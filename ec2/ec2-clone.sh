#!/usr/bin/env bash
set -uo pipefail
# =============================================================================
# ec2-clone.sh — Clone an existing EC2 instance onto a NEW AMI (e.g. RHEL 9),
# reusing the source's configuration and a SNAPSHOT-COPY of its DATA volumes,
# WITHOUT touching the source instance.
#
# What it does:
#   1) describe the SOURCE instance and capture: type, key pair, IAM profile,
#      AZ, subnet, security groups, tags, and its block-device mapping
#   2) identify DATA volumes (every attached volume EXCEPT the root/boot volume)
#   3) snapshot those data volumes (source stays running, untouched)
#   4) create new volumes from those snapshots in the same AZ
#   5) launch a NEW instance from the AMI YOU PASS (--ami, the RHEL 9 image),
#      mirroring type, key pair, SGs, subnet, IAM profile, and tags
#   6) attach the cloned data volumes at the SAME device names as the source
#   7) wait for running + 2/2 status checks, then verify parity
#
# The NEW instance boots from the RHEL 9 AMI's OWN fresh root volume. The old
# RHEL 8 root is intentionally NOT cloned or attached — this is an OS upgrade.
# This script stops at attach: mounting the data volumes and writing fstab is
# a separate step done on the new host (by UUID, at the original mount paths).
#
# Requirements: awscli v2 configured locally, jq.
#
# -------------------------- INPUTS YOU PROVIDE -------------------------------
# REQUIRED:
#   --source <SOURCE_INSTANCE_ID>   The existing instance, e.g. i-0abc123...
#   --ami    <NEW_AMI_ID>           The AMI to boot the clone from (RHEL 9),
#                                   e.g. ami-0rhel9...
#   --name   <NAME_TAG>             Name tag for the NEW instance. Required and
#                                   must differ from the source's Name, so the
#                                   clone is always named deliberately (mirrors
#                                   the RDS clone's explicit --target).
#
# OPTIONAL:
#   --private-ip <IP>               Specific private IP in the subnet (else auto).
#   --region  <REGION>  --profile <PROFILE>   Default to env / CLI config.
#   --dry-run                       PLAN ONLY (terraform-plan style): describe +
#                                   print the exact AWS commands; create nothing.
#   --no-wait                       Launch + attach but don't wait for status checks.
#
# DISCOVERED FROM THE SOURCE (you do not supply):
#   instance type, key pair name, IAM instance profile, availability zone,
#   subnet, security group IDs, all instance tags, EBS-optimized flag,
#   and the data-volume device mapping (volume id -> device name).
#
# Nothing is modified on the SOURCE except creation of volume snapshots.
# =============================================================================

SOURCE_ID=""; NEW_AMI=""; NAME_TAG=""; PRIVATE_IP=""
REGION="${AWS_REGION:-}"; PROFILE="${AWS_PROFILE:-}"
DRY_RUN="false"; NO_WAIT="false"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[ec2-clone] $*"; }

# terraform-plan style command printer (flag per line, quotes spaced args)
plan_cmd() {
  local first="true" out="  aws"
  for a in "$@"; do
    if [[ "$a" == --* ]]; then
      [[ "$first" == "true" ]] && out+=" $a" || out+=$'\n'"    $a"
      first="false"
    else
      case "$a" in *" "*|*'"'*|*'['*) a="'$a'";; esac
      out+=" $a"
    fi
  done
  echo "$out"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)     shift; SOURCE_ID="${1:-}";  shift ;;
    --ami)        shift; NEW_AMI="${1:-}";     shift ;;
    --name)       shift; NAME_TAG="${1:-}";    shift ;;
    --private-ip) shift; PRIVATE_IP="${1:-}";  shift ;;
    --region)     shift; REGION="${1:-}";      shift ;;
    --profile)    shift; PROFILE="${1:-}";     shift ;;
    --dry-run)    DRY_RUN="true";  shift ;;
    --no-wait)    NO_WAIT="true";  shift ;;
    -h|--help)    grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$SOURCE_ID" ]] || die "Missing --source <SOURCE_INSTANCE_ID>"
[[ -n "$NEW_AMI"   ]] || die "Missing --ami <NEW_AMI_ID> (the RHEL 9 image)"
[[ -n "$NAME_TAG"  ]] || die "Missing --name <NAME_TAG> (the Name for the new instance)"

command -v aws >/dev/null 2>&1 || die "aws CLI not found"
command -v jq  >/dev/null 2>&1 || die "jq not found"

