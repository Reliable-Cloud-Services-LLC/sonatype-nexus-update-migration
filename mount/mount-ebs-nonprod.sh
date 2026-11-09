#!/usr/bin/env bash
set -uo pipefail
# =============================================================================
# mount-ebs-nonprod.sh — Mount the Nexus NONPROD data EBS volumes on a newly
# provisioned instance, BY FILESYSTEM UUID, and persist them in /etc/fstab.
#
# WHY BY UUID (not device name):
#   On Nitro instances the kernel assigns /dev/nvmeXn1 names at attach time, so
#   they are NOT stable — the volume you attached as /dev/sdf may appear as
#   nvme2n1 on one boot and nvme4n1 on the next. (On the source box you can
#   already see `lsblk` and `df` disagree on which nvme device is which mount.)
#   A filesystem UUID lives inside the filesystem itself, is captured in the
#   snapshot, and is therefore identical on the cloned volume — the only
#   reliable key. This script mounts and writes fstab by UUID.
#
# HOW TO USE (run as root on the NEW instance, after volumes are attached):
#   The MOUNT TABLE below is already filled with the nonprod source box's real
#   UUIDs, so normally you just:
#     - Run with  --plan   to preview what will be mounted + the fstab lines.
#     - Run (no flag) to mount everything and write /etc/fstab.
#   It is idempotent (skips what's already mounted). If a cloned volume ever
#   reports a DIFFERENT UUID than the source (rare — UUIDs survive snapshots),
#   run  --discover  to list the live UUIDs and update the matching row.
#
#   sudo ./mount-ebs-nonprod.sh --discover
#   sudo ./mount-ebs-nonprod.sh --plan
#   sudo ./mount-ebs-nonprod.sh
#   sudo ./mount-ebs-nonprod.sh --verify     # just check current state
#
# =============================================================================

# ============================ MOUNT TABLE — EDIT ME ==========================
# One row per data volume, in the order they should be mounted (PARENTS FIRST:
# /app must mount before /app/sonatype-work/... and /app/new-blob-store).
#
# Format:  UUID | MOUNT_POINT | FSTYPE | MOUNT_OPTS
#   UUID        filesystem UUID from `--discover` (NOT a device name)
#   MOUNT_POINT absolute path, identical to the source box
#   FSTYPE      xfs or ext4 (from `--discover`; most Nexus blob stores are xfs)
#   MOUNT_OPTS  usually "defaults,nofail"
#
# Fill in the UUIDs from `--discover`. Sizes in comments are from the nonprod
# source box to help you match each volume to its mount point.
# UUIDs below are the NONPROD source box's actual values (from its /etc/fstab).
# Filesystems are ext4 (the OS root/LVMs are xfs, but the data volumes are ext4).
# If a clone ever shows a different UUID, run --discover and update the row.
NONPROD_MOUNTS=(
  # ~4.9T  /app  — root of the app tree, MOUNT FIRST (its children nest under it)
  "6f12103f-1fcc-4083-a1d9-82e77d0d6a41 | /app                                    | ext4 | defaults,nofail"

  # ~24.4T /app/sonatype-work/nexus3/blobs/default
  "cbf282b1-8963-417e-a496-2ab05ec608e9 | /app/sonatype-work/nexus3/blobs/default | ext4 | defaults,nofail"

  # ~14.7T /app/sonatype-work/nexus3/blobs/elis
  "b1d1ae7d-fd14-4b61-abf9-b59c902f1b91 | /app/sonatype-work/nexus3/blobs/elis    | ext4 | defaults,nofail"

  # ~4.9T  /app/new-blob-store  (was commented out in the source fstab; enabled here per request)
  "bb626aea-4d63-441a-8feb-deaea185e620 | /app/new-blob-store                     | ext4 | defaults,nofail"

  # ~250G  /for_storage
  "a250ce47-7361-4129-b2e4-c28bed7526d4 | /for_storage                            | ext4 | defaults,nofail"
)
# ---------------------------------------------------------------------------
# NOTE on the source fstab (for the record): it listed /for_storage TWICE and
# had a copy/paste error where UUID b1d1ae7d...91 appeared on BOTH the
# /for_storage (rw,acl) line and the blobs/elis line. The correct mapping,
# confirmed, is: /for_storage = a250ce47...d4, and b1d1ae7d...91 = blobs/elis
# (above). /app and /app/new-blob-store are both ~4.9T but have distinct UUIDs,
# so they will not be confused.
# =============================================================================

