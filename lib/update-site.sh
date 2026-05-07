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

PROJECT_DIR="${1:?Usage: $0 <deploy-dir> [--trigger bootstrap|update] [--pull-only] [--skip-artifact-download] [--force] [--dry-run] [--always-run-hooks]}"
shift

TRIGGER="update"
PULL_ONLY=false
SKIP_DOWNLOAD=false
FORCE=false
DRY_RUN=false
ALWAYS_RUN_HOOKS=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --trigger)
            TRIGGER="${2:?--trigger requires a value: bootstrap|update}"
            shift 2
            ;;
        --pull-only)              PULL_ONLY=true;           shift ;;
        --skip-artifact-download) SKIP_DOWNLOAD=true;       shift ;;
        --force)                  FORCE=true;               shift ;;
        --dry-run)                DRY_RUN=true;             shift ;;
        --always-run-hooks)       ALWAYS_RUN_HOOKS=true;    shift ;;
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

_START_TS=$(date +%s)

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

GCS_PREFIX="$(_dotenv_get GCS_PREFIX)"
GCS_PREFIX="${GCS_PREFIX#/}"
GCS_PREFIX="${GCS_PREFIX%/}"
GCS_BASE="${GCS_BUCKET}${GCS_PREFIX:+/${GCS_PREFIX}}"

RELEASE_CHANNEL="$(_dotenv_get RELEASE_CHANNEL)"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-main-latest}"
CHANNEL_URL="${GCS_BASE}/channels/${RELEASE_CHANNEL}.json"

cd "${PROJECT_DIR}"

_log "Starting: trigger=${TRIGGER} force=${FORCE} dry-run=${DRY_RUN} pull-only=${PULL_ONLY}"

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
ARTIFACT_STORAGE_CONFIGS=()
ARTIFACT_SIGNED=()
ARTIFACT_ENCRYPTED=()
ARTIFACT_TARGET_DIRS=()

if [[ "${SKIP_DOWNLOAD}" != "true" ]]; then
    _log "Fetching channel metadata from GCS..."

    GCS_TOKEN="$(_gcs_access_token "${GCS_KEY_FILE}")" \
        || _fail "Failed to obtain GCS access token — check service account key at ${GCS_KEY_FILE}"

    CHANNEL_META="$(curl -fsSL \
        -H "Authorization: Bearer ${GCS_TOKEN}" \
        "$(_gcs_https_url "${CHANNEL_URL}")")"

    # Parse new structured infra metadata
    CHANNEL_INFRA_HASH="$(echo "${CHANNEL_META}" | python3 -c "import json,sys; print(json.load(sys.stdin)['infra']['git_hash'])")"
    CHANNEL_INFRA_SIGNED="$(echo "${CHANNEL_META}" | python3 -c "import json,sys; print(json.load(sys.stdin)['infra'].get('signed', True))" | tr '[:upper:]' '[:lower:]')"
    CHANNEL_INFRA_ENCRYPTED="$(echo "${CHANNEL_META}" | python3 -c "import json,sys; print(json.load(sys.stdin)['infra'].get('encrypted', True))" | tr '[:upper:]' '[:lower:]')"
    CHANNEL_INFRA_STORAGE="$(echo "${CHANNEL_META}" | python3 -c "import json,sys; d=json.load(sys.stdin)['infra']; print(json.dumps({k:v for k,v in d.items() if k in ('type','bucket','path','directory','url')}))")"
    
    # Extract filename from storage config
    CHANNEL_INFRA_ARTIFACT="$(python3 - "${CHANNEL_INFRA_STORAGE}" <<'PYEOF'
import json, sys, os
storage = json.loads(sys.argv[1])
storage_type = storage.get('type', 'gcs')
if storage_type == 'local':
    dir_path = storage['directory'].rstrip('/')
    print(os.path.basename(dir_path))
elif storage_type == 'gcs':
    if 'path' in storage:
        print(os.path.basename(storage['path']))
    else:
        sys.exit("GCS storage requires 'path' field")
elif storage_type in ('http', 'https'):
    print(os.path.basename(storage['url']))
