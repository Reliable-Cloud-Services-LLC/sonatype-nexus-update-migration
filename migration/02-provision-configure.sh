#!/usr/bin/env bash
set -uo pipefail
# =============================================================================
# 02-provision-configure.sh — Build the isolated clone and configure Nexus.
#
# This script has TWO kinds of stages:
#   AWS stages   (run from a workstation with AWS CLI + creds)
#   HOST stages  (run ON the new RHEL 9 instance, as root)
# Run the stage you need; each is idempotent-ish and guarded.
#
# Order:
#   aws-restore-rds     create CLONE RDS from the prod snapshot
#   aws-create-volumes  create volumes from EBS snapshots (in NEW_AZ)
#   aws-attach-volumes  attach those volumes to the new instance
#   host-prep           RHEL 9 packages, nexus user, dirs, SELinux, firewall
#   host-mount          mount the restored data volume(s) by UUID
#   host-install        download+extract Nexus (pinned version), promote
#   host-configure      write nexus-store.properties (CLONE RDS), store config
#   host-service        systemd unit, start Nexus
#
# Sources ./00-config.sh automatically.
#
# -------------------------- SAMPLE COMMANDS ---------------------------------
# On a workstation with AWS CLI (build the isolated clone infrastructure):
#   ./02-provision-configure.sh aws-restore-rds       # restore CLONE RDS from prod snapshot
#   ./02-provision-configure.sh aws-create-volumes    # clone EBS volumes in NEW_AZ
#   ./02-provision-configure.sh aws-attach-volumes    # attach them to NEW_INSTANCE_ID
#   # ...or all three at once:
#   ./02-provision-configure.sh all-aws
#
# On the NEW RHEL 9 box, as root (install + configure Nexus on the clone):
#   export CLONE_RDS_PASSWORD='the-clone-db-password'
#   sudo -E ./02-provision-configure.sh host-prep
#   sudo    ./02-provision-configure.sh host-mount          # guided; then:
#   sudo    ./02-provision-configure.sh host-mount-verify
#   sudo    ./02-provision-configure.sh host-install
#   sudo -E ./02-provision-configure.sh host-configure      # needs CLONE_RDS_PASSWORD
#   sudo    ./02-provision-configure.sh host-service
#
# See every stage:
#   ./02-provision-configure.sh --help
# =============================================================================

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HERE}/00-config.sh"

need_root() { [[ "$(id -u)" -eq 0 ]] || die "This host stage must run as root on the RHEL 9 box."; }

# =============================== AWS STAGES ==================================

aws_restore_rds() {
  assert_not_prod_rds
  local snap; snap="$(cat "${HERE}/.snapshot-rds.txt" 2>/dev/null || true)"
  [[ -n "$snap" ]] || die "No RDS snapshot recorded. Run 01-pre-validate.sh first (or set it in .snapshot-rds.txt)."
  [[ -n "$NEW_AZ" ]] || die "NEW_AZ unset."

  log "Restoring CLONE RDS '${CLONE_RDS_INSTANCE_ID}' from snapshot '${snap}'"
  log "  (prod RDS '${PROD_RDS_INSTANCE_ID}' is untouched)"

  aws_ rds restore-db-instance-from-db-snapshot \
    --db-instance-identifier "$CLONE_RDS_INSTANCE_ID" \
    --db-snapshot-identifier "$snap" \
    --db-instance-class "$CLONE_RDS_INSTANCE_CLASS" \
    --availability-zone "$NEW_AZ" \
    --no-multi-az \
    --no-publicly-accessible \
    >/dev/null 2>&1 || die "restore-db-instance-from-db-snapshot failed"

  log "Waiting for clone RDS to become available (can take 10-20 min)..."
  aws_ rds wait db-instance-available --db-instance-identifier "$CLONE_RDS_INSTANCE_ID" \
    || die "Clone RDS did not become available"

  local ep
  ep="$(aws_ rds describe-db-instances --db-instance-identifier "$CLONE_RDS_INSTANCE_ID" \
        --query 'DBInstances[0].Endpoint.Address' --output text)"
  log "Clone RDS endpoint: ${ep}"
  echo "$ep" > "${HERE}/.clone-rds-host.txt"
  log "Saved to ${HERE}/.clone-rds-host.txt — set CLONE_RDS_HOST in 00-config.sh to this value."
  log "IMPORTANT: ensure the clone RDS security group allows the NEW instance to reach port ${CLONE_RDS_PORT}."
}

