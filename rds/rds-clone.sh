#!/usr/bin/env bash
set -uo pipefail
# =============================================================================
# rds-clone.sh — Clone an existing RDS instance by:
#   1) describing the SOURCE and capturing every attribute we care about
#   2) taking a FRESH manual snapshot of the source (and waiting for it)
#   3) restoring a NEW instance from that snapshot, mirroring the source:
#      subnet group, VPC security groups, parameter group, option group,
#      Multi-AZ, storage type/iops, port, instance class, PI, monitoring,
#      deletion protection, CA cert, tags
#   4) waiting until available and VERIFYING parity against the source
#
# Model: mirror the source EXACTLY. Credentials are left as-is from the
# snapshot (the clone keeps the source's master user/password). New instance
# identifier is provided by you.
#
# Requirements: awscli v2 configured locally, jq.
#
# -------------------------- SAMPLE COMMANDS ---------------------------------
# Preview the plan first (creates nothing — like `terraform plan`):
#   ./rds-clone.sh \
#       --source   nexus-prod  \
#       --target   nexus-clone-rhel9  \
#       --endpoint nexus-prod.abc123.us-east-1.rds.amazonaws.com  \
#       --region   us-east-1  --profile my-aws-profile  --dry-run
#
# Execute the clone (fresh snapshot -> restore mirror -> verify parity):
#   ./rds-clone.sh \
#       --source   nexus-prod  \
#       --target   nexus-clone-rhel9  \
#       --endpoint nexus-prod.abc123.us-east-1.rds.amazonaws.com  \
#       --region   us-east-1  --profile my-aws-profile
#
# Minimal form (no endpoint guard, default region/profile from your AWS config):
#   ./rds-clone.sh --source nexus-prod --target nexus-clone-rhel9
# ----------------------------------------------------------------------------
#
# -------------------------- INPUTS YOU PROVIDE -------------------------------
# REQUIRED:
#   --source   <SOURCE_DB_IDENTIFIER>   The existing RDS instance identifier
#                                       (the DBInstanceIdentifier, e.g.
#                                       "nexus-prod" — NOT the endpoint host).
#   --target   <NEW_DB_IDENTIFIER>      Identifier for the new clone instance.
#
# OPTIONAL:
#   --endpoint <SOURCE_ENDPOINT_ADDRESS>  Safety guard. If given, the script
#                                       verifies it equals the source's actual
#                                       endpoint address and ABORTS if not — so
#                                       you can't accidentally clone the wrong
#                                       instance. (e.g.
#                                       nexus-prod.abc123.us-east-1.rds.amazonaws.com)
#   --region   <REGION>                 Defaults to AWS_REGION / CLI config.
#   --profile  <PROFILE>                Defaults to AWS_PROFILE / CLI config.
#   --dry-run                           PLAN ONLY (like `terraform plan`):
#                                       describes the source, then prints the
#                                       EXACT aws commands it WOULD run. Creates
#                                       nothing. No snapshot, no restore.
#   --no-wait                           Submit restore but don't block waiting.
#
# EVERYTHING ELSE IS DISCOVERED FROM THE SOURCE — you do not supply it:
#   engine + version, instance class, Multi-AZ, AZ, port, subnet group,
#   VPC security groups, DB parameter group, option group, storage type/IOPS,
#   allocated storage, publicly-accessible, deletion protection, CA cert,
#   Performance Insights, enhanced monitoring (interval + role),
#   backup retention, copy-tags-to-snapshot, and all tags.
#   The source's master username/password come across in the snapshot as-is.
#
# Nothing is modified on the SOURCE except the creation of one manual snapshot.
# =============================================================================

# ---------------------------- args & helpers --------------------------------
SOURCE_ID=""; TARGET_ID=""; SRC_ENDPOINT=""
REGION="${AWS_REGION:-}"; PROFILE="${AWS_PROFILE:-}"
DRY_RUN="false"; NO_WAIT="false"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[rds-clone] $*"; }