PYEOF
)"

    # Parse artifacts array
    readarray -t ARTIFACT_NAMES  < <(echo "${CHANNEL_META}" | python3 -c "import json,sys; [print(a['name']) for a in json.load(sys.stdin).get('artifacts',[])]")
    readarray -t ARTIFACT_HASHES < <(echo "${CHANNEL_META}" | python3 -c "import json,sys; [print(a['git_hash']) for a in json.load(sys.stdin).get('artifacts',[])]")
    readarray -t ARTIFACT_SIGNED < <(echo "${CHANNEL_META}" | python3 -c "import json,sys; [print(str(a.get('signed', True)).lower()) for a in json.load(sys.stdin).get('artifacts',[])]")
    readarray -t ARTIFACT_ENCRYPTED < <(echo "${CHANNEL_META}" | python3 -c "import json,sys; [print(str(a.get('encrypted', True)).lower()) for a in json.load(sys.stdin).get('artifacts',[])]")
    readarray -t ARTIFACT_STORAGE_CONFIGS < <(echo "${CHANNEL_META}" | python3 -c "import json,sys; [print(json.dumps({k:v for k,v in a.items() if k in ('type','bucket','path','directory','url')})) for a in json.load(sys.stdin).get('artifacts',[])]")
    readarray -t ARTIFACT_TARGET_DIRS < <(echo "${CHANNEL_META}" | python3 -c "import json,sys; [print(a.get('target_dir', '')) for a in json.load(sys.stdin).get('artifacts',[])]")
    
    # Extract filenames from storage configs
    for _storage in "${ARTIFACT_STORAGE_CONFIGS[@]}"; do
        _filename="$(python3 - "${_storage}" <<'PYEOF'
import json, sys, os
storage = json.loads(sys.argv[1])
storage_type = storage.get('type', 'gcs')
if storage_type == 'local':
    dir_path = storage['directory'].rstrip('/')
    print(os.path.basename(dir_path))
elif storage_type == 'gcs':
    if 'path' in storage:
        print(os.path.basename(storage['path']))
    else:
        sys.exit("GCS storage requires 'path' field")
elif storage_type in ('http', 'https'):
    print(os.path.basename(storage['url']))
PYEOF
)"
        ARTIFACT_FILES+=("${_filename}")
    done

    [[ -n "${CHANNEL_INFRA_ARTIFACT}" ]] \
        || _fail "channel metadata is missing infra — trigger a new CI build and re-run."

    _log "Channel: infra=${CHANNEL_INFRA_HASH:0:12} (signed=${CHANNEL_INFRA_SIGNED}, encrypted=${CHANNEL_INFRA_ENCRYPTED})  artifacts=(${ARTIFACT_NAMES[*]:-none})"
else
    CHANNEL_INFRA_HASH="$(_dotenv_get INFRA_HASH || echo '')"
    CHANNEL_INFRA_SIGNED="$(_dotenv_get INFRA_SIGNED || echo 'true')"
    CHANNEL_INFRA_ENCRYPTED="$(_dotenv_get INFRA_ENCRYPTED || echo 'true')"
    CHANNEL_INFRA_ARTIFACT="$(basename "$(_dotenv_get INFRA_ARTIFACT || echo '')")"
    _names_csv="$(_dotenv_get ARTIFACT_NAMES || echo '')"
    if [[ -n "${_names_csv}" ]]; then
        IFS=',' read -ra ARTIFACT_NAMES <<< "${_names_csv}"
        for _n in "${ARTIFACT_NAMES[@]}"; do
            ARTIFACT_HASHES+=("$(_dotenv_get "${_n^^}_GIT_HASH" || echo '')")
            ARTIFACT_SIGNED+=("$(_dotenv_get "${_n^^}_SIGNED" || echo 'true')")
            ARTIFACT_ENCRYPTED+=("$(_dotenv_get "${_n^^}_ENCRYPTED" || echo 'true')")
            ARTIFACT_TARGET_DIRS+=("$(_dotenv_get "${_n^^}_TARGET_DIR" || echo '')")
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

