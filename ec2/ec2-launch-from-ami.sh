#!/usr/bin/env bash
set -uo pipefail
# =============================================================================
# ec2-launch-from-ami.sh — Launch a NEW EC2 instance from an AMI, mirroring an
# existing instance's configuration (same AZ, instance type, key pair, security
# groups, subnet, IAM instance profile, EBS-optimized flag, and tags), with a
# REQUIRED new Name so it does not conflict with the source.
#
# The AMI already carries the volumes (e.g. one made by ec2-create-ami.sh); this
# script does NOT snapshot or attach volumes. It reproduces the *instance-level*
# configuration that an AMI does not carry — SGs, subnet, IAM profile, tags, etc.
# — by reading them from the --source instance you point it at.
#
# This is a standalone script. Requirements: awscli v2 configured locally, jq.
#
# -------------------------- SAMPLE COMMANDS ---------------------------------
# Preview the plan (creates nothing):
#   ./ec2-launch-from-ami.sh \
#       --ami    ami-0newami123456  \
#       --source i-0abc123def456    \
#       --name   nexus-restored     \
#       --region us-east-1 --profile my-aws-profile --dry-run
#
# Launch the new instance mirroring the source's config:
#   ./ec2-launch-from-ami.sh \
#       --ami    ami-0newami123456  \
#       --source i-0abc123def456    \
#       --name   nexus-restored     \
#       --region us-east-1 --profile my-aws-profile
#
# Typical pairing with ec2-create-ami.sh:
#   AMI_ID=$(./ec2-create-ami.sh --source i-0abc123def456 | awk -F= '/NEW_AMI_ID=/{print $2}')
#   ./ec2-launch-from-ami.sh --ami "$AMI_ID" --source i-0abc123def456 --name nexus-restored
# ----------------------------------------------------------------------------
#
# -------------------------- INPUTS YOU PROVIDE -------------------------------
# REQUIRED:
#   --ami    <AMI_ID>          The AMI to launch from (e.g. from ec2-create-ami.sh).
#   --source <INSTANCE_ID>     Existing instance whose configuration to mirror.
#   --name   <NAME_TAG>        Name tag for the NEW instance. Required, and must
#                              differ from the source's Name, so the new instance
#                              does not conflict with the source.
#
# OPTIONAL:
#   --private-ip <IP>          Specific private IP in the subnet (else auto).
#   --region <REGION>  --profile <PROFILE>   Default to env / CLI config.
#   --dry-run                  Describe + print the exact run-instances command.
#   --no-wait                  Don't wait for running + status checks.
#
# MIRRORED FROM --source (you don't supply): availability zone, instance type,
# key pair, security groups, subnet, IAM instance profile, EBS-optimized flag,
# and all instance tags (Name overridden to --name).
# Nothing on the source is modified.
# =============================================================================

NEW_AMI=""; SOURCE_ID=""; NAME_TAG=""; PRIVATE_IP=""
REGION="${AWS_REGION:-}"; PROFILE="${AWS_PROFILE:-}"
DRY_RUN="false"; NO_WAIT="false"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[ec2-launch-from-ami] $*"; }

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
    --ami)        shift; NEW_AMI="${1:-}";    shift ;;
    --source)     shift; SOURCE_ID="${1:-}";  shift ;;
    --name)       shift; NAME_TAG="${1:-}";   shift ;;
    --private-ip) shift; PRIVATE_IP="${1:-}"; shift ;;
    --region)     shift; REGION="${1:-}";     shift ;;
    --profile)    shift; PROFILE="${1:-}";    shift ;;
    --dry-run)    DRY_RUN="true"; shift ;;
    --no-wait)    NO_WAIT="true"; shift ;;
    -h|--help)    grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$NEW_AMI"   ]] || die "Missing --ami <AMI_ID>"
[[ -n "$SOURCE_ID" ]] || die "Missing --source <INSTANCE_ID> (config to mirror)"
[[ -n "$NAME_TAG"  ]] || die "Missing --name <NAME_TAG> (Name for the new instance)"

command -v aws >/dev/null 2>&1 || die "aws CLI not found"
command -v jq  >/dev/null 2>&1 || die "jq not found"

AWS_ARGS=()
[[ -n "$REGION"  ]] && AWS_ARGS+=(--region "$REGION")
[[ -n "$PROFILE" ]] && AWS_ARGS+=(--profile "$PROFILE")
awsr() { aws "${AWS_ARGS[@]}" "$@"; }

awsr sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials not working"

# ---------------------------- describe source -------------------------------
log "Describing source instance for configuration: ${SOURCE_ID}"
SRC="$(awsr ec2 describe-instances --instance-ids "$SOURCE_ID" \
        --query 'Reservations[0].Instances[0]' --output json 2>/dev/null)" \
  || die "describe-instances failed for ${SOURCE_ID}"
[[ -n "$SRC" && "$SRC" != "null" ]] || die "Source instance ${SOURCE_ID} not found."

j() { echo "$SRC" | jq -r "$1"; }
SRC_TYPE="$(j '.InstanceType')"
SRC_AZ="$(j '.Placement.AvailabilityZone')"
SRC_SUBNET="$(j '.SubnetId')"
SRC_KEY="$(j '.KeyName // empty')"
SRC_EBS_OPT="$(j '.EbsOptimized')"
SRC_IAM_ARN="$(j '.IamInstanceProfile.Arn // empty')"
SRC_SGS="$(echo "$SRC" | jq -r '[.SecurityGroups[].GroupId] | join(" ")')"
SRC_NAME="$(echo "$SRC" | jq -r '(.Tags[]? | select(.Key=="Name") | .Value) // empty')"
SRC_TENANCY="$(j '.Placement.Tenancy // empty')"