# Pretty-print a planned command with each flag on its own line (terraform-plan
# style). Quotes args that contain spaces so the output is copy-pasteable.
plan_cmd() {
  local first="true" out="  aws"
  for a in "$@"; do
    if [[ "$a" == --* ]]; then
      [[ "$first" == "true" ]] && out+=" $a" || out+=$'\n'"    $a"
      first="false"
    else
      case "$a" in *" "*|*'"'*) a="\"$a\"";; esac
      out+=" $a"
    fi
  done
  echo "$out"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)   shift; SOURCE_ID="${1:-}";   shift ;;
    --target)   shift; TARGET_ID="${1:-}";   shift ;;
    --endpoint) shift; SRC_ENDPOINT="${1:-}"; shift ;;
    --region)   shift; REGION="${1:-}";      shift ;;
    --profile)  shift; PROFILE="${1:-}";     shift ;;
    --dry-run)  DRY_RUN="true";  shift ;;
    --no-wait)  NO_WAIT="true";  shift ;;
    -h|--help)  grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$SOURCE_ID" ]] || die "Missing --source <SOURCE_DB_IDENTIFIER>"
[[ -n "$TARGET_ID" ]] || die "Missing --target <NEW_DB_IDENTIFIER>"
[[ "$SOURCE_ID" != "$TARGET_ID" ]] || die "--source and --target must differ"

command -v aws >/dev/null 2>&1 || die "aws CLI not found"
command -v jq  >/dev/null 2>&1 || die "jq not found (needed to parse describe output)"

# Assemble common aws args
AWS_ARGS=()
[[ -n "$REGION"  ]] && AWS_ARGS+=(--region "$REGION")
[[ -n "$PROFILE" ]] && AWS_ARGS+=(--profile "$PROFILE")
awsr() { aws "${AWS_ARGS[@]}" "$@"; }

awsr sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials not working (region=${REGION:-default} profile=${PROFILE:-default})"

# ---------------------------- 1. describe source ----------------------------
log "Describing source instance: ${SOURCE_ID}"
SRC_JSON="$(awsr rds describe-db-instances --db-instance-identifier "$SOURCE_ID" \
            --query 'DBInstances[0]' --output json 2>/dev/null)" \
  || die "Could not describe source '${SOURCE_ID}' — check name/region/profile."
[[ -n "$SRC_JSON" && "$SRC_JSON" != "null" ]] || die "Source '${SOURCE_ID}' not found."

# jq helper
j() { echo "$SRC_JSON" | jq -r "$1"; }

SRC_STATUS="$(j '.DBInstanceStatus')"
SRC_ENGINE="$(j '.Engine')"
SRC_EVERSION="$(j '.EngineVersion')"
SRC_CLASS="$(j '.DBInstanceClass')"
SRC_AZ="$(j '.AvailabilityZone')"
SRC_MULTIAZ="$(j '.MultiAZ')"
SRC_PORT="$(j '.Endpoint.Port // empty')"
SRC_ADDRESS="$(j '.Endpoint.Address // empty')"
SRC_SUBNET_GROUP="$(j '.DBSubnetGroup.DBSubnetGroupName // empty')"
SRC_STORAGE_TYPE="$(j '.StorageType // empty')"
SRC_IOPS="$(j '.Iops // empty')"
SRC_ALLOC="$(j '.AllocatedStorage // empty')"
SRC_PUBLIC="$(j '.PubliclyAccessible')"
SRC_DELPROT="$(j '.DeletionProtection')"
SRC_CA="$(j '.CACertificateIdentifier // empty')"
SRC_PI="$(j '.PerformanceInsightsEnabled // false')"
SRC_MONITORING_INTERVAL="$(j '.MonitoringInterval // 0')"
SRC_MONITORING_ROLE="$(j '.MonitoringRoleArn // empty')"
SRC_BACKUP_RETENTION="$(j '.BackupRetentionPeriod // 0')"
SRC_COPY_TAGS_SNAP="$(j '.CopyTagsToSnapshot // false')"
SRC_ARN="$(j '.DBInstanceArn')"