# Auto-detect fresh bootstrap: if no containers exist, force hooks to run
if [[ "${_any_stale}" == "false" && "${TRIGGER}" == "bootstrap" ]]; then
    if ! docker compose -f "${PROJECT_DIR}/docker-compose.yml" ps --services 2>/dev/null | grep -q .; then
        _log "Fresh deployment detected (no containers exist) — forcing bootstrap hooks"
        ALWAYS_RUN_HOOKS=true
    fi
fi

if [[ "${_any_stale}" == "false" && "${ALWAYS_RUN_HOOKS}" != "true" ]]; then
    _log "All artifacts up to date — nothing to do."
    exit 0
fi

if [[ "${_any_stale}" == "false" && "${ALWAYS_RUN_HOOKS}" == "true" ]]; then
    _log "All artifacts up to date — running hooks only (--always-run-hooks)."
    _run_hooks "pre-start"
    _run_hooks "post-start"
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
    local type="$1" storage_json="$2" signed="$3" encrypted="$4"
    
    # Check if this is a local directory
    local is_local
    is_local="$(python3 - "${storage_json}" <<'PYEOF'
import json, sys
storage = json.loads(sys.argv[1])
print("true" if storage.get('type') == 'local' and 'directory' in storage else "false")
PYEOF
)"
    
    if [[ "${is_local}" == "true" ]]; then
        # Local directory mode - create symlink in cache
        local local_dir
        local_dir="$(python3 - "${storage_json}" <<'PYEOF'
import json, sys
storage = json.loads(sys.argv[1])
print(storage['directory'])
PYEOF
)"
        
        local artifact_basename
        artifact_basename="$(python3 - "${storage_json}" <<'PYEOF'
import json, sys, os
storage = json.loads(sys.argv[1])
print(os.path.basename(storage['directory'].rstrip('/')))
PYEOF
)"
        
        local symlink="${ARTIFACT_CACHE}/${type}"
        
        _log "${type}: using local directory ${local_dir}"
        
        if [[ ! -d "${local_dir}" ]]; then
            _fail "${type}: local directory does not exist: ${local_dir}"
        fi
        
        # Create or update symlink
        rm -f "${symlink}"
        ln -sf "${local_dir}" "${symlink}"
        
        _log "${type}: symlinked ${symlink} -> ${local_dir}"
        return 0
    fi
    
    # Construct download URL from storage config
    local download_url
    download_url="$(python3 - "${storage_json}" <<'PYEOF'
import json, sys
storage = json.loads(sys.argv[1])
storage_type = storage.get('type', 'gcs')

if storage_type == 'gcs':
    bucket = storage['bucket'].lstrip('gs://')
    if 'path' in storage:
        path = storage['path']
    else:
        sys.exit("GCS storage requires 'path' field")
    print(f"https://storage.googleapis.com/{bucket}/{path}")
elif storage_type in ('http', 'https'):
    print(storage['url'])
else:
    sys.exit(f"Unsupported storage type: {storage_type}")
PYEOF
)"
    
    # Extract filename from storage config
    local artifact_basename
    artifact_basename="$(python3 - "${storage_json}" <<'PYEOF'
import json, sys, os
storage = json.loads(sys.argv[1])
storage_type = storage.get('type', 'gcs')

if storage_type == 'gcs':
    if 'path' in storage:
        print(os.path.basename(storage['path']))
    else:
        sys.exit("GCS storage requires 'path' field")
elif storage_type in ('http', 'https'):
    print(os.path.basename(storage['url']))
