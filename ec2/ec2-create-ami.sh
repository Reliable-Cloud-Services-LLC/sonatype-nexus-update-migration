#!/usr/bin/env bash
set -uo pipefail
# =============================================================================
# ec2-create-ami.sh — Create an AMI from a running EC2 instance, capturing the
# instance AND all attached EBS volumes, wait until the AMI is available, and
# print the new AMI ID.
#
# `aws ec2 create-image` captures every attached EBS volume (root + data) in a
# single call: it snapshots each volume and records them in the AMI's block
# device mapping, so launching from this AMI recreates all of them.
#
# Reboot behavior (consistency):
#   --no-reboot (DEFAULT here)  Do NOT reboot the instance. Produces a
#                               CRASH-consistent image (buffered/in-memory data
#                               not yet flushed may be missing). Chosen by
#                               default so a running instance is not disrupted.
#   --reboot                    Reboot the instance first for a fully
#                               filesystem-consistent image (brief downtime).
#
# This is a standalone script — no dependency on the other tooling.
# Requirements: awscli v2 configured locally.
#
# -------------------------- SAMPLE COMMANDS ---------------------------------
# Preview what would happen (creates nothing):
#   ./ec2-create-ami.sh --source i-0abc123def456 --dry-run
#
# Create an AMI without rebooting (default), wait, and print the AMI ID:
#   ./ec2-create-ami.sh --source i-0abc123def456
#
# Create a fully-consistent AMI by rebooting the instance first:
#   ./ec2-create-ami.sh --source i-0abc123def456 --reboot
#
# Give the AMI a specific name, in a specific region/profile:
#   ./ec2-create-ami.sh --source i-0abc123def456 \
#       --name nexus-prod-backup-2026-11-09 \
#       --region us-east-1 --profile my-aws-profile
#
# Kick off creation but don't wait for 'available' (prints AMI id immediately):
#   ./ec2-create-ami.sh --source i-0abc123def456 --no-wait
# ----------------------------------------------------------------------------
#
# -------------------------- INPUTS YOU PROVIDE -------------------------------
# REQUIRED:
#   --source <INSTANCE_ID>   The instance to image, e.g. i-0abc123...
#
# OPTIONAL:
#   --name   <AMI_NAME>      Name for the AMI. Default:
#                            "<instance Name or id>-ami-<timestamp>".
#   --reboot                 Reboot the instance for a consistent image.
#   --no-reboot              Do not reboot (DEFAULT).
#   --no-wait                Don't block waiting for the AMI to become available.
#   --region <REGION>  --profile <PROFILE>   Default to env / CLI config.
#   --dry-run                Describe + print the plan; create nothing.
#
# The AMI and its snapshots are tagged with the source instance id and a
# copy of the source instance's tags for traceability.
# =============================================================================

SOURCE_ID=""; AMI_NAME=""; REBOOT="false"
REGION="${AWS_REGION:-}"; PROFILE="${AWS_PROFILE:-}"
DRY_RUN="false"; NO_WAIT="false"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[ec2-create-ami] $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)    shift; SOURCE_ID="${1:-}"; shift ;;
    --name)      shift; AMI_NAME="${1:-}";  shift ;;
    --reboot)    REBOOT="true";  shift ;;
    --no-reboot) REBOOT="false"; shift ;;
    --no-wait)   NO_WAIT="true";  shift ;;
    --region)    shift; REGION="${1:-}";  shift ;;
    --profile)   shift; PROFILE="${1:-}"; shift ;;
    --dry-run)   DRY_RUN="true"; shift ;;
    -h|--help)   grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$SOURCE_ID" ]] || die "Missing --source <INSTANCE_ID>"
command -v aws >/dev/null 2>&1 || die "aws CLI not found"

AWS_ARGS=()
[[ -n "$REGION"  ]] && AWS_ARGS+=(--region "$REGION")
[[ -n "$PROFILE" ]] && AWS_ARGS+=(--profile "$PROFILE")
awsr() { aws "${AWS_ARGS[@]}" "$@"; }

awsr sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials not working"

# ---------------------------- describe source -------------------------------
log "Describing source instance: ${SOURCE_ID}"
SRC="$(awsr ec2 describe-instances --instance-ids "$SOURCE_ID" \
        --query 'Reservations[0].Instances[0]' --output json 2>/dev/null)" \
  || die "describe-instances failed for ${SOURCE_ID}"
[[ -n "$SRC" && "$SRC" != "null" ]] || die "Source instance ${SOURCE_ID} not found."

# Name tag + volume count for the plan
SRC_NAME=""
command -v jq >/dev/null 2>&1 && \
  SRC_NAME="$(echo "$SRC" | jq -r '(.Tags[]? | select(.Key=="Name") | .Value) // empty')"
