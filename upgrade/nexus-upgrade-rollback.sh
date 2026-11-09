#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Nexus Upgrade / Rollback Script  (aligned to Nexus 3.78.0+ / 3.87.0+ layout)
#
# KEY STRUCTURAL CHANGE vs. the previous script:
#   The linux tarball does NOT extract to a nested nexus-<v>/nexus-<v>/ path.
#   It extracts into the staging root as TWO siblings:
#       nexus-<version>/          <- install-dir (bin, etc, lib, jdk, deploy, ...)
#       sonatype-work/nexus3/     <- data-dir parent (bundled skeleton; created if missing)
#
#   Therefore:
#     - extracted app root is  ${stage_dir}/nexus-<version>   (single level)
#     - we extract into an ISOLATED staging dir so the bundled sonatype-work/
#       can NEVER shadow or overwrite the live data at /app/sonatype-work.
#     - version strings are full (e.g. 3.94.0-12), matching the tarball name.
#
# Upgrade: downloads + stages new Nexus, copies configs, promotes to /app/nexus,
#          updates Jetty maxThreads, fixes keystore filename + passwords, starts service
# Rollback: restores the most recent backup of the prior version back to /app/nexus
#
# -------------------------- SAMPLE COMMANDS ---------------------------------
# Run as root on the Nexus host. Use FULL version strings (with the -NN build
# suffix) exactly as they appear in the tarball name.
#
# Upgrade in place (from the running version to a new one):
#   sudo ./nexus-upgrade-rollback.sh upgrade  --from 3.89.0-09 --to 3.94.0-12
#
# Roll back to the previous version (restores the backup the upgrade made):
#   sudo ./nexus-upgrade-rollback.sh rollback --restore 3.89.0-09 --current 3.94.0-12
#
# Show full usage / notes:
#   ./nexus-upgrade-rollback.sh --help
#
# ALWAYS take a database/blob backup BEFORE upgrading — a data-dir downgrade is
# not supported, so rollback only restores the install directory.
# -----------------------------------------------------------------------------

BASE_DIR="/app"
ACTIVE_DIR="${BASE_DIR}/nexus"
NEXUS_USER="nexus"   # change if your service user differs

# Where Nexus downloads live (Sonatype download host).
# Modern linux tarball name: nexus-<version>-linux-x86_64.tar.gz
tarball_name() {
  local v="$1"
  echo "nexus-${v}-linux-x86_64.tar.gz"
}

download_url() {
  local v="$1"
  echo "https://download.sonatype.com/nexus/3/$(tarball_name "$v")"
}

die() { echo "ERROR: $*" >&2; exit 1; }

need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run as root (service control, /app writes, chown)."
}

have_user() {
  id "${NEXUS_USER}" >/dev/null 2>&1 || die "User '${NEXUS_USER}' not found. Update NEXUS_USER in script."
}

svc_stop() {
  echo "==> Stopping nexus service"
  if command -v systemctl >/dev/null 2>&1 && systemctl list-units --type=service | grep -qE '^nexus\.service'; then
    systemctl stop nexus
  else
    service nexus stop
  fi
}

svc_start() {
  echo "==> Starting nexus service"
  if command -v systemctl >/dev/null 2>&1 && systemctl list-units --type=service | grep -qE '^nexus\.service'; then
    systemctl start nexus
  else
    service nexus start
  fi
}

svc_restart() {
  echo "==> Restarting nexus service"
  if command -v systemctl >/dev/null 2>&1 && systemctl list-units --type=service | grep -qE '^nexus\.service'; then
    systemctl restart nexus
  else
    service nexus restart
  fi
}

# Backups created on upgrade look like:
#   /app/nexus-<OLD_VERSION>-YYYYmmdd-HHMMSS
latest_backup_for_version() {
  local v="$1"
  ls -1dt "${BASE_DIR}/nexus-${v}-"* 2>/dev/null | head -n1 || true
}