AWS_ARGS=()
[[ -n "$REGION"  ]] && AWS_ARGS+=(--region "$REGION")
[[ -n "$PROFILE" ]] && AWS_ARGS+=(--profile "$PROFILE")
awsr() { aws "${AWS_ARGS[@]}" "$@"; }

awsr sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials not working"

# ---------------------------- 1. describe source ----------------------------
log "Describing source instance: ${SOURCE_ID}"
SRC="$(awsr ec2 describe-instances --instance-ids "$SOURCE_ID" \
        --query 'Reservations[0].Instances[0]' --output json 2>/dev/null)" \
  || die "describe-instances failed for ${SOURCE_ID}"
[[ -n "$SRC" && "$SRC" != "null" ]] || die "Source instance ${SOURCE_ID} not found."

j() { echo "$SRC" | jq -r "$1"; }

SRC_TYPE="$(j '.InstanceType')"
SRC_AZ="$(j '.Placement.AvailabilityZone')"
SRC_SUBNET="$(j '.SubnetId')"
SRC_KEY="$(j '.KeyName // empty')"
SRC_AMI_OLD="$(j '.ImageId')"
SRC_EBS_OPT="$(j '.EbsOptimized')"
SRC_IAM_ARN="$(j '.IamInstanceProfile.Arn // empty')"
SRC_ROOT_DEVICE="$(j '.RootDeviceName')"            # e.g. /dev/sda1 or /dev/xvda
SRC_SGS="$(echo "$SRC" | jq -r '[.SecurityGroups[].GroupId] | join(" ")')"
SRC_NAME="$(echo "$SRC" | jq -r '(.Tags[]? | select(.Key=="Name") | .Value) // empty')"

# All instance tags (as Key=,Value= pairs for create-tags / tag-spec)
SRC_TAGS_JSON="$(echo "$SRC" | jq -c '[.Tags[]? | select(.Key|startswith("aws:")|not)]')"

# Block device mapping -> identify DATA volumes (everything but the root device)
#   produces lines: <volumeId> <deviceName>
DATA_VOLS="$(echo "$SRC" | jq -r --arg root "$SRC_ROOT_DEVICE" '
  .BlockDeviceMappings[]
  | select(.DeviceName != $root)
  | select(.Ebs.VolumeId != null)
  | "\(.Ebs.VolumeId) \(.DeviceName)"')"

[[ -n "$DATA_VOLS" ]] || log "NOTE: source has no non-root data volumes. Only the root (from the new AMI) will exist on the clone."

# --name is required (checked above). Guard against reusing the source's Name,
# so the clone is distinguishable from the source.
if [[ -n "$SRC_NAME" && "$NAME_TAG" == "$SRC_NAME" ]]; then
  die "--name '${NAME_TAG}' equals the source's Name tag. Choose a different name for the clone."
fi

# ---------------------------- plan printout ---------------------------------
cat <<EOF

================= SOURCE ($SOURCE_ID) =================
  name tag          : ${SRC_NAME:-<none>}
  instance type     : $SRC_TYPE
  AZ / subnet       : $SRC_AZ / $SRC_SUBNET
  key pair          : ${SRC_KEY:-<none>}
  IAM profile       : ${SRC_IAM_ARN:-<none>}
  security groups   : $SRC_SGS
  EBS optimized     : $SRC_EBS_OPT
  old AMI (RHEL 8)  : $SRC_AMI_OLD
  root device       : $SRC_ROOT_DEVICE  (NOT cloned — new AMI supplies root)
  data volumes      :
$(if [[ -n "$DATA_VOLS" ]]; then echo "$DATA_VOLS" | sed 's/^/      /'; else echo "      <none>"; fi)
================= TARGET (new clone) =================
  new AMI (RHEL 9)  : $NEW_AMI
  name tag          : $NAME_TAG
  will mirror       : type, key pair, SGs, subnet, IAM profile, tags, AZ
  data volumes      : snapshot -> new volume -> attach at same device name
=====================================================

EOF

# ---------------------------- build commands (no exec yet) ------------------
TS="$(date +%Y%m%d-%H%M%S)"

# Tag specifications for run-instances (instance + volumes), Name overridden
TAG_ITEMS="$(echo "$SRC_TAGS_JSON" | jq -r --arg n "$NAME_TAG" '
  ( [ .[] | select(.Key!="Name") ] + [ {Key:"Name",Value:$n} ] )
  | map("{Key=\(.Key),Value=\(.Value)}") | join(",")')"