FSTAB="/etc/fstab"
MARKER="# --- mount-ebs-nonprod (managed) ---"
MARKER_END="# --- end mount-ebs-nonprod ---"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[mount-ebs-nonprod] $*"; }
need_root() { [[ "$(id -u)" -eq 0 ]] || die "Run as root (mount + fstab writes)."; }

# ---------------------------- --discover ------------------------------------
# List every block device that has a filesystem but is NOT currently mounted,
# so you can copy UUIDs into the table above.
discover() {
  log "Unmounted filesystems on this host (copy UUIDs into the MOUNT TABLE):"
  echo
  printf "  %-38s %-8s %-8s %s\n" "UUID" "FSTYPE" "SIZE" "DEVICE"
  printf "  %-38s %-8s %-8s %s\n" "----" "------" "----" "------"
  # iterate whole disks and partitions that carry a filesystem
  lsblk -rno NAME,TYPE | while read -r name type; do
    [[ "$type" == "disk" || "$type" == "part" || "$type" == "lvm" ]] || continue
    dev="/dev/${name}"
    uuid="$(blkid -s UUID   -o value "$dev" 2>/dev/null || true)"
    fstype="$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)"
    [[ -n "$uuid" ]] || continue                     # no filesystem → skip
    # skip if already mounted
    if findmnt -rno TARGET "$dev" >/dev/null 2>&1; then continue; fi
    size="$(lsblk -dno SIZE "$dev" 2>/dev/null | tr -d ' ')"
    printf "  %-38s %-8s %-8s %s\n" "$uuid" "${fstype:-?}" "${size:-?}" "$dev"
  done
  echo
  log "Match each UUID to a mount point by size (see comments in the table),"
  log "then re-run with --plan."
}

# ---------------------------- parse table -----------------------------------
# emits: uuid<TAB>mountpoint<TAB>fstype<TAB>opts  (trimmed), for valid rows only
parse_rows() {
  local row uuid mp fstype opts
  for row in "${NONPROD_MOUNTS[@]}"; do
    IFS='|' read -r uuid mp fstype opts <<< "$row"
    uuid="$(echo "$uuid" | xargs)"; mp="$(echo "$mp" | xargs)"
    fstype="$(echo "$fstype" | xargs)"; opts="$(echo "$opts" | xargs)"
    [[ -z "$uuid" || "$uuid" == "PUT-UUID-HERE" ]] && continue
    printf '%s\t%s\t%s\t%s\n' "$uuid" "$mp" "$fstype" "$opts"
  done
}

count_ready() { parse_rows | grep -c . || true; }

# ---------------------------- --plan ----------------------------------------
plan() {
  local n; n="$(count_ready)"
  if [[ "$n" -eq 0 ]]; then
    die "No UUIDs filled in yet. Run --discover, then edit the MOUNT TABLE."
  fi
  log "Planned mounts (UUID → mount point), in order:"
  echo
  parse_rows | while IFS=$'\t' read -r uuid mp fstype opts; do
    local present="(UUID not found on this host!)"
    blkid -U "$uuid" >/dev/null 2>&1 && present="device: $(blkid -U "$uuid")"
    printf "  %-36s -> %-45s [%s %s]  %s\n" "$uuid" "$mp" "$fstype" "$opts" "$present"
  done
  echo
  log "fstab lines that would be added under the managed block in ${FSTAB}:"
  parse_rows | while IFS=$'\t' read -r uuid mp fstype opts; do
    echo "  UUID=${uuid}  ${mp}  ${fstype}  ${opts}  0 2"
  done
  echo
  log "Re-run without a flag to create mount points, mount, and update fstab."
}