copy_configs() {
  local from="$1"   # /app/nexus (current active install-dir)
  local to="$2"     # extracted new install-dir (e.g. /app/nexus-<new>-stage/nexus-<new>)

  echo "==> Copying configuration files from ${from} to ${to}"
  mkdir -p "${to}/bin" "${to}/etc/jetty" "${to}/etc/ssl"

  # Required copies
  cp -av "${from}/bin/nexus.vmoptions"          "${to}/bin/"
  #cp -av "${from}/etc/jetty/jetty-https.xml"    "${to}/etc/jetty/"
  #cp -av "${from}/etc/jetty/jetty-http.xml"     "${to}/etc/jetty/"
  cp -av "${from}/etc/ssl/."                    "${to}/etc/ssl/"

  # Optional (not present in all installations)
  if [[ -f "${from}/bin/nexus.rc" ]]; then
    cp -av "${from}/bin/nexus.rc" "${to}/bin/"
  else
    echo "==> NOTE: ${from}/bin/nexus.rc not found; skipping (service may be systemd-based)."
  fi

  # -------------------------------------------------------------------------
  # Java 21 truststore note (Nexus 3.87.0+):
  #   The bundled JDK's truststore is NOT reused across installs. If you added
  #   CA certs to the OLD bundled JDK cacerts (for LDAP / SAML / proxy repos),
  #   re-import them into the new runtime, or point the new install at an
  #   external truststore via nexus.vmoptions. We do NOT copy jdk/ wholesale
  #   because that would defeat the point of shipping a new JDK.
  # -------------------------------------------------------------------------
  if [[ -f "${from}/etc/ssl/truststore.jks" ]]; then
    echo "==> Copying external truststore.jks (etc/ssl) to new install"
    cp -av "${from}/etc/ssl/truststore.jks" "${to}/etc/ssl/" || true
  fi
}

update_jetty_maxthreads_upgrade_only() {
  local jetty_xml="/app/nexus/etc/jetty/jetty.xml"

  if [[ ! -f "$jetty_xml" ]]; then
    echo "==> NOTE: ${jetty_xml} not found; skipping maxThreads update."
    return 0
  fi

  echo "==> Updating Jetty maxThreads in ${jetty_xml} to 2500 (upgrade only)"
  cp -a "$jetty_xml" "${jetty_xml}.bak.$(date +%Y%m%d-%H%M%S)"

  # Replace any numeric value inside <Set name="maxThreads">...</Set> with 2500
  sed -i -E 's|(<Set[[:space:]]+name="maxThreads">)[0-9]+(</Set>)|\12500\2|' "$jetty_xml"

  echo "==> maxThreads now:"
  grep -n 'name="maxThreads"' "$jetty_xml" || true
}

fix_keystore_filename_and_passwords_upgrade_only() {
  local ssl_dir="/app/nexus/etc/ssl"
  local jetty_https="/app/nexus/etc/jetty/jetty-https.xml"

  # 1) Copy nexus-keystore.jks -> keystore.jks (because default jetty-https.xml looks for keystore.jks)
  local src_keystore="${ssl_dir}/nexus-keystore.jks"
  local dst_keystore="${ssl_dir}/keystore.jks"

  if [[ -f "$src_keystore" ]]; then
    echo "==> Copying keystore: ${src_keystore} -> ${dst_keystore} (upgrade only)"
    cp -a "$src_keystore" "$dst_keystore"
  else
    echo "==> NOTE: ${src_keystore} not found; skipping keystore copy."
    echo "          If jetty-https.xml expects keystore.jks, Nexus HTTPS may fail."
  fi

  # 2) Update passwords in jetty-https.xml (3 places) to 'changeit'
  if [[ -f "$jetty_https" ]]; then
    echo "==> Updating keystore/truststore passwords to 'changeit' in ${jetty_https} (upgrade only)"
    cp -a "$jetty_https" "${jetty_https}.bak.$(date +%Y%m%d-%H%M%S)"

    # Update the values between tags for these three <Set> entries:
    #  - KeyStorePassword
    #  - KeyManagerPassword
    #  - trustStorePassword
    sed -i -E \
      -e 's|(<Set name="KeyStorePassword">)[^<]*(</Set>)|\1changeit\2|g' \
      -e 's|(<Set name="KeyManagerPassword">)[^<]*(</Set>)|\1changeit\2|g' \
      -e 's|(<Set name="TrustStorePassword">)[^<]*(</Set>)|\1changeit\2|g' \
      -e 's|(<Set name="trustStorePassword">)[^<]*(</Set>)|\1changeit\2|g' \
      "$jetty_https"

    echo "==> Password entries now:"
    grep -nE 'KeyStorePassword|KeyManagerPassword|trustStorePassword' "$jetty_https" || true
  else
    echo "==> NOTE: ${jetty_https} not found; skipping password updates."
  fi

  # NOTE (FIPS): 3.94.0-12 also ships etc/jetty/jetty-https-fips.xml. This function only
  # edits the standard jetty-https.xml. If you run Nexus in FIPS mode, apply the same
  # keystore-filename and password changes to jetty-https-fips.xml as well.
  if [[ -f "/app/nexus/etc/jetty/jetty-https-fips.xml" ]]; then
    echo "==> NOTE: jetty-https-fips.xml present. If running FIPS, mirror these edits there too (not done automatically)."
  fi
}