aws_create_volumes() {
  [[ -f "${HERE}/.snapshots-ebs.txt" ]] || die "No EBS snapshots recorded. Run 01-pre-validate.sh first."
  [[ -n "$NEW_AZ" ]] || die "NEW_AZ unset."
  : > "${HERE}/.clone-volumes.txt"

  while read -r snapid vol entry; do
    [[ -n "$snapid" ]] || continue
    local mnt="${entry##*:}"
    log "Waiting for snapshot ${snapid} to complete..."
    aws_ ec2 wait snapshot-completed --snapshot-ids "$snapid" || die "snapshot ${snapid} not completed"
    local newvol
    newvol="$(aws_ ec2 create-volume --snapshot-id "$snapid" \
       --availability-zone "$NEW_AZ" --volume-type gp3 \
       --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=${SNAPSHOT_TAG}-clone},{Key=srcSnapshot,Value=${snapid}}]" \
       --query 'VolumeId' --output text 2>/dev/null || echo "")"
    [[ -n "$newvol" ]] || die "create-volume failed for snapshot ${snapid}"
    log "Created clone volume ${newvol} (mount target ${mnt})"
    echo "${newvol}  ${mnt}" >> "${HERE}/.clone-volumes.txt"
  done < "${HERE}/.snapshots-ebs.txt"
  log "Clone volumes recorded in ${HERE}/.clone-volumes.txt"
}

aws_attach_volumes() {
  [[ -f "${HERE}/.clone-volumes.txt" ]] || die "No clone volumes. Run aws-create-volumes first."
  [[ -n "$NEW_INSTANCE_ID" ]] || die "NEW_INSTANCE_ID unset (the RHEL 9 instance id)."
  local dev_letters=(f g h i j k)
  local i=0
  while read -r vol mnt; do
    [[ -n "$vol" ]] || continue
    aws_ ec2 wait volume-available --volume-ids "$vol" || die "volume ${vol} not available"
    local dev="/dev/sd${dev_letters[$i]}"
    log "Attaching ${vol} to ${NEW_INSTANCE_ID} as ${dev} (will surface as NVMe) for mount ${mnt}"
    aws_ ec2 attach-volume --volume-id "$vol" --instance-id "$NEW_INSTANCE_ID" --device "$dev" \
      >/dev/null 2>&1 || die "attach-volume failed for ${vol}"
    i=$((i+1))
  done < "${HERE}/.clone-volumes.txt"
  log "Attach requests submitted. On the host, identify NVMe devices with: lsblk -f"
}

# =============================== HOST STAGES =================================

host_prep() {
  need_root
  log "RHEL 9 base prep"
  dnf -y update
  dnf -y install tar gzip curl policycoreutils-python-utils util-linux

  if [[ -n "$NEXUS_UID" ]]; then
    id "$NEXUS_USER" >/dev/null 2>&1 || useradd -r -m -u "$NEXUS_UID" -s /bin/bash "$NEXUS_USER"
  else
    id "$NEXUS_USER" >/dev/null 2>&1 || useradd -r -m -s /bin/bash "$NEXUS_USER"
    log "NOTE: NEXUS_UID unset — if it differs from the old box, you'll chown the data dir (slow)."
  fi

  mkdir -p "$BASE_DIR" "$DATA_MOUNT"

  # file descriptors
  echo "${NEXUS_USER} - nofile 65536" > /etc/security/limits.d/nexus.conf

  # SELinux: label the connector ports (ignore errors if already labeled)
  if command -v semanage >/dev/null 2>&1; then
    for p in "$NEXUS_HTTP_PORT" "$DOCKER_PROXY_PORT" "$DOCKER_HOSTED_PORT"; do
      semanage port -a -t http_port_t -p tcp "$p" 2>/dev/null || \
        semanage port -m -t http_port_t -p tcp "$p" 2>/dev/null || true
    done
    log "SELinux: labeled ports ${NEXUS_HTTP_PORT}, ${DOCKER_PROXY_PORT}, ${DOCKER_HOSTED_PORT} as http_port_t"
  fi

  # firewalld
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for p in "$NEXUS_HTTP_PORT" "$DOCKER_PROXY_PORT" "$DOCKER_HOSTED_PORT"; do
      firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true
    done
    firewall-cmd --reload >/dev/null 2>&1 || true
    log "firewalld: opened ${NEXUS_HTTP_PORT}, ${DOCKER_PROXY_PORT}, ${DOCKER_HOSTED_PORT}"
  fi
  log "host-prep complete. (Security group inbound still must allow these ports.)"
}

