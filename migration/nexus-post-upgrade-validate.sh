#!/usr/bin/env bash
set -uo pipefail
# NOTE: intentionally NOT using `set -e` — we want every check to run and
# report pass/fail, rather than aborting on the first failure.

# =============================================================================
# Nexus Repository — Post-Upgrade Validation (HTTP test-replica edition)
# =============================================================================
# Purpose:
#   Run after upgrading a Nexus replica to smoke-test that repositories work:
#   UI/health, repo list online, and real pull/push against Docker, Maven,
#   npm, PyPI, raw, and yum repositories.
#
# Designed for an HTTP-only test server (no TLS). Your PRODUCTION box uses
# HTTPS; the only differences you should have to change there are the scheme
# (http -> https), the ports, and removing the Docker insecure-registry step.
#
# Everything you must change is in the CONFIG block below, marked <<< EDIT.
# Any check whose placeholder is left blank is SKIPPED (not failed), so you
# can enable formats incrementally.
#
# IMPORTANT — Docker over HTTP:
#   Docker refuses plain-HTTP registries unless the daemon is told to trust
#   them. On Docker Desktop (your local machines), add your test registry to
#   Settings -> Docker Engine JSON:
#       "insecure-registries": ["TEST_HOST:8082", "TEST_HOST:8083"]
#   then Apply & Restart. This script detects the failure mode and reminds you.
#
# Usage:
#   chmod +x nexus-post-upgrade-validate.sh
#   ./nexus-post-upgrade-validate.sh                 # run all configured checks
#   ./nexus-post-upgrade-validate.sh --only docker   # run one section
#   ./nexus-post-upgrade-validate.sh --list          # list section names
#   NEXUS_PASS='secret' ./nexus-post-upgrade-validate.sh   # avoid hardcoding pw
# =============================================================================


# ============================ CONFIG — <<< EDIT ==============================

# --- Nexus core -------------------------------------------------------------
NEXUS_SCHEME="http"                 # <<< EDIT: http on test replica; https in prod
NEXUS_HOST="localhost"              # <<< EDIT: test server hostname or IP
NEXUS_PORT="8080"                   # <<< EDIT: main UI / REST API port
NEXUS_CONTEXT="/nexus"              # <<< EDIT: UI/REST context path. Use "" if Nexus is at the root.
                                    #     Applies to UI + REST + repository (Maven/npm/PyPI/raw/yum) URLs.
                                    #     Does NOT apply to Docker connector ports (those serve at root).
NEXUS_USER="admin"                  # <<< EDIT
NEXUS_PASS="${NEXUS_PASS:-changeme}"  # <<< EDIT or export NEXUS_PASS to avoid hardcoding

# Base URL for the REST API and UI. Usually leave as-is.
# Trailing slash on the context is stripped so we never produce a double slash.
NEXUS_CONTEXT="${NEXUS_CONTEXT%/}"
NEXUS_URL="${NEXUS_SCHEME}://${NEXUS_HOST}:${NEXUS_PORT}${NEXUS_CONTEXT}"

# --- Local scratch ----------------------------------------------------------
WORK_DIR="$(mktemp -d /tmp/nexus-validate.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

# --- Docker -----------------------------------------------------------------
# Nexus typically exposes Docker on dedicated connector ports, NOT 8081.
# A hosted repo and a proxy repo each usually get their own port.
DOCKER_ENABLE="true"                       # <<< EDIT: "true" to run docker checks
DOCKER_REGISTRY_HOST="${NEXUS_HOST}"       # <<< EDIT: host clients connect to (your EC2 IP, inherited)
DOCKER_PROXY_PORT="8132"                   # <<< connector port for the docker-hub PROXY repo
DOCKER_HOSTED_PORT="8143"                  # <<< connector port for the docker HOSTED repo (push target)
DOCKER_PROXY_IMAGE="alpine:latest"         # <<< image pulled through the proxy (proxies Docker Hub)
# Hosted push test: build a self-contained image and push it under YOUR hosted
# image name:tag, mirroring real usage. Build stays FROM scratch so it needs no
# base image present locally.
DOCKER_HOSTED_IMAGE="alpine-jdk17"         # <<< hosted image name (repo/name part)
DOCKER_HOSTED_TAG="3.23"                   # <<< hosted image tag
# Full push ref resolves to: ${DOCKER_REGISTRY_HOST}:${DOCKER_HOSTED_PORT}/${DOCKER_HOSTED_IMAGE}:${DOCKER_HOSTED_TAG}
# NOTE: no group repository is used (none configured).