RUN_TAGSPEC="ResourceType=instance,Tags=[${TAG_ITEMS}]"

# run-instances args (mirror source)
RUN_ARGS=(
  ec2 run-instances
  --image-id "$NEW_AMI"
  --instance-type "$SRC_TYPE"
  --subnet-id "$SRC_SUBNET"
  --security-group-ids $SRC_SGS
  --placement "AvailabilityZone=$SRC_AZ"
  --tag-specifications "$RUN_TAGSPEC"
  --count 1
)
[[ -n "$SRC_KEY" ]]      && RUN_ARGS+=(--key-name "$SRC_KEY")
[[ "$SRC_EBS_OPT" == "true" ]] && RUN_ARGS+=(--ebs-optimized)
[[ -n "$PRIVATE_IP" ]]   && RUN_ARGS+=(--private-ip-address "$PRIVATE_IP")
if [[ -n "$SRC_IAM_ARN" ]]; then
  RUN_ARGS+=(--iam-instance-profile "Arn=$SRC_IAM_ARN")
fi

# ---------------------------- DRY-RUN GATE ----------------------------------
if [[ "$DRY_RUN" == "true" ]]; then
  echo "================= PLAN (dry-run — nothing will be created) ================="
  echo "The following AWS commands WOULD run, in order:"
  echo
  if [[ -n "$DATA_VOLS" ]]; then
    echo "STEP 1 — snapshot each DATA volume (source stays running):"
    while read -r vol dev; do
      [[ -n "$vol" ]] || continue
      plan_cmd ec2 create-snapshot --volume-id "$vol" \
        --description "ec2-clone ${SOURCE_ID} ${dev} ${TS}" \
        --tag-specifications "ResourceType=snapshot,Tags=[{Key=srcInstance,Value=${SOURCE_ID}},{Key=srcDevice,Value=${dev}}]"
    done <<< "$DATA_VOLS"
    echo "  aws ec2 wait snapshot-completed --snapshot-ids <each>"
    echo
    echo "STEP 2 — create a new volume from each snapshot (same AZ ${SRC_AZ}):"
    echo "  aws ec2 create-volume --snapshot-id <snap> --availability-zone ${SRC_AZ} --volume-type gp3 ..."
    echo
  else
    echo "STEP 1-2 — (no data volumes to snapshot/clone)"
    echo
  fi
  echo "STEP 3 — launch the new instance from the RHEL 9 AMI:"
  plan_cmd "${RUN_ARGS[@]}"
  echo
  if [[ -n "$DATA_VOLS" ]]; then
    echo "STEP 4 — attach each cloned volume at the SAME device name:"
    while read -r vol dev; do
      [[ -n "$vol" ]] || continue
      echo "  aws ec2 attach-volume --instance-id <new-id> --volume-id <clone-of ${vol}> --device ${dev}"
    done <<< "$DATA_VOLS"
    echo
  fi
  echo "STEP 5 — wait for running + 2/2 status checks, then verify parity."
  echo
  echo "No resources were created. Re-run without --dry-run to execute."
  echo "==========================================================================="
  exit 0
fi

# ---------------------------- 3. snapshot data volumes ----------------------
declare -a SNAP_IDS=() SNAP_DEVS=()
if [[ -n "$DATA_VOLS" ]]; then
  log "Snapshotting data volumes (source untouched)"
  while read -r vol dev; do
    [[ -n "$vol" ]] || continue
    snap="$(awsr ec2 create-snapshot --volume-id "$vol" \
      --description "ec2-clone ${SOURCE_ID} ${dev} ${TS}" \
      --tag-specifications "ResourceType=snapshot,Tags=[{Key=srcInstance,Value=${SOURCE_ID}},{Key=srcDevice,Value=${dev}}]" \
      --query 'SnapshotId' --output text 2>/dev/null)" \
      || die "create-snapshot failed for ${vol}"
    log "  ${vol} (${dev}) -> snapshot ${snap}"
    SNAP_IDS+=("$snap"); SNAP_DEVS+=("$dev")
  done <<< "$DATA_VOLS"

  log "Waiting for snapshots to complete..."
  awsr ec2 wait snapshot-completed --snapshot-ids "${SNAP_IDS[@]}" \
    || die "one or more snapshots did not complete"
  log "Snapshots complete."
fi