# Security groups (active ones only)
SRC_VPC_SGS="$(echo "$SRC_JSON" | jq -r '[.VpcSecurityGroups[]? | select(.Status=="active") | .VpcSecurityGroupId] | join(" ")')"
# Parameter group (in-sync one)
SRC_PARAM_GROUP="$(echo "$SRC_JSON" | jq -r '.DBParameterGroups[0].DBParameterGroupName // empty')"
# Option group
SRC_OPTION_GROUP="$(echo "$SRC_JSON" | jq -r '.OptionGroupMemberships[0].OptionGroupName // empty')"

# Tags (describe separately — not always inlined)
SRC_TAGS_JSON="$(awsr rds list-tags-for-resource --resource-name "$SRC_ARN" \
                  --query 'TagList' --output json 2>/dev/null || echo '[]')"

# ---------------------------- endpoint guard --------------------------------
if [[ -n "$SRC_ENDPOINT" ]]; then
  if [[ "$SRC_ENDPOINT" == "$SRC_ADDRESS" ]]; then
    log "Endpoint guard OK: ${SRC_ENDPOINT} matches source."
  else
    die "Endpoint guard FAILED: you passed '${SRC_ENDPOINT}' but source ${SOURCE_ID} endpoint is '${SRC_ADDRESS}'. Refusing (wrong target?)."
  fi
fi

# ---------------------------- plan printout ---------------------------------
cat <<EOF

================= SOURCE ($SOURCE_ID) =================
  status            : $SRC_STATUS
  engine            : $SRC_ENGINE $SRC_EVERSION
  class             : $SRC_CLASS
  endpoint          : $SRC_ADDRESS:$SRC_PORT
  az / multi-az     : $SRC_AZ / $SRC_MULTIAZ
  subnet group      : $SRC_SUBNET_GROUP
  vpc SGs           : ${SRC_VPC_SGS:-<none active>}
  parameter group   : ${SRC_PARAM_GROUP:-<default>}
  option group      : ${SRC_OPTION_GROUP:-<none>}
  storage           : ${SRC_STORAGE_TYPE:-?} alloc=${SRC_ALLOC:-?}GB iops=${SRC_IOPS:-n/a}
  publicly access   : $SRC_PUBLIC
  deletion prot     : $SRC_DELPROT
  CA cert           : ${SRC_CA:-<default>}
  perf insights     : $SRC_PI
  monitoring        : interval=${SRC_MONITORING_INTERVAL}s role=${SRC_MONITORING_ROLE:-<none>}
  backup retention  : ${SRC_BACKUP_RETENTION} days
  tags              : $(echo "$SRC_TAGS_JSON" | jq -c '.')
================= TARGET ($TARGET_ID) =================
  will mirror the above (credentials kept from snapshot)
======================================================

EOF

# ---------------------------- build all command args ------------------------
# We assemble every command's arguments FIRST (no execution yet), so --dry-run
# can print the exact commands. Execution happens after the dry-run gate below.

TS="$(date +%Y%m%d-%H%M%S)"
SNAP_ID="${SOURCE_ID}-clone-src-${TS}"

# 2. snapshot args
SNAPSHOT_ARGS=(
  --db-instance-identifier "$SOURCE_ID"
  --db-snapshot-identifier "$SNAP_ID"
  --tags "Key=purpose,Value=clone-source" "Key=srcInstance,Value=${SOURCE_ID}"
)