# --- Maven ------------------------------------------------------------------
MAVEN_ENABLE="true"                        # <<< EDIT
# Path to an artifact known to exist in your Maven proxy/group. Format:
#   <repo>/<groupId-with-slashes>/<artifactId>/<version>/<artifactId>-<version>.jar
MAVEN_REPO_PATH="maven-public"             # <<< EDIT: repo or group name
MAVEN_ARTIFACT_PATH="junit/junit/4.13.2/junit-4.13.2.jar"  # <<< EDIT: a small known artifact
# Optional deploy test to a hosted repo (needs deploy privileges):
MAVEN_DEPLOY_ENABLE="false"                # <<< EDIT: "true" to test upload
MAVEN_HOSTED_REPO="maven-releases"         # <<< EDIT: hosted repo to deploy into

# --- npm --------------------------------------------------------------------
NPM_ENABLE="true"                          # <<< EDIT
NPM_REPO="npm-public"                      # <<< EDIT: npm proxy/group repo name
NPM_PACKAGE="lodash"                       # <<< EDIT: a package your proxy can fetch
NPM_PACKAGE_VERSION="4.17.21"              # <<< EDIT: specific version (tarball fetch)

# --- PyPI -------------------------------------------------------------------
PYPI_ENABLE="true"                         # <<< EDIT
PYPI_REPO="pypi-public"                    # <<< EDIT: pypi proxy/group repo name
PYPI_PACKAGE="six"                         # <<< EDIT: a small pure-python package

# --- raw --------------------------------------------------------------------
RAW_ENABLE="false"                         # <<< EDIT
RAW_REPO="raw-hosted"                      # <<< EDIT: raw repo name
RAW_TEST_PATH="validation/ping.txt"        # path we upload+download (hosted repo only)

# --- yum --------------------------------------------------------------------
YUM_ENABLE="false"                         # <<< EDIT
YUM_REPO="yum-proxy"                       # <<< EDIT: yum proxy/group repo name
YUM_REPOMD_PATH="repodata/repomd.xml"      # standard metadata path; usually leave as-is

# ========================== END CONFIG ======================================


# ------------------------------ plumbing ------------------------------------
PASS=0; FAIL=0; SKIP=0
RESULTS=()

c_green="\033[0;32m"; c_red="\033[0;31m"; c_yellow="\033[0;33m"; c_blue="\033[0;34m"; c_off="\033[0m"

pass() { echo -e "  ${c_green}PASS${c_off}  $1"; PASS=$((PASS+1)); RESULTS+=("PASS  $1"); }
fail() { echo -e "  ${c_red}FAIL${c_off}  $1"; FAIL=$((FAIL+1)); RESULTS+=("FAIL  $1"); }
skip() { echo -e "  ${c_yellow}SKIP${c_off}  $1"; SKIP=$((SKIP+1)); RESULTS+=("SKIP  $1"); }
info() { echo -e "  ${c_blue}··${c_off}   $1"; }
section() { echo; echo -e "${c_blue}=== $1 ===${c_off}"; }

curl_auth() { curl -sS -u "${NEXUS_USER}:${NEXUS_PASS}" "$@"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# HTTP status of a URL (authenticated GET), or 000 on connection failure.
http_status() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' -u "${NEXUS_USER}:${NEXUS_PASS}" "$1" 2>/dev/null)"
  echo "${code:-000}"
}