upgrade() {
  local from_version="$1"  # manually provided currently-running version (labels backup)
  local to_version="$2"    # new version to install (full, e.g. 3.94.0-12)

  [[ -d "$ACTIVE_DIR" ]] || die "Expected active Nexus at ${ACTIVE_DIR} not found."
  [[ "$from_version" != "$to_version" ]] || die "from_version equals to_version; nothing to do."

  echo "==> Upgrading Nexus"
  echo "==> From: ${from_version}"
  echo "==> To:   ${to_version}"

  # Isolated staging dir. We extract here so the tarball's bundled
  # sonatype-work/ skeleton lands in staging and can NEVER touch live data.
  local stage_dir="${BASE_DIR}/nexus-${to_version}-stage"

  # Modern layout: single-level install-dir directly under the staging root.
  local extracted_dir="${stage_dir}/nexus-${to_version}"

  [[ ! -e "$stage_dir" ]] || die "Staging directory already exists: ${stage_dir} (remove it and retry)."

  echo "==> Creating staging directory: ${stage_dir}"
  mkdir -p "$stage_dir"
  cd "$stage_dir"

  local tb url
  tb="$(tarball_name "$to_version")"
  url="$(download_url "$to_version")"

  echo "==> Downloading: ${tb}"
  echo "==> From:        ${url}"
  curl -fL -o "$tb" "$url"

  echo "==> Extracting tarball into ${stage_dir}"
  # --keep-directory-symlink is required by Sonatype so extraction does not
  # clobber symlinked directories. -z because the artifact is gzip-compressed.
  tar -xzvf "$tb" --keep-directory-symlink

  # Sanity-check the extracted layout.
  [[ -d "$extracted_dir" ]] || die "Expected extracted install dir not found: ${extracted_dir}
     (Extraction layout changed? Contents of ${stage_dir}:
      $(ls -1 "$stage_dir"))"
  [[ -d "${extracted_dir}/bin" && -d "${extracted_dir}/etc" && -d "${extracted_dir}/jdk" ]] \
     || die "Extracted dir ${extracted_dir} missing bin/, etc/, or jdk/ — not a valid 3.87.0+ install-dir (partial extract?)."

  # The tarball also drops a bundled sonatype-work/ skeleton in staging.
  # We intentionally leave it behind — the live data dir is untouched.
  if [[ -d "${stage_dir}/sonatype-work" ]]; then
    echo "==> NOTE: bundled sonatype-work/ present in staging; leaving it behind (live data untouched)."
  fi

  svc_stop

  # Copy required configs from the active install into the new install-dir.
  copy_configs "$ACTIVE_DIR" "$extracted_dir"

  # Ownership for the extracted install-dir.
  echo "==> Setting ownership (${NEXUS_USER}) on ${extracted_dir}"
  chown -R "${NEXUS_USER}" "$extracted_dir"

  # Backup old active install.
  local ts backup_dir
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_dir="${BASE_DIR}/nexus-${from_version}-${ts}"

  echo "==> Backing up current active install:"
  echo "    ${ACTIVE_DIR} -> ${backup_dir}"
  mv "$ACTIVE_DIR" "$backup_dir"

  # Promote new install-dir to active. /app/nexus now contains bin/, etc/, jdk/, deploy/, ...
  # (In 3.94.0-12 the app jar lives at bin/sonatype-nexus-repository-<v>.jar; there is no top-level lib/.)
  echo "==> Promoting extracted install-dir to active:"
  echo "    ${extracted_dir} -> ${ACTIVE_DIR}"
  mv "$extracted_dir" "$ACTIVE_DIR"

  # Clean up the (now near-empty) staging dir; ignore the leftover sonatype-work skeleton.
  echo "==> Removing staging directory: ${stage_dir}"
  rm -rf "$stage_dir"

  # --- Upgrade-only config tweaks before starting service ---
  update_jetty_maxthreads_upgrade_only
  fix_keystore_filename_and_passwords_upgrade_only
  # ---------------------------------------------------------

  # Ensure active dir ownership (in case anything was created/copied as root during tweaks).
  echo "==> Ensuring ownership (${NEXUS_USER}) on ${ACTIVE_DIR}"
  chown -R "${NEXUS_USER}" "$ACTIVE_DIR"

  svc_start

  echo
  echo "Upgrade complete."
  echo "Backup directory (for rollback): ${backup_dir}"
  echo "Active install:                 ${ACTIVE_DIR}"
  echo
  echo "Post-upgrade reminders:"
  echo "  - Tail \$NEXUS_DATA/log/nexus.log for FATAL/ERROR/WARN and 'Started Sonatype Nexus Repository.'"
  echo "  - If you use LDAP/SAML/proxy repos, confirm CA certs are trusted by the new bundled JDK 21."
  echo "  - Verify HTTPS comes up (keystore.jks present, passwords correct)."
}