# ---------------------------- 3. restore new instance -----------------------
# Build restore args, mirroring what restore CAN take at create time.
RESTORE_ARGS=(
  --db-instance-identifier "$TARGET_ID"
  --db-snapshot-identifier "$SNAP_ID"
  --db-instance-class      "$SRC_CLASS"
  --no-publicly-accessible
)
# publicly accessible mirrors source
[[ "$SRC_PUBLIC" == "true" ]] && RESTORE_ARGS=("${RESTORE_ARGS[@]/--no-publicly-accessible/--publicly-accessible}")

# Multi-AZ vs single-AZ (restore honors one or the other)
if [[ "$SRC_MULTIAZ" == "true" ]]; then
  RESTORE_ARGS+=(--multi-az)
else
  RESTORE_ARGS+=(--no-multi-az --availability-zone "$SRC_AZ")
fi

[[ -n "$SRC_SUBNET_GROUP" ]] && RESTORE_ARGS+=(--db-subnet-group-name "$SRC_SUBNET_GROUP")
[[ -n "$SRC_OPTION_GROUP"  ]] && RESTORE_ARGS+=(--option-group-name "$SRC_OPTION_GROUP")
[[ -n "$SRC_PORT"          ]] && RESTORE_ARGS+=(--port "$SRC_PORT")
[[ -n "$SRC_STORAGE_TYPE"  ]] && RESTORE_ARGS+=(--storage-type "$SRC_STORAGE_TYPE")

# Apply VPC security groups and DB parameter group AT RESTORE TIME.
# If omitted, restore falls back to the VPC DEFAULT security group and the
# engine DEFAULT parameter group (NOT the source's). Passing them here means
# the clone is never briefly exposed in the default SG.
if [[ -n "$SRC_VPC_SGS" ]]; then
  # shellcheck disable=SC2206
  SG_ARR=($SRC_VPC_SGS)
  RESTORE_ARGS+=(--vpc-security-group-ids "${SG_ARR[@]}")
fi
[[ -n "$SRC_PARAM_GROUP" ]] && RESTORE_ARGS+=(--db-parameter-group-name "$SRC_PARAM_GROUP")
# iops only valid for io1/io2/gp3
if [[ -n "$SRC_IOPS" && "$SRC_IOPS" != "null" && "$SRC_STORAGE_TYPE" =~ ^(io1|io2|gp3)$ ]]; then
  RESTORE_ARGS+=(--iops "$SRC_IOPS")
fi
[[ "$SRC_COPY_TAGS_SNAP" == "true" ]] && RESTORE_ARGS+=(--copy-tags-to-snapshot)
[[ "$SRC_DELPROT" == "true" ]] && RESTORE_ARGS+=(--deletion-protection)

# Tags at create (also re-applied via add-tags later to be safe)
TAG_PAIRS="$(echo "$SRC_TAGS_JSON" | jq -r '.[] | "Key=\(.Key),Value=\(.Value)"' 2>/dev/null | tr '\n' ' ')"
if [[ -n "${TAG_PAIRS// }" ]]; then
  # shellcheck disable=SC2206
  TAG_ARR=($TAG_PAIRS)
  RESTORE_ARGS+=(--tags "${TAG_ARR[@]}")
fi

# ---------------------------- 4. build modify args --------------------------
# SGs, parameter group, subnet group, option group, port, storage, deletion
# protection and tags are already set at restore time above. What remains to
# apply post-restore (restore has no parameters for these): backup retention,
# enhanced monitoring, Performance Insights, and CA certificate identifier.
# Built here (before execution) so --dry-run can print it too.
MODIFY_ARGS=(--db-instance-identifier "$TARGET_ID" --apply-immediately)
MODIFY_NEEDED="false"

if [[ "$SRC_BACKUP_RETENTION" -gt 0 ]] 2>/dev/null; then
  MODIFY_ARGS+=(--backup-retention-period "$SRC_BACKUP_RETENTION"); MODIFY_NEEDED="true"
fi
if [[ -n "$SRC_CA" ]]; then MODIFY_ARGS+=(--ca-certificate-identifier "$SRC_CA"); MODIFY_NEEDED="true"; fi