# ------------------------- check: core health -------------------------------
check_core() {
  section "Core health"

  # 1) UI reachable
  local ui_status; ui_status="$(http_status "${NEXUS_URL}/")"
  if [[ "$ui_status" == "200" ]]; then
    pass "UI reachable at ${NEXUS_URL}/ (HTTP 200)"
  else
    fail "UI not reachable at ${NEXUS_URL}/ (HTTP ${ui_status}) — is the service up? correct port?"
  fi

  # 2) Status endpoint (readiness)
  local st; st="$(http_status "${NEXUS_URL}/service/rest/v1/status")"
  if [[ "$st" == "200" ]]; then
    pass "Status endpoint healthy (/service/rest/v1/status = 200)"
  else
    fail "Status endpoint returned HTTP ${st}"
  fi

  # 3) Writable check (available for write)
  local stw; stw="$(http_status "${NEXUS_URL}/service/rest/v1/status/writable")"
  if [[ "$stw" == "200" ]]; then
    pass "Instance is available for WRITE (/status/writable = 200)"
  else
    info "Writable check returned HTTP ${stw} (ok if read-only mode is intended)"
  fi

  # 4) Version banner (helps confirm you're on the new build)
  local server_hdr; server_hdr="$(curl -sS -I -u "${NEXUS_USER}:${NEXUS_PASS}" "${NEXUS_URL}/" 2>/dev/null | grep -i '^Server:' || true)"
  [[ -n "$server_hdr" ]] && info "Server header: ${server_hdr#Server: }"
}


# --------------------- check: repositories online ---------------------------
check_repositories() {
  section "Repository inventory"

  local body
  body="$(curl_auth "${NEXUS_URL}/service/rest/v1/repositorySettings" 2>/dev/null)" || true
  if [[ -z "$body" ]]; then
    # fall back to the older repositories endpoint
    body="$(curl_auth "${NEXUS_URL}/service/rest/v1/repositories" 2>/dev/null)" || true
  fi

  if [[ -z "$body" ]]; then
    fail "Could not retrieve repository list from REST API"
    return
  fi

  local count
  if have_cmd jq; then
    count="$(echo "$body" | jq 'length' 2>/dev/null || echo 0)"
    pass "Repository list retrieved (${count} repositories configured)"
    echo "$body" | jq -r '.[] | "       - \(.name) [\(.format)/\(.type)]"' 2>/dev/null | head -40
  else
    count="$(echo "$body" | grep -o '"name"' | wc -l | tr -d ' ')"
    pass "Repository list retrieved (~${count} repositories; install jq for detail)"
  fi
  info "Tip: confirm each repo shows 'Online' in the UI (Administration → Repository → Repositories)."
}