# ---------------------------- --verify --------------------------------------
verify() {
  log "Current mount state for the configured mount points:"
  local bad=0
  parse_rows | while IFS=$'\t' read -r uuid mp fstype opts; do
    if findmnt -rno SOURCE,TARGET --target "$mp" 2>/dev/null | grep -q " ${mp}$"; then
      printf "  OK    %-45s  (%s)\n" "$mp" "$(findmnt -rno SOURCE --target "$mp")"
    else
      printf "  NOT MOUNTED  %-37s\n" "$mp"; bad=1
    fi
  done
  return 0
}

# ---------------------------- do the mounts ---------------------------------
apply() {
  local n; n="$(count_ready)"
  [[ "$n" -gt 0 ]] || die "No UUIDs filled in. Run --discover, edit the table, then --plan."

  # 1) sanity: every configured UUID must exist on this host before we touch fstab
  local missing=0
  while IFS=$'\t' read -r uuid mp fstype opts; do
    if ! blkid -U "$uuid" >/dev/null 2>&1; then
      log "ERROR: UUID ${uuid} (for ${mp}) not found on this host."; missing=1
    fi
  done < <(parse_rows)
  [[ "$missing" -eq 0 ]] || die "Fix the MOUNT TABLE (one or more UUIDs are not attached). Nothing changed."

  # 2) create mount points and mount in table order (parents first)
  while IFS=$'\t' read -r uuid mp fstype opts; do
    mkdir -p "$mp"
    if findmnt -rno TARGET --target "$mp" 2>/dev/null | grep -qx "$mp"; then
      log "already mounted: ${mp} — skipping"
      continue
    fi
    log "mounting UUID=${uuid} -> ${mp} (${fstype})"
    mount -t "$fstype" -o "$opts" "UUID=${uuid}" "$mp" \
      || die "mount failed for ${mp} (UUID=${uuid}). Nothing further changed."
  done < <(parse_rows)

  # 3) rewrite the managed block in fstab (idempotent)
  write_fstab

  log "All configured volumes mounted. Final state:"
  verify
  echo
  log "df for the configured mounts:"
  parse_rows | while IFS=$'\t' read -r uuid mp fstype opts; do
    df -h "$mp" 2>/dev/null | tail -1 | sed 's/^/    /'
  done
}

# ---------------------------- fstab management ------------------------------
write_fstab() {
  cp -a "$FSTAB" "${FSTAB}.bak.$(date +%Y%m%d-%H%M%S)"
  # strip any previous managed block
  if grep -qF "$MARKER" "$FSTAB"; then
    sed -i "/$(printf '%s' "$MARKER" | sed 's/[][\/.*]/\\&/g')/,/$(printf '%s' "$MARKER_END" | sed 's/[][\/.*]/\\&/g')/d" "$FSTAB"
  fi
  {
    echo "$MARKER"
    parse_rows | while IFS=$'\t' read -r uuid mp fstype opts; do
      echo "UUID=${uuid}  ${mp}  ${fstype}  ${opts}  0 2"
    done
    echo "$MARKER_END"
  } >> "$FSTAB"
  log "Updated ${FSTAB} (backup saved). Validating with 'mount -a'..."
  mount -a || log "WARN: 'mount -a' reported an issue — check ${FSTAB}."
}

# ---------------------------- main ------------------------------------------
case "${1:-}" in
  --discover) discover ;;
  --plan)     plan ;;
  --verify)   need_root; verify ;;
  "")         need_root; apply ;;
  -h|--help)  grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//' ;;
  *)          die "Unknown argument: $1 (use --discover | --plan | --verify | no flag)" ;;
esac