PYEOF
)"
    
    local dest="${ARTIFACT_CACHE}/${artifact_basename}"
    local stable="${ARTIFACT_CACHE}/${type}.tar.gz"

    _log "${type}: downloading ${artifact_basename} (signed=${signed}, encrypted=${encrypted})"

    # Docker creates a directory at the bind-mount path if the file doesn't
    # exist when the container starts. Remove it so the download can proceed.
    if [[ -d "${dest}" ]]; then
        _warn "${type}: removing directory at cache path (Docker created it before artifact existed): ${dest}"
        rm -rf "${dest}"
    fi

    if [[ -f "${dest}" ]]; then
        _log "${type}: cache hit — ${artifact_basename}"
    else
        _log "${type}: downloading ${artifact_basename}..."
        local download_tmp="${dest}.download"
        
        curl -fsSL --retry 3 --retry-delay 5 \
            -H "Authorization: Bearer ${GCS_TOKEN}" \
            -o "${download_tmp}" \
            "${download_url}"

        _log "${type}: verifying and decrypting ${artifact_basename}..."
        local pub_key_file="${PROJECT_DIR}/infra/secrets/artifact_signing_public_key.pem"
        local aes_key_file="${PROJECT_DIR}/infra/secrets/artifact_aes_key.txt"
        
        if [[ "${encrypted}" == "true" && "${signed}" == "true" ]]; then
            if [[ -f "${pub_key_file}" && -f "${aes_key_file}" ]]; then
                ARTIFACT_SIGNING_PUBLIC_KEY="$(cat "${pub_key_file}")" \
                ARTIFACT_AES_KEY="$(cat "${aes_key_file}")" \
                SKIP_ENCRYPTION=false \
                SKIP_SIGNATURE=false \
                bash "${DECRYPT_SH}" --bundle "${download_tmp}" --out-tar "${dest}"
            else
                _fail "${type}: artifact requires encryption and signing but keys not found"
            fi
        elif [[ "${encrypted}" == "true" ]]; then
            if [[ -f "${aes_key_file}" ]]; then
                ARTIFACT_AES_KEY="$(cat "${aes_key_file}")" \
                SKIP_ENCRYPTION=false \
                SKIP_SIGNATURE=true \
                bash "${DECRYPT_SH}" --bundle "${download_tmp}" --out-tar "${dest}"
            else
                _fail "${type}: artifact requires encryption but AES key not found"
            fi
        elif [[ "${signed}" == "true" ]]; then
            if [[ -f "${pub_key_file}" ]]; then
                ARTIFACT_SIGNING_PUBLIC_KEY="$(cat "${pub_key_file}")" \
                SKIP_ENCRYPTION=true \
                SKIP_SIGNATURE=false \
                bash "${DECRYPT_SH}" --bundle "${download_tmp}" --out-tar "${dest}"
            else
                _fail "${type}: artifact requires signing but public key not found"
            fi
        else
            SKIP_ENCRYPTION=true SKIP_SIGNATURE=true \
                bash "${DECRYPT_SH}" --bundle "${download_tmp}" --out-tar "${dest}"
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

_extract_to_directory() {
    local type="$1"
    local target_dir="$2"
    local stable="${ARTIFACT_CACHE}/${type}.tar.gz"
    
    # Strip leading/trailing slashes and ensure relative path
    target_dir="${target_dir#/}"
    target_dir="${target_dir%/}"
    
    local extract_path="${PROJECT_DIR}/${target_dir}"
    
    if [[ -d "${stable}" ]]; then
        _warn "${type}: removing directory at stable path (Docker created it): ${stable}"
        rm -rf "${stable}"
    fi
    [[ -f "${stable}" ]] || _fail "${type}: stable artifact not found at ${stable}"
    
    _log "${type}: extracting to ${extract_path}..."
    mkdir -p "${extract_path}"
    tar -xzf "${stable}" -C "${extract_path}"
    _log "${type}: extracted to ${target_dir}/"
}

if [[ "${SKIP_DOWNLOAD}" != "true" ]]; then
    [[ "${INFRA_STALE}" == "true" ]] && _download_artifact infra "${CHANNEL_INFRA_STORAGE}" "${CHANNEL_INFRA_SIGNED}" "${CHANNEL_INFRA_ENCRYPTED}"
    for _i in "${!ARTIFACT_NAMES[@]}"; do
        if [[ "${ARTIFACT_STALE[$_i]:-false}" == "true" ]]; then
            _download_artifact "${ARTIFACT_NAMES[$_i]}" "${ARTIFACT_STORAGE_CONFIGS[$_i]}" "${ARTIFACT_SIGNED[$_i]}" "${ARTIFACT_ENCRYPTED[$_i]}"
            
            # Extract to directory if target_dir is specified, otherwise write to volume
            if [[ -n "${ARTIFACT_TARGET_DIRS[$_i]:-}" ]]; then
                _extract_to_directory "${ARTIFACT_NAMES[$_i]}" "${ARTIFACT_TARGET_DIRS[$_i]}"
            else
                _write_to_artifact_volume "${ARTIFACT_NAMES[$_i]}"
            fi
        fi
    done
