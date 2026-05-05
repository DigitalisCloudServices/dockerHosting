#!/usr/bin/env bash
# lib/update-site.sh
#
# Generic site updater — pulls the latest artifacts from GCS and restarts
# stale Docker services.  Called by the systemd timer on every poll cycle
# and by deploy-site.sh on first bootstrap.
#
# The server has no knowledge of GitHub, git, or the build process — only a
# GCS service account key.  Artifact types are declared in the GCS channel
# metadata (e.g. main-latest.json):
#
#   infra   — docker-compose.yml, nginx, Kong, scripts (extracted to project root)
#   others  — arbitrary named artifacts bind-mounted into containers as
#             /run/artifact.tar.gz.  Which services consume which artifact is
#             declared via a Docker label on the service:
#               labels:
#                 artifact: <name>
#
# Usage:
#   lib/update-site.sh <deploy-dir> [options]
#
# Options:
#   --trigger <bootstrap|update>  Lifecycle hook trigger (default: update)
#   --pull-only                   Download artifacts but do not restart containers
#   --skip-artifact-download      Use cached artifacts; skip GCS (combine with --force to restart)
#   --force                       Force-recreate all containers even if up to date
#   --dry-run                     Report staleness but make no changes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── GCS helpers ───────────────────────────────────────────────────────────────
# shellcheck source=gcs.sh
source "${SCRIPT_DIR}/gcs.sh"

# ── Argument parsing ──────────────────────────────────────────────────────────

PROJECT_DIR="${1:?Usage: $0 <deploy-dir> [--trigger bootstrap|update] [--pull-only] [--skip-artifact-download] [--force] [--dry-run]}"
shift

TRIGGER="update"
PULL_ONLY=false
SKIP_DOWNLOAD=false
FORCE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --trigger)
            TRIGGER="${2:?--trigger requires a value: bootstrap|update}"
            shift 2
            ;;
        --pull-only)              PULL_ONLY=true;     shift ;;
        --skip-artifact-download) SKIP_DOWNLOAD=true; shift ;;
        --force)                  FORCE=true;         shift ;;
        --dry-run)                DRY_RUN=true;       shift ;;
        *) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Paths ─────────────────────────────────────────────────────────────────────

ARTIFACT_CACHE="${PROJECT_DIR}/artifact-cache"
DECRYPT_SH="${SCRIPT_DIR}/decrypt.sh"
DOTENV="${PROJECT_DIR}/.env"
GCS_KEY_FILE="${PROJECT_DIR}/infra/secrets/gcs_service_account.json"

# ── Helpers ───────────────────────────────────────────────────────────────────

_ts()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
_log()  { echo "  [update] [$(_ts)] $*"; }
_warn() { echo "  [update] [$(_ts)] WARN: $*" >&2; }
_fail() { echo "FATAL [update]: $*" >&2; exit 1; }

_dotenv_get() {
    local key="$1"
    [[ -f "${DOTENV}" ]] || return 1
    grep -E "^${key}=" "${DOTENV}" | tail -1 | cut -d= -f2- | tr -d '"' || true
}

_dotenv_set() {
    local key="$1" value="$2"
    if grep -qE "^${key}=" "${DOTENV}" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${DOTENV}"
    else
        echo "${key}=${value}" >> "${DOTENV}"
    fi
}

# ── Validate environment ──────────────────────────────────────────────────────

[[ -f "${DOTENV}" ]]     || _fail ".env not found at ${DOTENV}"
[[ -f "${DECRYPT_SH}" ]] || _fail "decrypt.sh not found at ${DECRYPT_SH}"
[[ -f "${GCS_KEY_FILE}" ]] || _fail "GCS service account key not found at ${GCS_KEY_FILE}"

GCS_BUCKET="$(_dotenv_get GCS_BUCKET)"
[[ -n "${GCS_BUCKET}" ]] || _fail "GCS_BUCKET not set in ${DOTENV} — was deploy-site.sh run?"

RELEASE_CHANNEL="$(_dotenv_get RELEASE_CHANNEL)"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-main-latest}"
CHANNEL_URL="${GCS_BUCKET}/channels/${RELEASE_CHANNEL}.json"

cd "${PROJECT_DIR}"

# ── Lifecycle hooks ───────────────────────────────────────────────────────────

HOOKS_FILE="${PROJECT_DIR}/infra/lifecycle-hooks.json"
HOOKS_SNAPSHOT="[]"
if [[ -f "${HOOKS_FILE}" ]]; then
    HOOKS_SNAPSHOT="$(python3 -c \
        "import json; d=json.load(open('${HOOKS_FILE}')); print(json.dumps(d.get('hooks', [])))" \
        2>/dev/null || echo "[]")"
fi