# Guard: new Name must differ from the source's Name
if [[ -n "$SRC_NAME" && "$NAME_TAG" == "$SRC_NAME" ]]; then
  die "--name '${NAME_TAG}' equals the source's Name tag. Choose a different name."
fi

cat <<EOF

================= SOURCE ($SOURCE_ID) =================
  name tag        : ${SRC_NAME:-<none>}
  instance type   : $SRC_TYPE
  AZ / subnet     : $SRC_AZ / $SRC_SUBNET
  key pair        : ${SRC_KEY:-<none>}
  IAM profile     : ${SRC_IAM_ARN:-<none>}
  security groups : $SRC_SGS
  EBS optimized   : $SRC_EBS_OPT
================= NEW INSTANCE =================
  from AMI        : $NEW_AMI
  name tag        : $NAME_TAG
  mirrors         : AZ, type, key pair, SGs, subnet, IAM profile, tags
================================================

EOF

# ---------------------------- build run-instances args ----------------------
# Tags: copy source tags (minus aws: reserved), override Name.
TAG_ITEMS="$(echo "$SRC" | jq -r --arg n "$NAME_TAG" '
  ( [ .Tags[]? | select(.Key|startswith("aws:")|not) | select(.Key!="Name") ]
    + [ {Key:"Name",Value:$n} ] )
  | map("{Key=\(.Key),Value=\(.Value)}") | join(",")')"
RUN_TAGSPEC="ResourceType=instance,Tags=[${TAG_ITEMS}]"

RUN_ARGS=(ec2 run-instances
  --image-id "$NEW_AMI"
  --instance-type "$SRC_TYPE"
  --subnet-id "$SRC_SUBNET"
  --security-group-ids $SRC_SGS
  --placement "AvailabilityZone=$SRC_AZ"
  --tag-specifications "$RUN_TAGSPEC"
  --count 1
)
[[ -n "$SRC_KEY" ]]            && RUN_ARGS+=(--key-name "$SRC_KEY")
[[ "$SRC_EBS_OPT" == "true" ]] && RUN_ARGS+=(--ebs-optimized)
[[ -n "$PRIVATE_IP" ]]         && RUN_ARGS+=(--private-ip-address "$PRIVATE_IP")
[[ -n "$SRC_IAM_ARN" ]]        && RUN_ARGS+=(--iam-instance-profile "Arn=$SRC_IAM_ARN")

# ---------------------------- dry-run gate ----------------------------------
if [[ "$DRY_RUN" == "true" ]]; then
  echo "================= PLAN (dry-run — nothing will be created) ================="
  echo "Would launch the new instance from the AMI, mirroring source config:"
  echo
  plan_cmd "${RUN_ARGS[@]}"
  echo
  [[ "$NO_WAIT" == "true" ]] || echo "  aws ec2 wait instance-status-ok --instance-ids <new-id>"
  echo
  echo "No resources were created. Re-run without --dry-run to execute."
  echo "==========================================================================="
  exit 0
fi

# ---------------------------- launch ----------------------------------------
log "Launching new instance from AMI ${NEW_AMI}"
NEW_ID="$(awsr "${RUN_ARGS[@]}" --query 'Instances[0].InstanceId' --output text 2>/dev/null)" \
  || die "run-instances failed"
[[ -n "$NEW_ID" && "$NEW_ID" != "None" ]] || die "run-instances returned no instance id"
log "New instance: ${NEW_ID}"

log "Waiting for ${NEW_ID} to reach 'running'..."
awsr ec2 wait instance-running --instance-ids "$NEW_ID" || die "instance did not reach running"

if [[ "$NO_WAIT" == "true" ]]; then
  log "--no-wait: skipping status-check wait."
else
  log "Waiting for 2/2 status checks on ${NEW_ID}..."
  awsr ec2 wait instance-status-ok --instance-ids "$NEW_ID" \
    || log "WARN: status checks not OK yet; inspect the instance."
fi

# ---------------------------- verify parity ---------------------------------
echo
log "=== Parity verification (source vs new) ==="
NEW="$(awsr ec2 describe-instances --instance-ids "$NEW_ID" \
        --query 'Reservations[0].Instances[0]' --output json 2>/dev/null)"
nj() { echo "$NEW" | jq -r "$1"; }
cmp() { if [[ "$2" == "$3" ]]; then echo "  OK    $1: $3"; else echo "  DIFF  $1: source='$2' new='$3'"; fi; }

cmp "instance type"  "$SRC_TYPE"   "$(nj '.InstanceType')"
cmp "AZ"             "$SRC_AZ"     "$(nj '.Placement.AvailabilityZone')"
cmp "subnet"         "$SRC_SUBNET" "$(nj '.SubnetId')"
cmp "key pair"       "$SRC_KEY"    "$(nj '.KeyName // empty')"
cmp "AMI"            "$NEW_AMI"    "$(nj '.ImageId')"
cmp "EBS optimized"  "$SRC_EBS_OPT" "$(nj '.EbsOptimized')"
SRC_SG_SORTED="$(echo "$SRC_SGS" | tr ' ' '\n' | sort | tr '\n' ' ' | xargs)"
NEW_SG_SORTED="$(echo "$NEW" | jq -r '[.SecurityGroups[].GroupId] | sort | join(" ")')"
cmp "security groups" "$SRC_SG_SORTED" "$NEW_SG_SORTED"
NEW_IAM="$(nj '.IamInstanceProfile.Arn // empty')"
cmp "IAM profile"    "$SRC_IAM_ARN" "$NEW_IAM"

echo
echo "NEW_INSTANCE_ID=${NEW_ID}"
log "Clone private IP: $(nj '.PrivateIpAddress // empty')"
log "Done. Review any DIFF lines above."