VOL_COUNT="$(echo "$SRC" | grep -o '"VolumeId"' | wc -l | tr -d ' ')"

TS="$(date +%Y%m%d-%H%M%S)"
[[ -n "$AMI_NAME" ]] || AMI_NAME="${SRC_NAME:-$SOURCE_ID}-ami-${TS}"
# AMI names allow limited chars; sanitize spaces just in case.
AMI_NAME="$(echo "$AMI_NAME" | tr ' ' '_')"

NOREBOOT_DESC="--no-reboot (crash-consistent; instance NOT disrupted)"
[[ "$REBOOT" == "true" ]] && NOREBOOT_DESC="--reboot (instance reboots; fully consistent)"

cat <<EOF

================= CREATE AMI =================
  source instance : ${SOURCE_ID}  ${SRC_NAME:+(Name: ${SRC_NAME})}
  attached EBS vols: ${VOL_COUNT}  (all captured in the AMI)
  AMI name        : ${AMI_NAME}
  reboot mode     : ${NOREBOOT_DESC}
=============================================

EOF

# ---------------------------- build tag spec --------------------------------
# Tag the AMI + its snapshots with source id (and copy source tags if jq present)
TAG_ITEMS="Key=srcInstance,Value=${SOURCE_ID},Key=createdBy,Value=ec2-create-ami"
# (two tags expressed as one list below)
AMI_TAGSPEC="ResourceType=image,Tags=[{Key=srcInstance,Value=${SOURCE_ID}},{Key=createdBy,Value=ec2-create-ami}]"
SNAP_TAGSPEC="ResourceType=snapshot,Tags=[{Key=srcInstance,Value=${SOURCE_ID}},{Key=createdBy,Value=ec2-create-ami}]"

CREATE_ARGS=(ec2 create-image
  --instance-id "$SOURCE_ID"
  --name "$AMI_NAME"
  --description "AMI of ${SOURCE_ID} created ${TS} by ec2-create-ami"
  --tag-specifications "$AMI_TAGSPEC" "$SNAP_TAGSPEC"
)
[[ "$REBOOT" == "true" ]] && CREATE_ARGS+=(--reboot) || CREATE_ARGS+=(--no-reboot)

# ---------------------------- dry-run gate ----------------------------------
if [[ "$DRY_RUN" == "true" ]]; then
  echo "================= PLAN (dry-run — nothing will be created) ================="
  echo "Would run:"
  echo "  aws ${CREATE_ARGS[*]}"
  echo
  [[ "$NO_WAIT" == "true" ]] || echo "  aws ec2 wait image-available --image-ids <new-ami-id>"
  echo
  echo "Then print the new AMI ID. No resources were created."
  echo "==========================================================================="
  exit 0
fi

# ---------------------------- create ----------------------------------------
if [[ "$REBOOT" == "true" ]]; then
  log "WARNING: --reboot will REBOOT ${SOURCE_ID}. For a running Nexus this causes"
  log "         downtime. Omit --reboot (the default) for a no-reboot, crash-consistent AMI."
fi
log "Creating AMI from ${SOURCE_ID} (${NOREBOOT_DESC})"
AMI_ID="$(awsr "${CREATE_ARGS[@]}" --query 'ImageId' --output text 2>/dev/null)" \
  || die "create-image failed"
[[ -n "$AMI_ID" && "$AMI_ID" != "None" ]] || die "create-image returned no ImageId"
log "AMI creation started: ${AMI_ID}"

if [[ "$NO_WAIT" == "true" ]]; then
  log "--no-wait: not waiting for 'available'. Check status with:"
  log "  aws ec2 describe-images --image-ids ${AMI_ID} --query 'Images[0].State'"
else
  log "Waiting for AMI ${AMI_ID} to become available (snapshots can take a while)..."
  awsr ec2 wait image-available --image-ids "$AMI_ID" \
    || die "AMI ${AMI_ID} did not become available (check console)"
  log "AMI is available."
  # show the captured block device mapping so the user sees all volumes came across
  if command -v jq >/dev/null 2>&1; then
    log "Captured block device mapping:"
    awsr ec2 describe-images --image-ids "$AMI_ID" \
      --query 'Images[0].BlockDeviceMappings' --output json 2>/dev/null \
      | jq -r '.[] | "    \(.DeviceName)  ->  snapshot \(.Ebs.SnapshotId // "n/a")"' 2>/dev/null || true
  fi
fi

echo
# The headline output the user asked for: the new AMI ID, clearly printed.
echo "NEW_AMI_ID=${AMI_ID}"
log "Done."
