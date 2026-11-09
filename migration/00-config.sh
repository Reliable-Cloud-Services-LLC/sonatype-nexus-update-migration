#!/usr/bin/env bash
# =============================================================================
# Shared configuration for the Nexus RHEL 8 -> RHEL 9 migration scripts
# (isolated-clone model: old prod stays live and UNTOUCHED)
#
# Source this file from the other scripts:  source ./00-config.sh
# Everything marked <<< EDIT must be set for your environment.
# =============================================================================

# ---- Nexus version (MUST match the OLD box; a newer version fails to start) --
# Old RHEL 8 box is on 3.95.3-02, so the new box runs the SAME version.
# Upgrading to a newer Nexus is a SEPARATE exercise AFTER migration succeeds.
NEXUS_VERSION="3.95.3-02"                       # <<< keep in lockstep with old box
NEXUS_TARBALL="nexus-${NEXUS_VERSION}-linux-x86_64.tar.gz"
NEXUS_DOWNLOAD_URL="https://download.sonatype.com/nexus/3/${NEXUS_TARBALL}"

# ---- Paths (keep identical to the OLD box so blob-store paths resolve) --------
BASE_DIR="/app"
ACTIVE_DIR="${BASE_DIR}/nexus"                  # install dir on the NEW box
DATA_MOUNT="/app/sonatype-work"                 # <<< EDIT: must match old box mount point
DATA_DIR="${DATA_MOUNT}/nexus3"                 # karaf.data
NEXUS_USER="nexus"                              # <<< EDIT if different
NEXUS_UID=""                                    # <<< EDIT: old box's numeric 'nexus' UID (id nexus) — match to avoid chown

# ---- NEW RHEL 9 instance -----------------------------------------------------
NEW_AZ=""                                        # <<< EDIT: AZ of old data volumes (must match for EBS attach)
NEW_INSTANCE_ID=""                               # <<< EDIT: filled once the RHEL 9 instance exists

# ---- Blob store EBS volumes (OLD prod volume IDs to SNAPSHOT) -----------------
# List every EBS volume that holds blob stores / the data dir on the OLD box.
# These are SNAPSHOTTED; prod volumes are never detached.
# Format: "oldVolumeId:mountPoint"  (mountPoint identical to old box)
BLOB_VOLUMES=(
  # "vol-0oldblobs1:/app/sonatype-work"          # <<< EDIT: add your real volume(s)
  # "vol-0oldblobs2:/app/blobs-extra"
)

# ---- RDS (external PostgreSQL) ----------------------------------------------
# PROD RDS — the source we snapshot. NEVER pointed at by the clone.
PROD_RDS_INSTANCE_ID=""                          # <<< EDIT: prod RDS instance identifier
PROD_RDS_DB_NAME="nexus"                         # <<< EDIT: database name (often 'nexus')

# CLONE RDS — restored from a prod snapshot; the NEW box points here.
CLONE_RDS_INSTANCE_ID="nexus-clone-$(date +%Y%m%d)"  # created by the provision script
CLONE_RDS_INSTANCE_CLASS="db.m5.large"           # <<< EDIT: size for the test clone
CLONE_RDS_HOST=""                                # filled after restore (endpoint address)
CLONE_RDS_PORT="5432"
CLONE_RDS_USER="nexus"                           # <<< EDIT: DB user
CLONE_RDS_PASSWORD="${CLONE_RDS_PASSWORD:-}"     # <<< export CLONE_RDS_PASSWORD; do not hardcode
CLONE_RDS_SCHEMA="nexus"                         # <<< EDIT if you use a non-default schema

# JDBC URL the new box will use (built from the clone values above)
nexus_jdbc_url() {
  echo "jdbc:postgresql://${CLONE_RDS_HOST}:${CLONE_RDS_PORT}/${PROD_RDS_DB_NAME}"
}

# ---- Connector ports (match old box so clients/validation line up) -----------
NEXUS_HTTP_PORT="8080"                            # <<< EDIT: UI/REST port
NEXUS_CONTEXT="/nexus"                            # <<< EDIT: context path ("" if at root)
DOCKER_PROXY_PORT="8132"                          # <<< EDIT
DOCKER_HOSTED_PORT="8143"                         # <<< EDIT

# ---- AWS CLI profile/region --------------------------------------------------
AWS_PROFILE="${AWS_PROFILE:-default}"             # <<< EDIT if needed
AWS_REGION="${AWS_REGION:-us-east-1}"             # <<< EDIT

# ---- Misc --------------------------------------------------------------------
SNAPSHOT_TAG="nexus-rhel9-migration-$(date +%Y%m%d)"
LOG_PREFIX="[nexus-migrate]"

aws_() { aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"; }

log()  { echo "${LOG_PREFIX} $*"; }
die()  { echo "${LOG_PREFIX} ERROR: $*" >&2; exit 1; }

# Sanity: refuse to run if the clone would somehow point at prod RDS
assert_not_prod_rds() {
  if [[ -n "$PROD_RDS_INSTANCE_ID" && "$CLONE_RDS_INSTANCE_ID" == "$PROD_RDS_INSTANCE_ID" ]]; then
    die "CLONE_RDS_INSTANCE_ID equals PROD_RDS_INSTANCE_ID — refusing (would risk prod)."
  fi
  if [[ -n "$CLONE_RDS_HOST" && -n "$PROD_RDS_INSTANCE_ID" ]]; then
    case "$CLONE_RDS_HOST" in
      *"${PROD_RDS_INSTANCE_ID}"*)
        die "CLONE_RDS_HOST looks like the PROD endpoint — refusing to point the clone at prod." ;;
    esac
  fi
}