_run_hooks() {
    local phase="$1"
    local scripts
    scripts="$(echo "${HOOKS_SNAPSHOT}" | python3 -c "
import json, sys
for h in json.load(sys.stdin):
    if h.get('trigger') == sys.argv[1] and h.get('phase') == sys.argv[2]:
        print(h['script'])
" "${TRIGGER}" "${phase}" 2>/dev/null || true)"
    [[ -z "${scripts}" ]] && return 0
    while IFS= read -r s; do
        [[ -z "${s}" ]] && continue
        local f="${PROJECT_DIR}/${s}"
        if [[ -f "${f}" ]]; then
            _log "Hook [${TRIGGER}/${phase}]: ${s}"
            bash "${f}" || _fail "Hook failed: ${s}"
        else
            _warn "Hook not found (skipping): ${f}"
        fi
    done <<< "${scripts}"
}

# ── Fetch channel metadata ────────────────────────────────────────────────────

ARTIFACT_NAMES=()
ARTIFACT_FILES=()
ARTIFACT_HASHES=()

if [[ "${SKIP_DOWNLOAD}" != "true" ]]; then
    _log "Fetching channel metadata from GCS..."

    GCS_TOKEN="$(_gcs_access_token "${GCS_KEY_FILE}")" \
        || _fail "Failed to obtain GCS access token — check service account key at ${GCS_KEY_FILE}"

    CHANNEL_META="$(curl -fsSL \
        -H "Authorization: Bearer ${GCS_TOKEN}" \
        "$(_gcs_https_url "${CHANNEL_URL}")")"

    CHANNEL_INFRA_HASH="$(echo "${CHANNEL_META}"     | python3 -c "import json,sys; print(json.load(sys.stdin).get('infra_hash',''))")"
    CHANNEL_INFRA_ARTIFACT="$(echo "${CHANNEL_META}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('infra_artifact',''))")"

    readarray -t ARTIFACT_NAMES  < <(echo "${CHANNEL_META}" | python3 -c "import json,sys; [print(a['name'])     for a in json.load(sys.stdin).get('artifacts',[])]")
    readarray -t ARTIFACT_FILES  < <(echo "${CHANNEL_META}" | python3 -c "import json,sys; [print(a['artifact']) for a in json.load(sys.stdin).get('artifacts',[])]")
    readarray -t ARTIFACT_HASHES < <(echo "${CHANNEL_META}" | python3 -c "import json,sys; [print(a['git_hash']) for a in json.load(sys.stdin).get('artifacts',[])]")

    [[ -n "${CHANNEL_INFRA_ARTIFACT}" ]] \
        || _fail "channel metadata is missing infra_artifact — trigger a new CI build and re-run."

    _log "Channel: infra=${CHANNEL_INFRA_HASH:0:12}  artifacts=(${ARTIFACT_NAMES[*]:-none})"
else
    CHANNEL_INFRA_HASH="$(_dotenv_get INFRA_HASH || echo '')"
    CHANNEL_INFRA_ARTIFACT="$(basename "$(_dotenv_get INFRA_ARTIFACT || echo '')")"
    _names_csv="$(_dotenv_get ARTIFACT_NAMES || echo '')"
    if [[ -n "${_names_csv}" ]]; then
        IFS=',' read -ra ARTIFACT_NAMES <<< "${_names_csv}"
        for _n in "${ARTIFACT_NAMES[@]}"; do
            ARTIFACT_HASHES+=("$(_dotenv_get "${_n^^}_GIT_HASH" || echo '')")
        done
    fi
    _log "Skip-download mode: using pinned data from .env"
fi

# ── Detect stale artifacts ────────────────────────────────────────────────────

INFRA_STALE=false
ARTIFACT_STALE=()

if [[ "${FORCE}" == "true" ]]; then
    INFRA_STALE=true
    for _i in "${!ARTIFACT_NAMES[@]}"; do ARTIFACT_STALE+=(true); done
else
    _running_infra="$(_dotenv_get INFRA_HASH || echo '')"
    [[ "${_running_infra}" != "${CHANNEL_INFRA_HASH}" ]] && INFRA_STALE=true
    _log "Infra:  running=${_running_infra:0:12}  channel=${CHANNEL_INFRA_HASH:0:12}  stale=${INFRA_STALE}"

    for _i in "${!ARTIFACT_NAMES[@]}"; do
        _running="$(_dotenv_get "${ARTIFACT_NAMES[$_i]^^}_GIT_HASH" || echo '')"
        _stale=false
        [[ "${_running}" != "${ARTIFACT_HASHES[$_i]}" ]] && _stale=true
        ARTIFACT_STALE+=("${_stale}")
        _log "$(printf '%-12s' "${ARTIFACT_NAMES[$_i]}"):  running=${_running:0:12}  channel=${ARTIFACT_HASHES[$_i]:0:12}  stale=${_stale}"
    done
fi