else
    # --skip-artifact-download --force: restore from local cache into volumes
    if [[ "${FORCE}" == "true" ]]; then
        for _i in "${!ARTIFACT_NAMES[@]}"; do
            # Only write to volume if no target_dir (volumes only)
            if [[ -z "${ARTIFACT_TARGET_DIRS[$_i]:-}" ]]; then
                _write_to_artifact_volume "${ARTIFACT_NAMES[$_i]}"
            fi
        done
    fi
fi

# ── Extract infra artifact if stale ──────────────────────────────────────────

if [[ "${INFRA_STALE}" == "true" ]]; then
    _log "Extracting infra artifact to ${PROJECT_DIR}..."
    tar -xzf "${ARTIFACT_CACHE}/${CHANNEL_INFRA_ARTIFACT}" -C "${PROJECT_DIR}"
    _dotenv_set INFRA_HASH      "${CHANNEL_INFRA_HASH}"
    _dotenv_set INFRA_SIGNED    "${CHANNEL_INFRA_SIGNED}"
    _dotenv_set INFRA_ENCRYPTED "${CHANNEL_INFRA_ENCRYPTED}"
    _dotenv_set INFRA_ARTIFACT  "./artifact-cache/${CHANNEL_INFRA_ARTIFACT}"
fi

# ── Update .env ───────────────────────────────────────────────────────────────

for _i in "${!ARTIFACT_NAMES[@]}"; do
    if [[ "${ARTIFACT_STALE[$_i]:-false}" == "true" ]]; then
        _dotenv_set "${ARTIFACT_NAMES[$_i]^^}_GIT_HASH"   "${ARTIFACT_HASHES[$_i]}"
        _dotenv_set "${ARTIFACT_NAMES[$_i]^^}_SIGNED"     "${ARTIFACT_SIGNED[$_i]}"
        _dotenv_set "${ARTIFACT_NAMES[$_i]^^}_ENCRYPTED"  "${ARTIFACT_ENCRYPTED[$_i]}"
        _dotenv_set "${ARTIFACT_NAMES[$_i]^^}_TARGET_DIR" "${ARTIFACT_TARGET_DIRS[$_i]:-}"
    fi
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
docker compose -f "${PROJECT_DIR}/docker-compose.yml" pull --quiet --ignore-pull-failures

# Return all service names whose `artifact` label matches the given artifact name.
# Requires Docker Compose v2.15+ for --format json.
_services_for_artifact() {
    local artifact_name="$1"
    docker compose -f "${PROJECT_DIR}/docker-compose.yml" config --format json 2>/dev/null \
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
    docker compose -f "${PROJECT_DIR}/docker-compose.yml" up -d --force-recreate
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
        docker compose -f "${PROJECT_DIR}/docker-compose.yml" up -d --force-recreate "${STALE_SERVICES[@]}"
    else
        _warn "No labeled services found for stale artifacts — check 'artifact:' labels in docker-compose.yml"
    fi
fi

# Run post-start lifecycle hooks
_run_hooks "post-start"

_log "Update complete in $(( $(date +%s) - _START_TS ))s."
docker compose -f "${PROJECT_DIR}/docker-compose.yml" ps

_unhealthy=$(docker compose -f "${PROJECT_DIR}/docker-compose.yml" ps --format json 2>/dev/null \
    | python3 -c "
import json, sys
bad = []
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        s = json.loads(line)
        state  = s.get('State', '')
        health = s.get('Health', '')
        name   = s.get('Name') or s.get('Service', '')
        if state != 'running' or health == 'unhealthy':
            bad.append(f'{name}({state}/{health})')
    except: pass
print(' '.join(bad))
" 2>/dev/null || true)
[[ -n "${_unhealthy}" ]] && _warn "Unhealthy/exited services: ${_unhealthy}"
