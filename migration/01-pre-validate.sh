#!/usr/bin/env bash
set -uo pipefail
# =============================================================================
# 01-pre-validate.sh  —  Run BEFORE migrating. Validates prerequisites and
# snapshots prod data (EBS + RDS) WITHOUT touching the live RHEL 8 instance.
#
# Safe to run while prod Nexus is up: it only reads prod and creates snapshots.
#
# Sources ./00-config.sh automatically — edit that file's <<< EDIT markers first.
#
# -------------------------- SAMPLE COMMANDS ---------------------------------
# 1) Edit migration/00-config.sh (NEW_AZ, PROD_RDS_INSTANCE_ID, BLOB_VOLUMES, ...).
#
# Checks only, no snapshots (dry sanity pass):
#   ./01-pre-validate.sh --check
#
# Full pre-validation + create prod EBS/RDS snapshots (non-disruptive):
#   ./01-pre-validate.sh
# =============================================================================

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HERE}/00-config.sh"

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  PASS  $*"; PASS=$((PASS+1)); }
no()   { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
sk()   { echo "  SKIP  $*"; SKIP=$((SKIP+1)); }

CHECK_ONLY="false"
[[ "${1:-}" == "--check" ]] && CHECK_ONLY="true"

# ---------------------------------------------------------------------------
echo "=== Pre-flight: tooling & config ==="

command -v aws >/dev/null 2>&1 && ok "aws CLI present" || no "aws CLI missing"
if aws_ sts get-caller-identity >/dev/null 2>&1; then
  ok "AWS credentials valid (profile=${AWS_PROFILE} region=${AWS_REGION})"
else
  no "AWS credentials/profile not working (profile=${AWS_PROFILE})"
fi

[[ -n "$NEXUS_VERSION" ]] && ok "Nexus version pinned: ${NEXUS_VERSION}" || no "NEXUS_VERSION unset"
[[ -n "$NEW_AZ" ]] && ok "Target AZ set: ${NEW_AZ}" || no "NEW_AZ unset (must match prod volume AZ)"
[[ -n "$PROD_RDS_INSTANCE_ID" ]] && ok "Prod RDS id set: ${PROD_RDS_INSTANCE_ID}" || no "PROD_RDS_INSTANCE_ID unset"
[[ ${#BLOB_VOLUMES[@]} -gt 0 ]] && ok "Blob volume(s) listed: ${#BLOB_VOLUMES[@]}" || no "BLOB_VOLUMES empty"

# ---------------------------------------------------------------------------
echo
echo "=== Verify the download URL for the pinned version resolves ==="
# HEAD the tarball so we fail now, not mid-provision, if the version string is wrong.
code="$(curl -sS -o /dev/null -w '%{http_code}' -I "$NEXUS_DOWNLOAD_URL" 2>/dev/null || echo 000)"
if [[ "$code" == "200" ]]; then
  ok "Tarball reachable: ${NEXUS_TARBALL} (HTTP 200)"
else
  no "Tarball HEAD returned HTTP ${code} for ${NEXUS_DOWNLOAD_URL} — check NEXUS_VERSION"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Verify prod EBS volumes exist and capture their AZ/type ==="
for entry in "${BLOB_VOLUMES[@]}"; do
  vol="${entry%%:*}"; mnt="${entry##*:}"
  [[ -n "$vol" ]] || continue
  az="$(aws_ ec2 describe-volumes --volume-ids "$vol" \
         --query 'Volumes[0].AvailabilityZone' --output text 2>/dev/null || echo "")"
  if [[ -n "$az" && "$az" != "None" ]]; then
    ok "Volume ${vol} exists (AZ=${az}, mount target=${mnt})"
    if [[ -n "$NEW_AZ" && "$az" != "$NEW_AZ" ]]; then
      echo "        NOTE: volume AZ ${az} != NEW_AZ ${NEW_AZ}. Snapshot+restore crosses AZ (fine), but a direct attach would not."
    fi
  else
    no "Volume ${vol} not found via describe-volumes"
  fi
done

# ---------------------------------------------------------------------------
echo
echo "=== Verify prod RDS exists and note its engine/version ==="
if [[ -n "$PROD_RDS_INSTANCE_ID" ]]; then
  read -r engine ever status <<<"$(aws_ rds describe-db-instances \
     --db-instance-identifier "$PROD_RDS_INSTANCE_ID" \
     --query 'DBInstances[0].[Engine,EngineVersion,DBInstanceStatus]' \
     --output text 2>/dev/null || echo "none none none")"
  if [[ "$engine" == "postgres" ]]; then
    ok "Prod RDS ${PROD_RDS_INSTANCE_ID}: ${engine} ${ever} (status=${status})"
  else
    no "Prod RDS lookup failed or not postgres (got engine='${engine}')"
  fi
fi

# ---------------------------------------------------------------------------
# Snapshots — the heart of the isolated-clone model. Prod is never detached.
# ---------------------------------------------------------------------------
if [[ "$CHECK_ONLY" == "true" ]]; then
  echo
  echo "=== --check mode: skipping snapshot creation ==="
else
  echo
  echo "=== Snapshot prod EBS blob volumes (non-disruptive) ==="
  for entry in "${BLOB_VOLUMES[@]}"; do
    vol="${entry%%:*}"; [[ -n "$vol" ]] || continue
    snapid="$(aws_ ec2 create-snapshot --volume-id "$vol" \
        --description "nexus blob ${vol} ${SNAPSHOT_TAG}" \
        --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=${SNAPSHOT_TAG}},{Key=srcVolume,Value=${vol}}]" \
        --query 'SnapshotId' --output text 2>/dev/null || echo "")"
    if [[ -n "$snapid" ]]; then
      ok "Created EBS snapshot ${snapid} from ${vol}"
      echo "$snapid  $vol  $entry" >> "${HERE}/.snapshots-ebs.txt"
    else
      no "Snapshot failed for volume ${vol}"
    fi
  done
  [[ -f "${HERE}/.snapshots-ebs.txt" ]] && echo "  (recorded in ${HERE}/.snapshots-ebs.txt)"

  echo
  echo "=== Snapshot prod RDS (non-disruptive manual snapshot) ==="
  if [[ -n "$PROD_RDS_INSTANCE_ID" ]]; then
    rds_snap="nexus-prod-${SNAPSHOT_TAG}"
    if aws_ rds create-db-snapshot \
         --db-instance-identifier "$PROD_RDS_INSTANCE_ID" \
         --db-snapshot-identifier "$rds_snap" >/dev/null 2>&1; then
      ok "Requested RDS snapshot ${rds_snap} (creating in background)"
      echo "$rds_snap" > "${HERE}/.snapshot-rds.txt"
    else
      no "RDS snapshot request failed for ${PROD_RDS_INSTANCE_ID}"
    fi
  fi
fi

# ---------------------------------------------------------------------------
echo
echo "=== Summary ==="
echo "  PASS: ${PASS}   FAIL: ${FAIL}   SKIP: ${SKIP}"
if [[ "$FAIL" -gt 0 ]]; then
  echo "  Resolve FAILs before running 02-provision-configure.sh"
  exit 1
fi
echo "  Pre-validation OK."
[[ "$CHECK_ONLY" == "false" ]] && echo "  Snapshots recorded in ${HERE}/.snapshots-ebs.txt and .snapshot-rds.txt"
echo "  Wait for snapshots to reach 'completed'/'available' before provisioning:"
echo "    aws ec2 wait snapshot-completed --snapshot-ids <id>"
echo "    aws rds wait db-snapshot-available --db-snapshot-identifier <id>"
exit 0