# ── Short-circuit if nothing to do ───────────────────────────────────────────

_any_stale=false
[[ "${INFRA_STALE}" == "true" ]] && _any_stale=true
for _i in "${!ARTIFACT_STALE[@]}"; do
    [[ "${ARTIFACT_STALE[$_i]}" == "true" ]] && _any_stale=true
done

if [[ "${_any_stale}" == "false" ]]; then
    _log "All artifacts up to date — nothing to do."
    exit 0
fi

if [[ "${DRY_RUN}" == "true" ]]; then
    _stale_names=()
    [[ "${INFRA_STALE}" == "true" ]] && _stale_names+=(infra)
    for _i in "${!ARTIFACT_NAMES[@]}"; do
        [[ "${ARTIFACT_STALE[$_i]:-false}" == "true" ]] && _stale_names+=("${ARTIFACT_NAMES[$_i]}")
    done
    _log "Dry-run: would update: ${_stale_names[*]}"
    exit 0
fi

# ── Download stale artifacts ──────────────────────────────────────────────────

mkdir -p "${ARTIFACT_CACHE}"

_download_artifact() {
    local type="$1" artifact_filename="$2"
    local dest="${ARTIFACT_CACHE}/${artifact_filename}"
    local stable="${ARTIFACT_CACHE}/${type}.tar.gz"

    # Docker creates a directory at the bind-mount path if the file doesn't
    # exist when the container starts. Remove it so the download can proceed.
    if [[ -d "${dest}" ]]; then
        _warn "${type}: removing directory at cache path (Docker created it before artifact existed): ${dest}"
        rm -rf "${dest}"
    fi

    if [[ -f "${dest}" ]]; then
        _log "${type}: cache hit — ${artifact_filename}"
    else
        _log "${type}: downloading ${artifact_filename} from GCS..."
        local download_tmp="${dest}.download"

        curl -fsSL --retry 3 --retry-delay 5 \
            -H "Authorization: Bearer ${GCS_TOKEN}" \
            -o "${download_tmp}" \
            "$(_gcs_https_url "${GCS_BUCKET}/artifacts/${artifact_filename}")"

        _log "${type}: decrypting ${artifact_filename}..."
        local pub_key_file="${PROJECT_DIR}/infra/secrets/artifact_signing_public_key.pem"
        local aes_key_file="${PROJECT_DIR}/infra/secrets/artifact_aes_key.txt"
        if [[ -f "${pub_key_file}" && -f "${aes_key_file}" ]]; then
            ARTIFACT_SIGNING_PUBLIC_KEY="$(cat "${pub_key_file}")" \
            ARTIFACT_AES_KEY="$(cat "${aes_key_file}")" \
            SKIP_ENCRYPTION=false \
            bash "${DECRYPT_SH}" --bundle "${download_tmp}" --out-tar "${dest}"
        else
            SKIP_ENCRYPTION=true bash "${DECRYPT_SH}" \
                --bundle "${download_tmp}" --out-tar "${dest}"
        fi
        rm -f "${download_tmp}"
        chmod 444 "${dest}"

        # Prune old cached versions (keep 3 per type)
        ls -1t "${ARTIFACT_CACHE}/${type}"-*.tar.gz 2>/dev/null \
            | tail -n +4 | xargs rm -f 2>/dev/null || true
    fi

    # Docker may have created a directory at the stable path too (same race condition).
    if [[ -d "${stable}" ]]; then
        _warn "${type}: removing directory at stable path (Docker created it): ${stable}"
        rm -rf "${stable}"
    fi

    # Atomically update the stable cache path (used by --skip-artifact-download and legacy)
    local stable_tmp="${stable}.tmp.$$"
    cp "${dest}" "${stable_tmp}"
    mv "${stable_tmp}" "${stable}"
    chmod 444 "${stable}"
    _log "${type}: cache path updated → ${stable}"
}