host_mount() {
  need_root
  [[ -f "${HERE}/.clone-volumes.txt" ]] || die "No clone volumes recorded; run aws-create-volumes/attach first."
  log "Identify attached NVMe devices and mount them at their target paths."
  echo "  Current block devices:"; lsblk -f || true

  while read -r vol mnt; do
    [[ -n "$mnt" ]] || continue
    mkdir -p "$mnt"
    echo
    log "For clone volume ${vol}, target mount ${mnt}:"
    echo "    1) Find its device from the lsblk output above (e.g. /dev/nvme1n1)."
    echo "    2) Get its UUID:   blkid <device>"
    echo "    3) Mount:          mount <device> ${mnt}"
    echo "    4) Persist (fstab, by UUID, with nofail):"
    echo "         echo \"UUID=<uuid>  ${mnt}  xfs  defaults,nofail  0 2\" >> /etc/fstab"
    echo "       (use ext4 if that's your filesystem — check 'blkid')"
  done < "${HERE}/.clone-volumes.txt"

  cat <<'EOF'

  This stage is intentionally guided rather than automatic: picking the wrong
  NVMe device could mount over the root volume. After mounting, verify:
    ls -la <DATA_MOUNT>/nexus3/db  <DATA_MOUNT>/nexus3/blobs
  then re-run with: host-mount-verify
EOF
}

host_mount_verify() {
  need_root
  local okc=0 bad=0
  while read -r vol mnt; do
    [[ -n "$mnt" ]] || continue
    if mountpoint -q "$mnt"; then
      log "PASS  ${mnt} is a mountpoint"; okc=$((okc+1))
    else
      log "FAIL  ${mnt} is NOT mounted"; bad=$((bad+1))
    fi
  done < "${HERE}/.clone-volumes.txt"
  [[ -d "${DATA_DIR}/db"    ]] && log "PASS  ${DATA_DIR}/db present"    || log "WARN  ${DATA_DIR}/db not found (ok if DB is external-only and blobs are elsewhere)"
  [[ -d "${DATA_DIR}/blobs" ]] && log "PASS  ${DATA_DIR}/blobs present" || log "FAIL  ${DATA_DIR}/blobs not found — blob stores won't resolve"
  [[ "$bad" -eq 0 ]] || die "Fix mounts before continuing."
}

host_install() {
  need_root
  [[ ! -e "${ACTIVE_DIR}/bin" ]] || { log "Nexus already installed at ${ACTIVE_DIR}; skipping download."; return 0; }

  local stage="${BASE_DIR}/nexus-${NEXUS_VERSION}-stage"
  rm -rf "$stage"; mkdir -p "$stage"; cd "$stage"
  log "Downloading pinned Nexus ${NEXUS_VERSION}"
  curl -fL -o "$NEXUS_TARBALL" "$NEXUS_DOWNLOAD_URL" || die "download failed"
  log "Extracting (isolated staging so bundled sonatype-work can't touch real data)"
  tar -xzf "$NEXUS_TARBALL" --keep-directory-symlink

  local extracted="${stage}/nexus-${NEXUS_VERSION}"
  [[ -d "${extracted}/bin" && -d "${extracted}/etc" ]] || die "extracted layout unexpected: ${extracted}"
  mv "$extracted" "$ACTIVE_DIR"
  rm -rf "$stage"
  chown -R "${NEXUS_USER}:${NEXUS_USER}" "$ACTIVE_DIR" 2>/dev/null || chown -R "${NEXUS_USER}" "$ACTIVE_DIR"
  log "Installed Nexus ${NEXUS_VERSION} at ${ACTIVE_DIR}"
}