# ----------------------------- check: docker --------------------------------
check_docker() {
  section "Docker (pull via proxy, build+push to hosted)"
  [[ "$DOCKER_ENABLE" == "true" ]] || { skip "Docker checks disabled (DOCKER_ENABLE=false)"; return; }

  if ! have_cmd docker; then
    skip "docker CLI not found on this host"
    return
  fi
  if ! docker info >/dev/null 2>&1; then
    fail "docker daemon not reachable (is Docker Desktop running?)"
    return
  fi

  local proxy_reg="${DOCKER_REGISTRY_HOST}:${DOCKER_PROXY_PORT}"
  local hosted_reg="${DOCKER_REGISTRY_HOST}:${DOCKER_HOSTED_PORT}"

  # Remind about insecure-registries for HTTP
  if [[ "$NEXUS_SCHEME" == "http" ]]; then
    info "HTTP registry: ensure Docker daemon has insecure-registries: [\"${proxy_reg}\", \"${hosted_reg}\"]"
  fi

  # docker login to the proxy connector
  if echo "${NEXUS_PASS}" | docker login "${proxy_reg}" -u "${NEXUS_USER}" --password-stdin >/dev/null 2>&1; then
    pass "docker login succeeded → ${proxy_reg}"
  else
    fail "docker login failed → ${proxy_reg} (check insecure-registries for HTTP, port, and credentials)"
    return
  fi

  # Pull through the proxy
  local proxy_ref="${proxy_reg}/${DOCKER_PROXY_IMAGE}"
  if docker pull "${proxy_ref}" >/dev/null 2>&1; then
    pass "Pulled image through proxy: ${proxy_ref}"
    docker rmi "${proxy_ref}" >/dev/null 2>&1 || true
  else
    fail "Pull failed through proxy: ${proxy_ref} (proxy repo online? upstream reachable? insecure-registry set?)"
  fi

  # Build a tiny local image and push to the hosted repo under YOUR image name:tag
  local build_dir="${WORK_DIR}/docker-build"
  mkdir -p "$build_dir"
  # scratch-based image with a single file → no dependency on any base image being present
  printf 'FROM scratch\nCOPY hello.txt /hello.txt\n' > "${build_dir}/Dockerfile"
  echo "nexus upgrade validation ${DOCKER_HOSTED_IMAGE}:${DOCKER_HOSTED_TAG} $(date -u +%FT%TZ)" > "${build_dir}/hello.txt"

  local push_ref="${hosted_reg}/${DOCKER_HOSTED_IMAGE}:${DOCKER_HOSTED_TAG}"

  # login to hosted connector (may be same creds, different port)
  echo "${NEXUS_PASS}" | docker login "${hosted_reg}" -u "${NEXUS_USER}" --password-stdin >/dev/null 2>&1 || true

  if docker build -t "${push_ref}" "${build_dir}" >/dev/null 2>&1; then
    if docker push "${push_ref}" >/dev/null 2>&1; then
      pass "Built and pushed image to hosted repo: ${push_ref}"
      # round-trip: remove local, pull back
      docker rmi "${push_ref}" >/dev/null 2>&1 || true
      if docker pull "${push_ref}" >/dev/null 2>&1; then
        pass "Pulled back pushed image (round-trip OK): ${push_ref}"
        docker rmi "${push_ref}" >/dev/null 2>&1 || true
      else
        fail "Could not pull back the image just pushed: ${push_ref}"
      fi
    else
      fail "Push failed to hosted repo: ${push_ref} (hosted repo online? deploy privileges? insecure-registry set?)"
    fi
  else
    fail "docker build failed for validation image (unexpected)"
  fi

  docker logout "${proxy_reg}"  >/dev/null 2>&1 || true
  docker logout "${hosted_reg}" >/dev/null 2>&1 || true
}


# ----------------------------- check: maven ---------------------------------
check_maven() {
  section "Maven (download artifact; optional deploy)"
  [[ "$MAVEN_ENABLE" == "true" ]] || { skip "Maven checks disabled (MAVEN_ENABLE=false)"; return; }

  local url="${NEXUS_URL}/repository/${MAVEN_REPO_PATH}/${MAVEN_ARTIFACT_PATH}"
  local out="${WORK_DIR}/$(basename "$MAVEN_ARTIFACT_PATH")"

  if curl_auth -f -o "$out" "$url" 2>/dev/null && [[ -s "$out" ]]; then
    pass "Downloaded Maven artifact: ${MAVEN_REPO_PATH}/${MAVEN_ARTIFACT_PATH} ($(wc -c <"$out") bytes)"
  else
    fail "Could not download Maven artifact from ${url}"
  fi

  if [[ "$MAVEN_DEPLOY_ENABLE" == "true" ]]; then
    local gav_path="com/example/nexus-validate/1.0.0/nexus-validate-1.0.0.txt"
    local deploy_url="${NEXUS_URL}/repository/${MAVEN_HOSTED_REPO}/${gav_path}"
    local payload="${WORK_DIR}/nexus-validate-1.0.0.txt"
    echo "nexus upgrade validation $(date -u +%FT%TZ)" > "$payload"
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' -u "${NEXUS_USER}:${NEXUS_PASS}" \
              --upload-file "$payload" "$deploy_url" 2>/dev/null || echo 000)"
    if [[ "$code" =~ ^20[0-9]$ ]]; then
      pass "Deployed test file to ${MAVEN_HOSTED_REPO} (HTTP ${code})"
    else
      fail "Deploy to ${MAVEN_HOSTED_REPO} returned HTTP ${code} (privileges? repo allows redeploy?)"
    fi
  else
    skip "Maven deploy test disabled (MAVEN_DEPLOY_ENABLE=false)"
  fi
}