# Enhanced monitoring
if [[ "$SRC_MONITORING_INTERVAL" -gt 0 ]] 2>/dev/null; then
  MODIFY_ARGS+=(--monitoring-interval "$SRC_MONITORING_INTERVAL")
  [[ -n "$SRC_MONITORING_ROLE" ]] && MODIFY_ARGS+=(--monitoring-role-arn "$SRC_MONITORING_ROLE")
  MODIFY_NEEDED="true"
fi
# Performance Insights
if [[ "$SRC_PI" == "true" ]]; then MODIFY_ARGS+=(--enable-performance-insights); MODIFY_NEEDED="true"; fi

# ======================= DRY-RUN GATE (terraform-plan style) =================
# All command arguments are now resolved. Print the exact plan; create nothing.
if [[ "$DRY_RUN" == "true" ]]; then
  cat <<EOF
================= PLAN (dry-run — nothing will be created) =================
The following AWS commands WOULD run, in order:

STEP 1 — snapshot the source (then wait for 'available'):
$(plan_cmd rds create-db-snapshot "${SNAPSHOT_ARGS[@]}")
  aws rds wait db-snapshot-available --db-snapshot-identifier $SNAP_ID

STEP 2 — restore the new instance from that snapshot:
$(plan_cmd rds restore-db-instance-from-db-snapshot "${RESTORE_ARGS[@]}")
EOF
  if [[ "$NO_WAIT" != "true" ]]; then
    echo "  aws rds wait db-instance-available --db-instance-identifier $TARGET_ID"
  fi
  if [[ "$MODIFY_NEEDED" == "true" ]]; then
    cat <<EOF

STEP 3 — apply settings restore can't take at create time:
$(plan_cmd rds modify-db-instance "${MODIFY_ARGS[@]}")
EOF
  else
    echo
    echo "STEP 3 — (skipped: all settings applied at restore time)"
  fi
  cat <<EOF

STEP 4 — re-apply tags + run parity verification (read-only describe calls).

Snapshot id that WOULD be created: ${SNAP_ID}
No resources were created. Re-run without --dry-run to execute.
===========================================================================
EOF
  exit 0
fi

# ---------------------------- EXECUTE: snapshot -----------------------------
log "Creating fresh snapshot of source: ${SNAP_ID}"
awsr rds create-db-snapshot "${SNAPSHOT_ARGS[@]}" >/dev/null 2>&1 \
  || die "create-db-snapshot failed"
log "Waiting for snapshot to become available (this can take a while)..."
awsr rds wait db-snapshot-available --db-snapshot-identifier "$SNAP_ID" \
  || die "Snapshot ${SNAP_ID} did not become available"
log "Snapshot available: ${SNAP_ID}"

# ---------------------------- EXECUTE: restore ------------------------------
log "Restoring new instance ${TARGET_ID} from ${SNAP_ID}"
awsr rds restore-db-instance-from-db-snapshot "${RESTORE_ARGS[@]}" >/dev/null 2>&1 \
  || die "restore-db-instance-from-db-snapshot failed"

if [[ "$NO_WAIT" == "true" ]]; then
  log "--no-wait: restore submitted. Re-run the modify/verify steps once it's available."
  exit 0
fi

log "Waiting for ${TARGET_ID} to become available (10-20+ min)..."
awsr rds wait db-instance-available --db-instance-identifier "$TARGET_ID" \
  || die "New instance did not become available"
log "New instance available."

# ---------------------------- EXECUTE: modify -------------------------------
if [[ "$MODIFY_NEEDED" == "true" ]]; then
  log "Applying post-restore modifications (backups, monitoring, PI, CA cert)"
  awsr rds modify-db-instance "${MODIFY_ARGS[@]}" >/dev/null 2>&1 \
    || log "WARN: modify-db-instance reported an error; review the clone's settings manually."
  # some modifications apply during a brief 'modifying' state; wait it out
  awsr rds wait db-instance-available --db-instance-identifier "$TARGET_ID" 2>/dev/null || true