host_configure() {
  need_root
  assert_not_prod_rds
  [[ -n "$CLONE_RDS_HOST" ]] || die "CLONE_RDS_HOST unset. Set it from ${HERE}/.clone-rds-host.txt in 00-config.sh."
  [[ -n "$CLONE_RDS_PASSWORD" ]] || die "CLONE_RDS_PASSWORD unset. Export it; never hardcode."

  # 1) enable external datastore in data-dir nexus.properties
  local props_dir="${DATA_DIR}/etc"
  local fabric_dir="${props_dir}/fabric"
  mkdir -p "$fabric_dir"

  local nexus_props="${props_dir}/nexus.properties"
  touch "$nexus_props"
  if grep -q '^nexus.datastore.enabled=' "$nexus_props" 2>/dev/null; then
    sed -i -E 's|^nexus.datastore.enabled=.*|nexus.datastore.enabled=true|' "$nexus_props"
  else
    echo "nexus.datastore.enabled=true" >> "$nexus_props"
  fi
  # preserve the context path if the old box used one
  if [[ -n "$NEXUS_CONTEXT" ]]; then
    if grep -q '^nexus-context-path=' "$nexus_props" 2>/dev/null; then
      sed -i -E "s|^nexus-context-path=.*|nexus-context-path=${NEXUS_CONTEXT}|" "$nexus_props"
    else
      echo "nexus-context-path=${NEXUS_CONTEXT}" >> "$nexus_props"
    fi
  fi
  log "Wrote ${nexus_props}"

  # 2) point the clone at the CLONE RDS (NOT prod)
  local store="${fabric_dir}/nexus-store.properties"
  cat > "$store" <<EOF
username=${CLONE_RDS_USER}
password=${CLONE_RDS_PASSWORD}
jdbcUrl=$(nexus_jdbc_url)
EOF
  chmod 640 "$store"
  log "Wrote ${store} pointing at CLONE RDS host ${CLONE_RDS_HOST}"
  log "  jdbcUrl = $(nexus_jdbc_url)"

  # 3) ownership of the data dir (fix only if UID mismatch)
  chown -R "${NEXUS_USER}:${NEXUS_USER}" "$DATA_DIR" 2>/dev/null || chown -R "${NEXUS_USER}" "$DATA_DIR"

  # 4) point karaf.data at the mounted data dir explicitly (avoid relative ambiguity)
  local vmopt="${ACTIVE_DIR}/bin/nexus.vmoptions"
  if [[ -f "$vmopt" ]]; then
    if grep -q '^-Dkaraf.data=' "$vmopt"; then
      sed -i -E "s|^-Dkaraf.data=.*|-Dkaraf.data=${DATA_DIR}|" "$vmopt"
    else
      echo "-Dkaraf.data=${DATA_DIR}" >> "$vmopt"
    fi
    log "Set -Dkaraf.data=${DATA_DIR} in ${vmopt}"
  fi

  log "SAFETY: confirm this is the clone, not prod:"
  log "  grep jdbcUrl ${store}"
}

host_service() {
  need_root
  local unit="/etc/systemd/system/nexus.service"
  if [[ ! -f "$unit" ]]; then
    log "Writing systemd unit ${unit}"
    cat > "$unit" <<EOF
[Unit]
Description=Sonatype Nexus Repository
After=network.target
[Service]
Type=forking
LimitNOFILE=65536
ExecStart=${ACTIVE_DIR}/bin/nexus start
ExecStop=${ACTIVE_DIR}/bin/nexus stop
User=${NEXUS_USER}
Restart=on-abort
TimeoutSec=600
[Install]
WantedBy=multi-user.target
EOF
  fi
  # ensure nexus.rc runs as the service user
  echo "run_as_user=\"${NEXUS_USER}\"" > "${ACTIVE_DIR}/bin/nexus.rc"
  systemctl daemon-reload
  systemctl enable nexus
  log "Starting Nexus (first start on migrated DB runs rebuild tasks — watch the log)"
  systemctl start nexus
  log "tail -f ${DATA_DIR}/log/nexus.log"
}

usage() {
  cat <<EOF
Usage: $0 <stage>

AWS stages (run from workstation w/ AWS CLI):
  aws-restore-rds       restore CLONE RDS from prod snapshot
  aws-create-volumes    create clone EBS volumes from snapshots in NEW_AZ
  aws-attach-volumes    attach clone volumes to NEW_INSTANCE_ID
  all-aws               the three above in order

HOST stages (run on the NEW RHEL 9 box as root):
  host-prep             packages, user, dirs, SELinux ports, firewall, ulimits
  host-mount            guided mount of the clone data volume(s)
  host-mount-verify     assert mounts + data dir present
  host-install          download+extract pinned Nexus ${NEXUS_VERSION}, promote
  host-configure        write nexus-store.properties (CLONE RDS) + nexus.properties
  host-service          systemd unit + start
  all-host              prep, install, configure, service (mount is manual)

Config: edit 00-config.sh. Export CLONE_RDS_PASSWORD before host-configure.
EOF
}

case "${1:-}" in
  aws-restore-rds)    aws_restore_rds ;;
  aws-create-volumes) aws_create_volumes ;;
  aws-attach-volumes) aws_attach_volumes ;;
  all-aws)            aws_restore_rds; aws_create_volumes; aws_attach_volumes ;;
  host-prep)          host_prep ;;
  host-mount)         host_mount ;;
  host-mount-verify)  host_mount_verify ;;
  host-install)       host_install ;;
  host-configure)     host_configure ;;
  host-service)       host_service ;;
  all-host)           host_prep; host_install; host_configure; host_service ;;
  -h|--help|"")       usage ;;
  *)                  die "Unknown stage: $1 (see --help)" ;;
esac
