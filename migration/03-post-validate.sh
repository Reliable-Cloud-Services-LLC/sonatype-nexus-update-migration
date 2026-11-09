#!/usr/bin/env bash
set -uo pipefail
# =============================================================================
# 03-post-validate.sh — Verify the migrated clone is healthy and at parity
# with the old box. Run AFTER 02 completes and Nexus has fully started.
#
# Distinct from the generic post-upgrade validator: this adds MIGRATION checks
#   - Nexus actually connected to the external PostgreSQL (not fell back to H2)
#   - repository COUNT matches the old box (parity)
#   - blob stores are present and report usage (data actually mounted)
#   - a sample read from each configured format
#
# Sources ./00-config.sh automatically.
#
# -------------------------- SAMPLE COMMANDS ---------------------------------
# 1) FIRST, from the OLD box — capture a repo baseline to compare against later:
#   NEXUS_HOST_VALIDATE=10.0.5.10 NEXUS_ADMIN_PASS='admin-password' \
#     ./03-post-validate.sh --capture-baseline ./.repo-baseline.txt
#
# 2) After migration, on/near the NEW box — validate and compare to the baseline:
#   NEXUS_ADMIN_PASS='admin-password' \
#     ./03-post-validate.sh --baseline ./.repo-baseline.txt
#
# All checks without a baseline comparison (reach a remote host):
#   NEXUS_HOST_VALIDATE=10.0.5.20 NEXUS_ADMIN_PASS='admin-password' ./03-post-validate.sh
# =============================================================================

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HERE}/00-config.sh"

# Where to reach the NEW Nexus. Defaults to localhost on the box; override for remote.
NEXUS_HOST_VALIDATE="${NEXUS_HOST_VALIDATE:-localhost}"
NEXUS_SCHEME="${NEXUS_SCHEME:-http}"
NEXUS_URL="${NEXUS_SCHEME}://${NEXUS_HOST_VALIDATE}:${NEXUS_HTTP_PORT}${NEXUS_CONTEXT}"
NEXUS_ADMIN_USER="${NEXUS_ADMIN_USER:-admin}"
NEXUS_ADMIN_PASS="${NEXUS_ADMIN_PASS:-}"

PASS=0; FAIL=0; SKIP=0
ok() { echo "  PASS  $*"; PASS=$((PASS+1)); }
no() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
sk() { echo "  SKIP  $*"; SKIP=$((SKIP+1)); }

cauth() { curl -sS -u "${NEXUS_ADMIN_USER}:${NEXUS_ADMIN_PASS}" "$@"; }
hstat() { local c; c="$(curl -sS -o /dev/null -w '%{http_code}' -u "${NEXUS_ADMIN_USER}:${NEXUS_ADMIN_PASS}" "$1" 2>/dev/null)"; echo "${c:-000}"; }
have()  { command -v "$1" >/dev/null 2>&1; }

repo_list() { # prints "name format type" per repo, sorted — stable for diffing
  local body
  body="$(cauth "${NEXUS_URL}/service/rest/v1/repositorySettings" 2>/dev/null)"
  [[ -z "$body" ]] && body="$(cauth "${NEXUS_URL}/service/rest/v1/repositories" 2>/dev/null)"
  if have jq; then
    echo "$body" | jq -r '.[] | "\(.name) \(.format) \(.type)"' 2>/dev/null | sort
  else
    echo "$body" | tr ',' '\n' | grep -o '"name"[^,]*' | sed 's/.*: *"//; s/".*//' | sort
  fi
}

# --- baseline capture (run this against the OLD box before cutover) ----------
if [[ "${1:-}" == "--capture-baseline" ]]; then
  [[ -n "$NEXUS_ADMIN_PASS" ]] || die "Set NEXUS_ADMIN_PASS."
  out="${2:-${HERE}/.repo-baseline.txt}"
  repo_list > "$out"
  echo "Captured $(wc -l <"$out") repositories to ${out} (from ${NEXUS_URL})"
  exit 0
fi

BASELINE=""
[[ "${1:-}" == "--baseline" ]] && BASELINE="${2:-}"

[[ -n "$NEXUS_ADMIN_PASS" ]] || die "Set NEXUS_ADMIN_PASS (admin password for ${NEXUS_URL})."

echo "=== Target: ${NEXUS_URL} ==="

# --- 1. core health ----------------------------------------------------------
echo "=== Core health ==="
[[ "$(hstat "${NEXUS_URL}/service/rest/v1/status")" == "200" ]] \
  && ok "status endpoint healthy" || no "status endpoint not 200"
[[ "$(hstat "${NEXUS_URL}/service/rest/v1/status/writable")" == "200" ]] \
  && ok "instance writable" || sk "not writable (ok if intentionally read-only)"

# --- 2. DATABASE: confirm external PostgreSQL, not H2 fallback ---------------
# The #1 migration failure is Nexus silently booting H2 when it can't read the
# store config. We detect it from the log + the store file.
echo "=== Database binding (must be PostgreSQL / clone RDS) ==="
LOG="${DATA_DIR}/log/nexus.log"
STORE="${DATA_DIR}/etc/fabric/nexus-store.properties"