else
  log "No post-restore modifications needed (everything applied at restore time)."
fi

# Re-apply tags explicitly (idempotent) in case copy-tags didn't cover instance-level tags
NEW_ARN="$(awsr rds describe-db-instances --db-instance-identifier "$TARGET_ID" \
            --query 'DBInstances[0].DBInstanceArn' --output text 2>/dev/null || echo "")"
if [[ -n "$NEW_ARN" && -n "${TAG_PAIRS// }" ]]; then
  # shellcheck disable=SC2206
  TAG_ARR=($TAG_PAIRS)
  awsr rds add-tags-to-resource --resource-name "$NEW_ARN" --tags "${TAG_ARR[@]}" >/dev/null 2>&1 || true
  log "Tags re-applied to ${TARGET_ID}"
fi

# ---------------------------- 5. verify parity ------------------------------
echo
log "=== Parity verification (source vs clone) ==="
NEW_JSON="$(awsr rds describe-db-instances --db-instance-identifier "$TARGET_ID" \
            --query 'DBInstances[0]' --output json 2>/dev/null)"
nj() { echo "$NEW_JSON" | jq -r "$1"; }

cmp_field() { # label  src  new
  local label="$1" a="$2" b="$3"
  if [[ "$a" == "$b" ]]; then echo "  OK    ${label}: ${b}"
  else echo "  DIFF  ${label}: source='${a}' clone='${b}'"; fi
}

cmp_field "engine"          "$SRC_ENGINE $SRC_EVERSION" "$(nj '.Engine') $(nj '.EngineVersion')"
cmp_field "class"           "$SRC_CLASS"          "$(nj '.DBInstanceClass')"
cmp_field "multi-az"        "$SRC_MULTIAZ"        "$(nj '.MultiAZ')"
cmp_field "port"            "$SRC_PORT"           "$(nj '.Endpoint.Port // empty')"
cmp_field "subnet group"    "$SRC_SUBNET_GROUP"   "$(nj '.DBSubnetGroup.DBSubnetGroupName // empty')"
cmp_field "storage type"    "$SRC_STORAGE_TYPE"   "$(nj '.StorageType // empty')"
cmp_field "deletion prot"   "$SRC_DELPROT"        "$(nj '.DeletionProtection')"
cmp_field "backup retention" "$SRC_BACKUP_RETENTION" "$(nj '.BackupRetentionPeriod // 0')"
cmp_field "CA cert"         "${SRC_CA}"           "$(nj '.CACertificateIdentifier // empty')"
cmp_field "parameter group" "${SRC_PARAM_GROUP}"  "$(echo "$NEW_JSON" | jq -r '.DBParameterGroups[0].DBParameterGroupName // empty')"
cmp_field "option group"    "${SRC_OPTION_GROUP}" "$(echo "$NEW_JSON" | jq -r '.OptionGroupMemberships[0].OptionGroupName // empty')"

SRC_SG_SORTED="$(echo "$SRC_VPC_SGS" | tr ' ' '\n' | sort | tr '\n' ' ')"
NEW_SG_SORTED="$(echo "$NEW_JSON" | jq -r '[.VpcSecurityGroups[]? | select(.Status=="active") | .VpcSecurityGroupId] | sort | join(" ")')"
cmp_field "vpc SGs"         "$(echo "$SRC_SG_SORTED" | xargs)" "$(echo "$NEW_SG_SORTED" | xargs)"

NEW_ADDRESS="$(nj '.Endpoint.Address // empty')"
echo
log "Clone endpoint: ${NEW_ADDRESS}:$(nj '.Endpoint.Port // empty')"
log "Source snapshot used: ${SNAP_ID}"
log "Done. Review any DIFF lines above."