rollback() {
  local restore_version="$1"  # OLD version you want to restore (backed up on upgrade)
  local current_version="$2"  # version currently active (used only to label preserved dir)

  [[ -d "$ACTIVE_DIR" ]] || die "Expected active Nexus at ${ACTIVE_DIR} not found."
  [[ "$restore_version" != "$current_version" ]] || die "restore_version equals current_version; nothing to rollback."

  echo "==> Rolling back Nexus"
  echo "==> Restoring (old) version: ${restore_version}"
  echo "==> Current (to preserve):   ${current_version}"
  echo
  echo "WARNING: Nexus does NOT support downgrading the DATA directory. A rollback of"
  echo "         the install-dir only works if the DATA dir was NOT yet migrated by the"
  echo "         newer version, or if you also restore the data dir / DB from backup."
  echo "         If the new version already migrated the data dir, restore the database"
  echo "         backup taken before the upgrade instead."
  echo

  local backup_dir
  backup_dir="$(latest_backup_for_version "$restore_version")"
  [[ -n "$backup_dir" && -d "$backup_dir" ]] || die "No backup found for version ${restore_version} (expected ${BASE_DIR}/nexus-${restore_version}-<timestamp>)."

  echo "==> Using backup: ${backup_dir}"

  svc_stop

  local ts preserve_dir
  ts="$(date +%Y%m%d-%H%M%S)"
  preserve_dir="${BASE_DIR}/nexus-${current_version}-rollback-${ts}"

  echo "==> Preserving current active install:"
  echo "    ${ACTIVE_DIR} -> ${preserve_dir}"
  mv "$ACTIVE_DIR" "$preserve_dir"

  echo "==> Restoring backup to active:"
  echo "    ${backup_dir} -> ${ACTIVE_DIR}"
  mv "$backup_dir" "$ACTIVE_DIR"

  echo "==> Ensuring ownership (${NEXUS_USER}) on ${ACTIVE_DIR}"
  chown -R "${NEXUS_USER}" "$ACTIVE_DIR"

  svc_start

  echo
  echo "Rollback complete."
  echo "Restored from:           ${backup_dir}"
  echo "Previous active saved:   ${preserve_dir}"
  echo "Active install:          ${ACTIVE_DIR}"
}

usage() {
  cat <<EOF
Usage:
  sudo $0 upgrade  --from <CURRENT_VERSION> --to <UPGRADE_VERSION>
  sudo $0 rollback --restore <OLD_VERSION_TO_RESTORE> --current <CURRENT_ACTIVE_VERSION>

Examples:
  sudo $0 upgrade  --from 3.89.0-09 --to 3.94.0-12
  sudo $0 rollback --restore 3.89.0-09 --current 3.94.0-12

Notes:
  - Use FULL versions matching the tarball name (e.g. 3.94.0-12, not 3.94.0).
  - Upgrade extracts into an isolated staging dir (/app/nexus-<v>-stage) so the
    tarball's bundled sonatype-work/ skeleton can never shadow your live data.
  - The linux tarball extracts to a SINGLE-level install-dir (nexus-<version>/),
    not a nested nexus-<v>/nexus-<v>/ path.
  - Upgrade creates a backup of the old active install:
      /app/nexus-<OLD_VERSION>-YYYYmmdd-HHMMSS
  - Rollback restores the most recent matching backup directory (see data-dir warning).

Upgrade-only extra steps included:
  - Update /app/nexus/etc/jetty/jetty.xml maxThreads to 2500
  - Copy /app/nexus/etc/ssl/nexus-keystore.jks -> keystore.jks
  - Update passwords in /app/nexus/etc/jetty/jetty-https.xml:
      KeyStorePassword, KeyManagerPassword, trustStorePassword => changeit

IMPORTANT PRE-UPGRADE:
  - Take a PostgreSQL DB backup (or verified PITR) BEFORE upgrading. Downgrade of the
    data dir is not supported; recovery is via restore-from-backup.
EOF
}

main() {
  need_root
  have_user

  [[ $# -ge 1 ]] || { usage; exit 1; }

  local action="$1"
  shift

  local from_version=""
  local to_version=""
  local restore_version=""
  local current_version=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from)    shift; from_version="${1:-}"; shift ;;
      --to)      shift; to_version="${1:-}"; shift ;;
      --restore) shift; restore_version="${1:-}"; shift ;;
      --current) shift; current_version="${1:-}"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  case "$action" in
    upgrade)
      [[ -n "$from_version" ]] || die "Missing --from <CURRENT_VERSION>"
      [[ -n "$to_version" ]]   || die "Missing --to <UPGRADE_VERSION>"
      upgrade "$from_version" "$to_version"
      ;;
    rollback)
      [[ -n "$restore_version" ]] || die "Missing --restore <OLD_VERSION_TO_RESTORE>"
      [[ -n "$current_version" ]] || die "Missing --current <CURRENT_ACTIVE_VERSION>"
      rollback "$restore_version" "$current_version"
      ;;
    *)
      die "Unknown action: ${action} (expected: upgrade|rollback)"
      ;;
  esac
}

main "$@"