# ------------------------------ check: npm ----------------------------------
check_npm() {
  section "npm (fetch package metadata + tarball)"
  [[ "$NPM_ENABLE" == "true" ]] || { skip "npm checks disabled (NPM_ENABLE=false)"; return; }

  # metadata
  local meta_url="${NEXUS_URL}/repository/${NPM_REPO}/${NPM_PACKAGE}"
  local mstatus; mstatus="$(http_status "$meta_url")"
  if [[ "$mstatus" == "200" ]]; then
    pass "npm metadata OK: ${NPM_REPO}/${NPM_PACKAGE}"
  else
    fail "npm metadata fetch failed (HTTP ${mstatus}) at ${meta_url}"
  fi

  # tarball (path convention: <pkg>/-/<pkg>-<version>.tgz)
  local tgz_url="${NEXUS_URL}/repository/${NPM_REPO}/${NPM_PACKAGE}/-/${NPM_PACKAGE}-${NPM_PACKAGE_VERSION}.tgz"
  local out="${WORK_DIR}/${NPM_PACKAGE}-${NPM_PACKAGE_VERSION}.tgz"
  if curl_auth -f -o "$out" "$tgz_url" 2>/dev/null && [[ -s "$out" ]]; then
    pass "npm tarball downloaded: ${NPM_PACKAGE}@${NPM_PACKAGE_VERSION} ($(wc -c <"$out") bytes)"
  else
    fail "npm tarball download failed at ${tgz_url}"
  fi
}


# ------------------------------ check: pypi ---------------------------------
check_pypi() {
  section "PyPI (simple index reachable)"
  [[ "$PYPI_ENABLE" == "true" ]] || { skip "PyPI checks disabled (PYPI_ENABLE=false)"; return; }

  # Simple index for a package: /repository/<repo>/simple/<pkg>/
  local idx_url="${NEXUS_URL}/repository/${PYPI_REPO}/simple/${PYPI_PACKAGE}/"
  local status; status="$(http_status "$idx_url")"
  if [[ "$status" == "200" ]]; then
    pass "PyPI simple index OK: ${PYPI_REPO}/simple/${PYPI_PACKAGE}/"
  else
    fail "PyPI simple index failed (HTTP ${status}) at ${idx_url}"
  fi

  # Optional real install proof (only if pip present)
  if have_cmd pip3 || have_cmd pip; then
    local pipbin; pipbin="$(command -v pip3 || command -v pip)"
    local venv="${WORK_DIR}/pipvenv"
    if have_cmd python3 && python3 -m venv "$venv" >/dev/null 2>&1; then
      # shellcheck disable=SC1091
      source "${venv}/bin/activate"
      if pip install --quiet --index-url "${NEXUS_URL}/repository/${PYPI_REPO}/simple/" \
            --trusted-host "${NEXUS_HOST}" "${PYPI_PACKAGE}" >/dev/null 2>&1; then
        pass "pip install ${PYPI_PACKAGE} succeeded via Nexus index"
      else
        fail "pip install ${PYPI_PACKAGE} via Nexus index failed (trusted-host set for HTTP?)"
      fi
      deactivate || true
    else
      info "python3 venv unavailable; skipped live pip install (index check above still ran)"
    fi
  else
    info "pip not found; skipped live pip install (index check above still ran)"
  fi
}