_write_to_artifact_volume() {
    local type="$1"
    local stable="${ARTIFACT_CACHE}/${type}.tar.gz"
    local compose_project
    compose_project="$(_dotenv_get COMPOSE_PROJECT_NAME || echo "${PROJECT_DIR##*/}")"
    local vol="${compose_project}_${type}_artifact"

    if [[ -d "${stable}" ]]; then
        _warn "${type}: removing directory at stable path (Docker created it): ${stable}"
        rm -rf "${stable}"
    fi
    [[ -f "${stable}" ]] || _fail "${type}: stable artifact not found at ${stable}"

    _log "${type}: writing artifact into isolated volume ${vol}..."
    docker run --rm \
        -v "${vol}:/dst" \
        -v "${stable}:/src:ro" \
        alpine sh -c 'cp /src /dst/artifact.tar.gz && chmod 444 /dst/artifact.tar.gz' \
        || _fail "${type}: failed to write artifact to volume ${vol}"
    _log "${type}: volume ${vol} updated"
}

if [[ "${SKIP_DOWNLOAD}" != "true" ]]; then
    [[ "${INFRA_STALE}" == "true" ]] && _download_artifact infra "${CHANNEL_INFRA_ARTIFACT}"
    for _i in "${!ARTIFACT_NAMES[@]}"; do
        if [[ "${ARTIFACT_STALE[$_i]:-false}" == "true" ]]; then
            _download_artifact "${ARTIFACT_NAMES[$_i]}" "${ARTIFACT_FILES[$_i]}"
            _write_to_artifact_volume "${ARTIFACT_NAMES[$_i]}"
        fi
    done
else
    # --skip-artifact-download --force: restore from local cache into volumes
    if [[ "${FORCE}" == "true" ]]; then
        for _n in "${ARTIFACT_NAMES[@]}"; do
            _write_to_artifact_volume "${_n}"
        done
    fi
fi

# ── Extract infra artifact if stale ──────────────────────────────────────────

if [[ "${INFRA_STALE}" == "true" ]]; then
    _log "Extracting infra artifact to ${PROJECT_DIR}..."
    tar -xzf "${ARTIFACT_CACHE}/${CHANNEL_INFRA_ARTIFACT}" --strip-components=1 -C "${PROJECT_DIR}"
    _dotenv_set INFRA_HASH     "${CHANNEL_INFRA_HASH}"
    _dotenv_set INFRA_ARTIFACT "./artifact-cache/${CHANNEL_INFRA_ARTIFACT}"
fi

# ── Update .env ───────────────────────────────────────────────────────────────

for _i in "${!ARTIFACT_NAMES[@]}"; do
    [[ "${ARTIFACT_STALE[$_i]:-false}" == "true" ]] \
        && _dotenv_set "${ARTIFACT_NAMES[$_i]^^}_GIT_HASH" "${ARTIFACT_HASHES[$_i]}"
done

# Persist artifact names so --skip-artifact-download works offline
_names_csv="$(IFS=','; echo "${ARTIFACT_NAMES[*]}")"
[[ -n "${_names_csv}" ]] && _dotenv_set ARTIFACT_NAMES "${_names_csv}"

[[ "${PULL_ONLY}" == "true" ]] && { _log "Pull-only mode — skipping container restart."; exit 0; }

# ── Restart stale services ────────────────────────────────────────────────────

# Run pre-start lifecycle hooks (snapshotted before potential infra extraction above)
_run_hooks "pre-start"

_log "Authenticating Docker to Artifact Registry..."
AR_REGISTRY="$(_dotenv_get AR_REGISTRY)"
AR_REGISTRY="${AR_REGISTRY:-europe-docker.pkg.dev}"
if cat "${GCS_KEY_FILE}" | docker login "${AR_REGISTRY}" \
        --username _json_key \
        --password-stdin > /dev/null 2>&1; then
    _log "Docker registry auth OK (${AR_REGISTRY})"
else
    _warn "Docker registry auth failed — images may be stale"
fi

_log "Pulling container images..."
docker compose pull --quiet --ignore-pull-failures

# Return all service names whose `artifact` label matches the given artifact name.
# Requires Docker Compose v2.15+ for --format json.
_services_for_artifact() {
    local artifact_name="$1"
    docker compose config --format json 2>/dev/null \
        | python3 -c "
import json, sys
config = json.load(sys.stdin)
name = sys.argv[1]
for svc, cfg in config.get('services', {}).items():
    labels = cfg.get('labels', {})
    if isinstance(labels, list):
        labels = dict(l.split('=', 1) for l in labels if '=' in l)
    if labels.get('artifact') == name:
        print(svc)
" "${artifact_name}" 2>/dev/null || true
}

if [[ "${INFRA_STALE}" == "true" ]]; then
    _log "Infra updated — restarting all services"
    docker compose up -d --force-recreate
else
    STALE_SERVICES=()
    for _i in "${!ARTIFACT_NAMES[@]}"; do
        if [[ "${ARTIFACT_STALE[$_i]:-false}" == "true" ]]; then
            while IFS= read -r _svc; do
                [[ -n "${_svc}" ]] && STALE_SERVICES+=("${_svc}")
            done < <(_services_for_artifact "${ARTIFACT_NAMES[$_i]}")
        fi
    done
    if [[ ${#STALE_SERVICES[@]} -gt 0 ]]; then
        _log "Restarting stale services: ${STALE_SERVICES[*]}"
        docker compose up -d --force-recreate "${STALE_SERVICES[@]}"
    else
        _warn "No labeled services found for stale artifacts — check 'artifact:' labels in docker-compose.yml"
    fi
fi

# Run post-start lifecycle hooks
_run_hooks "post-start"

_log "Update complete."
docker compose ps