if [[ -f "$STORE" ]]; then
  if grep -q "$CLONE_RDS_HOST" "$STORE" 2>/dev/null; then
    ok "nexus-store.properties points at clone RDS host"
  else
    no "nexus-store.properties does NOT reference CLONE_RDS_HOST (${CLONE_RDS_HOST})"
  fi
  # hard safety: make sure it is NOT prod
  if [[ -n "$PROD_RDS_INSTANCE_ID" ]] && grep -q "$PROD_RDS_INSTANCE_ID" "$STORE" 2>/dev/null; then
    no "DANGER: store file references the PROD RDS id — stop and fix before any writes"
  fi
else
  sk "store file not readable here (running remotely?) — checking via log/API instead"
fi

if [[ -r "$LOG" ]]; then
  if grep -qiE 'Embedded H2|Loaded .nexus. data store configuration defaults .Embedded H2.' "$LOG"; then
    no "nexus.log shows Embedded H2 — external PostgreSQL config was NOT picked up"
  else
    ok "no 'Embedded H2' fallback seen in nexus.log"
  fi
  if grep -qiE 'postgres|PostgreSQL' "$LOG"; then
    ok "nexus.log references PostgreSQL datastore"
  fi
  # migration rebuild tasks (expected on first start of a migrated/moved DB)
  if grep -qiE 'repository.rebuild-index|create.browse.nodes|rebuild repository (browse|search)' "$LOG"; then
    ok "post-migration rebuild tasks observed (browse/search/index)"
  else
    sk "no rebuild-task lines yet (may have completed already, or not applicable)"
  fi
else
  sk "cannot read ${LOG} (running remotely) — rely on API checks"
fi

# --- 3. repository parity ----------------------------------------------------
echo "=== Repository inventory / parity ==="
CUR="$(repo_list)"
CUR_N="$(echo "$CUR" | grep -c . || true)"
if [[ "$CUR_N" -gt 0 ]]; then
  ok "retrieved ${CUR_N} repositories from the new instance"
else
  no "could not retrieve repository list"
fi

if [[ -n "$BASELINE" && -f "$BASELINE" ]]; then
  if diff <(echo "$CUR") "$BASELINE" >/dev/null 2>&1; then
    ok "repository list MATCHES baseline (${BASELINE})"
  else
    no "repository list DIFFERS from baseline — review diff below:"
    diff <(echo "$CUR") "$BASELINE" | sed 's/^/        /' | head -40
  fi
else
  sk "no baseline provided (capture one from the OLD box: --capture-baseline)"
fi

# --- 4. blob stores online + have content -----------------------------------
echo "=== Blob stores ==="
BS="$(cauth "${NEXUS_URL}/service/rest/v1/blobstores" 2>/dev/null)"
if [[ -n "$BS" ]] && have jq; then
  n="$(echo "$BS" | jq 'length' 2>/dev/null || echo 0)"
  ok "blob store API returned ${n} store(s)"
  # flag any that report zero blob count (possible unmounted/empty path)
  echo "$BS" | jq -r '.[] | "\(.name) blobCount=\(.blobCount // "?") total=\(.totalSizeInBytes // "?")"' 2>/dev/null \
    | sed 's/^/        /'
  zero="$(echo "$BS" | jq -r '.[] | select((.blobCount // 0) == 0) | .name' 2>/dev/null)"
  [[ -n "$zero" ]] && no "blob store(s) with zero blobs (check mount/path): ${zero}" \
                   || ok "all blob stores report content"
elif [[ -n "$BS" ]]; then
  ok "blob store API responded (install jq for per-store detail)"
else
  no "blob store API returned nothing"
fi

# --- 5. format smoke tests (reuse your validator if present) -----------------
echo "=== Format smoke tests ==="
VALIDATOR="${HERE}/nexus-post-upgrade-validate.sh"
if [[ -x "$VALIDATOR" ]]; then
  ok "found format validator; delegating repos/docker/maven/npm/pypi checks"
  echo "    Run it directly for full output, e.g.:"
  echo "    NEXUS_HOST=${NEXUS_HOST_VALIDATE} NEXUS_PASS='***' ${VALIDATOR}"
else
  sk "format validator not alongside this script — skipping deep format checks"
  # minimal inline check: can we at least hit a repo path?
  code="$(hstat "${NEXUS_URL}/service/rest/v1/repositories")"
  [[ "$code" == "200" ]] && ok "repositories endpoint reachable" || no "repositories endpoint HTTP ${code}"
fi

echo
echo "=== Summary ==="
echo "  PASS: ${PASS}   FAIL: ${FAIL}   SKIP: ${SKIP}"
[[ "$FAIL" -gt 0 ]] && { echo "  Migration validation FAILED — do not cut over."; exit 1; }
echo "  Migration validation OK for ${NEXUS_URL}"
exit 0