# ------------------------------ check: raw ----------------------------------
check_raw() {
  section "raw (upload + download round-trip)"
  [[ "$RAW_ENABLE" == "true" ]] || { skip "raw checks disabled (RAW_ENABLE=false)"; return; }

  local url="${NEXUS_URL}/repository/${RAW_REPO}/${RAW_TEST_PATH}"
  local payload="${WORK_DIR}/raw-ping.txt"
  echo "nexus raw validation $(date -u +%FT%TZ)" > "$payload"

  local up_code
  up_code="$(curl -sS -o /dev/null -w '%{http_code}' -u "${NEXUS_USER}:${NEXUS_PASS}" \
              --upload-file "$payload" "$url" 2>/dev/null || echo 000)"
  if [[ "$up_code" =~ ^20[0-9]$ ]]; then
    pass "raw upload OK → ${RAW_REPO}/${RAW_TEST_PATH} (HTTP ${up_code})"
  else
    fail "raw upload failed (HTTP ${up_code}) → ${url}"
    return
  fi

  local out="${WORK_DIR}/raw-download.txt"
  if curl_auth -f -o "$out" "$url" 2>/dev/null && diff -q "$payload" "$out" >/dev/null 2>&1; then
    pass "raw download round-trip OK (content matches)"
  else
    fail "raw download/content-match failed at ${url}"
  fi
}


# ------------------------------ check: yum ----------------------------------
check_yum() {
  section "yum (repodata metadata reachable)"
  [[ "$YUM_ENABLE" == "true" ]] || { skip "yum checks disabled (YUM_ENABLE=false)"; return; }

  local url="${NEXUS_URL}/repository/${YUM_REPO}/${YUM_REPOMD_PATH}"
  local status; status="$(http_status "$url")"
  if [[ "$status" == "200" ]]; then
    pass "yum repomd.xml reachable: ${YUM_REPO}/${YUM_REPOMD_PATH}"
  else
    fail "yum repomd.xml fetch failed (HTTP ${status}) at ${url}"
  fi
}


# ------------------------------- runner -------------------------------------
# NOTE: no associative arrays here — macOS ships Bash 3.2, which doesn't support
# `declare -A`. Section name → function is done with a case statement so this
# runs on Bash 3.2+ everywhere.
ORDER="core repos docker maven npm pypi raw yum"

run_section() {
  case "$1" in
    core)   check_core ;;
    repos)  check_repositories ;;
    docker) check_docker ;;
    maven)  check_maven ;;
    npm)    check_npm ;;
    pypi)   check_pypi ;;
    raw)    check_raw ;;
    yum)    check_yum ;;
    *)      echo "Unknown section: $1 (see --list)"; return 1 ;;
  esac
}

usage() {
  cat <<EOF
Nexus post-upgrade validation (HTTP test-replica)

Usage:
  $0                 Run all sections
  $0 --only NAME     Run one section (repeatable): ${ORDER}
  $0 --list          List section names
  $0 -h | --help     Show this help

Environment:
  NEXUS_PASS         Password (preferred over editing the file)

Edit the CONFIG block at the top to point at your test server's host, ports,
repo names, and sample images/artifacts. Blank/disabled sections are skipped.
EOF
}

main() {
  # space-separated list of sections to run when --only is used
  local only=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --only) shift; only="${only} ${1:-}"; shift ;;
      --list) for s in $ORDER; do echo "$s"; done; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown arg: $1"; usage; exit 1 ;;
    esac
  done

  echo -e "${c_blue}Nexus post-upgrade validation${c_off}"
  echo "Target: ${NEXUS_URL}  (user: ${NEXUS_USER})"
  [[ "$NEXUS_SCHEME" == "http" ]] && echo -e "${c_yellow}Mode: HTTP (test replica). Remember Docker insecure-registries.${c_off}"

  local to_run="$ORDER"
  # trim leading space; if --only was given, use that list instead
  only="$(echo "$only" | sed 's/^ *//')"
  [[ -n "$only" ]] && to_run="$only"

  for name in $to_run; do
    run_section "$name"
  done

  # ---- summary ----
  section "Summary"
  printf '  %bPASS%b: %d   %bFAIL%b: %d   %bSKIP%b: %d\n' \
    "$c_green" "$c_off" "$PASS" "$c_red" "$c_off" "$FAIL" "$c_yellow" "$c_off" "$SKIP"

  if [[ "$FAIL" -gt 0 ]]; then
    echo
    echo "Failures:"
    for r in "${RESULTS[@]}"; do [[ "$r" == FAIL* ]] && echo "  - ${r#FAIL  }"; done
    exit 1
  fi
  exit 0
}

main "$@"