# ---------------------------- 4. create clone volumes -----------------------
declare -a CLONE_VOLS=() CLONE_DEVS=()
for i in "${!SNAP_IDS[@]}"; do
  snap="${SNAP_IDS[$i]}"; dev="${SNAP_DEVS[$i]}"
  nv="$(awsr ec2 create-volume --snapshot-id "$snap" \
        --availability-zone "$SRC_AZ" --volume-type gp3 \
        --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=${NAME_TAG}-${dev##*/}},{Key=srcInstance,Value=${SOURCE_ID}},{Key=srcDevice,Value=${dev}}]" \
        --query 'VolumeId' --output text 2>/dev/null)" \
    || die "create-volume failed from ${snap}"
  log "  snapshot ${snap} -> volume ${nv} (for ${dev})"
  CLONE_VOLS+=("$nv"); CLONE_DEVS+=("$dev")
done

# ---------------------------- 5. launch new instance ------------------------
log "Launching new instance from AMI ${NEW_AMI}"
NEW_ID="$(awsr "${RUN_ARGS[@]}" --query 'Instances[0].InstanceId' --output text 2>/dev/null)" \
  || die "run-instances failed"
[[ -n "$NEW_ID" && "$NEW_ID" != "None" ]] || die "run-instances returned no instance id"
log "New instance: ${NEW_ID}"

log "Waiting for ${NEW_ID} to reach 'running'..."
awsr ec2 wait instance-running --instance-ids "$NEW_ID" || die "instance did not reach running"

# ---------------------------- 6. attach cloned volumes ----------------------
if [[ ${#CLONE_VOLS[@]} -gt 0 ]]; then
  log "Attaching cloned data volumes at source device names"
  for i in "${!CLONE_VOLS[@]}"; do
    nv="${CLONE_VOLS[$i]}"; dev="${CLONE_DEVS[$i]}"
    awsr ec2 wait volume-available --volume-ids "$nv" || die "volume ${nv} not available"
    awsr ec2 attach-volume --instance-id "$NEW_ID" --volume-id "$nv" --device "$dev" \
      >/dev/null 2>&1 || die "attach-volume failed (${nv} -> ${dev})"
    log "  ${nv} -> ${dev}"
  done
fi

if [[ "$NO_WAIT" == "true" ]]; then
  log "--no-wait: skipping status-check wait."
else
  log "Waiting for 2/2 status checks on ${NEW_ID} (can take a few minutes)..."
  awsr ec2 wait instance-status-ok --instance-ids "$NEW_ID" \
    || log "WARN: status checks not OK yet; inspect the instance."
fi

# ---------------------------- 7. verify parity ------------------------------
echo
log "=== Parity verification (source vs clone) ==="
NEW="$(awsr ec2 describe-instances --instance-ids "$NEW_ID" \
        --query 'Reservations[0].Instances[0]' --output json 2>/dev/null)"
nj() { echo "$NEW" | jq -r "$1"; }
cmp() { if [[ "$2" == "$3" ]]; then echo "  OK    $1: $3"; else echo "  DIFF  $1: source='$2' clone='$3'"; fi; }

cmp "instance type" "$SRC_TYPE"  "$(nj '.InstanceType')"
cmp "AZ"            "$SRC_AZ"    "$(nj '.Placement.AvailabilityZone')"
cmp "subnet"        "$SRC_SUBNET" "$(nj '.SubnetId')"
cmp "key pair"      "$SRC_KEY"   "$(nj '.KeyName // empty')"
cmp "AMI"           "$NEW_AMI"   "$(nj '.ImageId')"
cmp "EBS optimized" "$SRC_EBS_OPT" "$(nj '.EbsOptimized')"

SRC_SG_SORTED="$(echo "$SRC_SGS" | tr ' ' '\n' | sort | tr '\n' ' ' | xargs)"
NEW_SG_SORTED="$(echo "$NEW" | jq -r '[.SecurityGroups[].GroupId] | sort | join(" ")')"
cmp "security groups" "$SRC_SG_SORTED" "$NEW_SG_SORTED"

echo
NEW_PRIV="$(nj '.PrivateIpAddress // empty')"
log "Clone instance id : ${NEW_ID}"
log "Clone private IP  : ${NEW_PRIV}  (public/EIP reassignment is a separate cutover step)"
if [[ ${#CLONE_DEVS[@]} -gt 0 ]]; then
  log "Attached data volumes (mount by UUID at their original paths on the new host):"
  for i in "${!CLONE_VOLS[@]}"; do log "    ${CLONE_VOLS[$i]} at ${CLONE_DEVS[$i]}"; done
fi
log "Done. Review any DIFF lines above."
