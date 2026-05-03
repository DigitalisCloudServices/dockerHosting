#!/usr/bin/env bash
# deploy-site.sh — Deploy a new site from GCS artifacts
#
# Downloads all site components from GCS. No git access required.
# The server only needs a GCS service account key.
#
# Flow:
#   1. Authenticate to GCS with service account key
#   2. Download channel metadata JSON
#   3. Download + extract infra artifact (docker-compose.yml, nginx, Kong, scripts)
#   4. Provision secrets (GCS key, optional encryption keys)
#   5. Download frontend + wordpress artifacts to artifact-cache
#   6. Configure .env, Traefik, logrotate, systemd updater timer
#
# Usage:
#   Interactive:  sudo ./deploy-site.sh
#   Scripted:     sudo ./deploy-site.sh --site-name <name> --gcs-key-file <path> [options]
#
# Options:
#   --site-name <name>       Site name — alphanumeric + hyphens (required)
#   --site-user <user>       System user for site files (default: <site-name>)
#   --deploy-dir <path>      Deployment directory (default: /opt/apps/<site-name>)
#   --gcs-bucket <url>       GCS bucket URL (default: gs://velaair-website-artifacts)
#   --gcs-key-file <path>    Path to GCS service account JSON key file (required)
#   --domain <hostname>      Site hostname for Traefik routing
#   --kong-port <port>       Kong internal HTTPS port (default: auto-detect from 8443)
#   --create-user <yes|no>   Create dedicated system user (default: yes)
#   --setup-logrotate <yes|no> Set up log rotation (default: yes)
#   --setup-timer <yes|no>   Install systemd updater timer (default: yes)
#   --non-interactive        Skip all prompts (requires --site-name and --gcs-key-file)
#   --artifact-aes-key-file <path>          AES-256 key file for artifact decryption (base64)
#   --artifact-signing-pub-key-file <path>  RSA public key file for artifact verification (PEM)

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $1"; }
log_note()  { echo -e "${CYAN}[NOTE]${NC}  $1"; }

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "Run as root: sudo $0 $*"
        exit 1
    fi
}

display_banner() {
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║   dockerHosting — Site Deployment                ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
}

# ── Port helpers ──────────────────────────────────────────────────────────────

find_next_kong_port() {
    local port="${1:-8443}"
    local used=""
    if [[ -d /opt/apps ]]; then
        used=$(grep -rh "^KONG_HTTPS_PORT=" /opt/apps/ 2>/dev/null | \
               cut -d= -f2 | tr -d '"' | sort -n || true)
    fi
    while echo "$used" | grep -qx "$port" || \
          ss -tlnp 2>/dev/null | awk '{print $4}' | grep -q ":${port}$"; do
        port=$((port + 1))
    done
    echo "$port"
}

# ── .env helpers ──────────────────────────────────────────────────────────────

_env_get() {
    local key="$1" file="$2"
    grep -E "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true
}

_env_set() {
    local key="$1" value="$2" file="$3"
    if grep -qE "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

# ── Artifact helpers ──────────────────────────────────────────────────────────

artifact_is_encrypted() {
    local bundle="$1"
    [[ -f "$bundle" ]] || return 1
    tar tzf "$bundle" 2>/dev/null | grep -q "^payload\.enc$"
}

decrypt_artifact() {
    local bundle="$1" dest="$2" decrypt_sh="$3" secrets_dir="$4"
    local pub_key_file="${secrets_dir}/artifact_signing_public_key.pem"
    local aes_key_file="${secrets_dir}/artifact_aes_key.txt"
    if [[ -f "${pub_key_file}" && -f "${aes_key_file}" ]]; then
        ARTIFACT_SIGNING_PUBLIC_KEY="$(cat "${pub_key_file}")" \
        ARTIFACT_AES_KEY="$(cat "${aes_key_file}")" \
        bash "${decrypt_sh}" --bundle "${bundle}" --out-tar "${dest}"
    else
        SKIP_ENCRYPTION=true bash "${decrypt_sh}" \
            --bundle "${bundle}" --out-tar "${dest}"
    fi
}

# ── GCS helpers ──────────────────────────────────────────────────────────────
# Convert gs://bucket/path → https://storage.googleapis.com/bucket/path
_gcs_https_url() { printf 'https://storage.googleapis.com/%s' "${1#gs://}"; }

# Exchange a service account JSON key for a short-lived OAuth2 Bearer token.
# Requires: python3 (stdlib), openssl. No Google Cloud SDK needed.
_gcs_access_token() {
    local sa_file="$1"
    python3 - "$sa_file" <<'PYEOF'
import sys, json, time, base64, subprocess, urllib.request, urllib.parse, tempfile, os

sa = json.load(open(sys.argv[1]))
email   = sa['client_email']
key_pem = sa['private_key']

now = int(time.time())

def b64url(data):
    if isinstance(data, str):
        data = data.encode()
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()

header  = b64url(json.dumps({"alg":"RS256","typ":"JWT"}, separators=(',',':')))
payload = b64url(json.dumps({
    "iss":   email,
    "scope": "https://www.googleapis.com/auth/devstorage.read_only",
    "aud":   "https://oauth2.googleapis.com/token",
    "iat":   now,
    "exp":   now + 3600,
}, separators=(',',':')))

signing_input = f"{header}.{payload}".encode()

with tempfile.NamedTemporaryFile(mode='w', suffix='.pem', delete=False) as kf:
    os.chmod(kf.fileno(), 0o600)
    kf.write(key_pem)
    key_path = kf.name
try:
    sig_bytes = subprocess.check_output(
        ['openssl', 'dgst', '-sha256', '-sign', key_path],
        input=signing_input, stderr=subprocess.DEVNULL
    )
finally:
    os.unlink(key_path)

jwt = f"{header}.{payload}.{b64url(sig_bytes)}"

data = urllib.parse.urlencode({
    "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
    "assertion":  jwt,
}).encode()
resp = urllib.request.urlopen("https://oauth2.googleapis.com/token", data=data)
print(json.loads(resp.read())['access_token'], end='')
PYEOF
}

# ── Systemd timer ─────────────────────────────────────────────────────────────

install_updater_timer() {
    local site_name="$1"
    local deploy_dir="$2"
    local svc_name="${site_name}-updater"
    local update_script="${deploy_dir}/infra/bootstrap/update.sh"

    cat > "/etc/systemd/system/${svc_name}.service" <<EOF
[Unit]
Description=${site_name} — artifact updater
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${deploy_dir}
ExecStart=/bin/bash ${update_script}
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${svc_name}
EOF

    # 15-minute poll with ±5 min random jitter (10-minute window)
    cat > "/etc/systemd/system/${svc_name}.timer" <<EOF
[Unit]
Description=${site_name} — check for artifact updates every 15 minutes

[Timer]
OnBootSec=2min
OnCalendar=*:0/15
RandomizedDelaySec=300
AccuracySec=10
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${svc_name}.timer"
    log_info "Timer enabled: ${svc_name}.timer (every 15 min, ±5 min jitter)"
}

add_update_now_sudoers() {
    local site_user="$1" site_name="$2"
    local sudoers_file="/etc/sudoers.d/updater-${site_user}"
    cat > "$sudoers_file" <<EOF
${site_user} ALL=(root) NOPASSWD: /usr/bin/systemctl start ${site_name}-updater.service
EOF
    chmod 0440 "$sudoers_file"
    chown root:root "$sudoers_file"
    visudo -c -f "$sudoers_file" 2>/dev/null || { rm -f "$sudoers_file"; log_warn "sudoers validation failed"; }
}

create_update_now_helper() {
    local site_name="$1" helpers_dir="$2" site_user="$3"
    mkdir -p "$helpers_dir"
    cat > "${helpers_dir}/update-now" <<HELPER
#!/bin/bash
echo "[${site_name}] Triggering update check..."
sudo systemctl start ${site_name}-updater.service
echo "[${site_name}] Job started — follow logs:"
echo "  journalctl -fu ${site_name}-updater.service"
HELPER
    chmod +x "${helpers_dir}/update-now"
    chown "${site_user}:${site_user}" "${helpers_dir}/update-now"
}

# ── Argument parsing ──────────────────────────────────────────────────────────

parse_args() {
    NON_INTERACTIVE=false
    SITE_NAME=""
    SITE_USER=""
    DEPLOY_DIR=""
    DOMAIN=""
    KONG_PORT=""
    GCS_BUCKET="gs://velaair-website-artifacts"
    GCS_KEY_FILE=""
    ARTIFACT_AES_KEY_FILE=""
    ARTIFACT_SIGNING_PUB_KEY_FILE=""
    CREATE_USER="yes"
    ADD_DOCKER_GROUP="no"
    SETUP_LOGROTATE="yes"
    SETUP_TIMER="yes"

    if [[ $# -eq 0 ]]; then return 0; fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --site-name)        SITE_NAME="$2";     shift 2 ;;
            --site-user)        SITE_USER="$2";     shift 2 ;;
            --deploy-dir)       DEPLOY_DIR="$2";    shift 2 ;;
            --domain)           DOMAIN="$2";        shift 2 ;;
            --kong-port)        KONG_PORT="$2";     shift 2 ;;
            --gcs-bucket)       GCS_BUCKET="$2";    shift 2 ;;
            --gcs-key-file)     GCS_KEY_FILE="$2";  shift 2 ;;
            --artifact-aes-key-file)         ARTIFACT_AES_KEY_FILE="$2";         shift 2 ;;
            --artifact-signing-pub-key-file) ARTIFACT_SIGNING_PUB_KEY_FILE="$2"; shift 2 ;;
            --create-user)      CREATE_USER="$2";   shift 2 ;;
            --setup-logrotate)  SETUP_LOGROTATE="$2"; shift 2 ;;
            --setup-timer)      SETUP_TIMER="$2";   shift 2 ;;
            --non-interactive)  NON_INTERACTIVE=true; shift ;;
            --help|-h)
                grep '^#   ' "$0" | sed 's/^#   //'
                exit 0 ;;
            *)
                log_error "Unknown argument: $1"
                echo "Run with --help for usage."
                exit 1 ;;
        esac
    done

    if [[ -n "$SITE_NAME" && -n "$GCS_KEY_FILE" ]]; then NON_INTERACTIVE=true; fi

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        [[ -n "$SITE_NAME" ]]    || { log_error "--site-name required";    exit 1; }
        [[ -n "$GCS_KEY_FILE" ]] || { log_error "--gcs-key-file required"; exit 1; }
    fi
}

# ── Interactive gathering ─────────────────────────────────────────────────────

gather_interactive() {
    log_info "Please provide the following information:"
    echo ""

    while [[ -z "$SITE_NAME" ]]; do
        read -rp "Site name (alphanumeric + hyphens): " SITE_NAME
    done

    read -rp "System user for site [${SITE_NAME}]: " input
    SITE_USER="${input:-}"

    local default_dir="/opt/apps/${SITE_NAME}"
    read -rp "Deployment directory [${default_dir}]: " input
    DEPLOY_DIR="${input:-$default_dir}"

    read -rp "Site hostname for Traefik (e.g. example.com, optional): " DOMAIN

    echo ""
    log_info "GCS configuration:"
    read -rp "GCS bucket URL [${GCS_BUCKET}]: " input
    GCS_BUCKET="${input:-$GCS_BUCKET}"

    while [[ -z "$GCS_KEY_FILE" || ! -f "$GCS_KEY_FILE" ]]; do
        read -rp "Path to GCS service account JSON key file: " GCS_KEY_FILE
        [[ -f "$GCS_KEY_FILE" ]] || log_warn "File not found: $GCS_KEY_FILE"
    done

    echo ""
    log_info "User setup:"
    read -rp "Create system user '${SITE_USER:-$SITE_NAME}' with nologin shell? [Y/n]: " input
    if [[ "${input,,}" == "n" ]]; then CREATE_USER="no"; fi

    if [[ "$CREATE_USER" == "yes" ]]; then
        echo ""
        log_warn "The docker group grants root-equivalent container access."
        log_note "Sudoers-based restricted access will be set up instead (recommended)."
        read -rp "Add user to docker group anyway? [y/N]: " input
        if [[ "${input,,}" == "y" ]]; then ADD_DOCKER_GROUP="yes"; fi
    fi
    return 0
}

# ── Apply defaults ────────────────────────────────────────────────────────────

apply_defaults() {
    SITE_NAME=$(echo "$SITE_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
    SITE_USER="${SITE_USER:-$SITE_NAME}"
    DEPLOY_DIR="${DEPLOY_DIR:-/opt/apps/$SITE_NAME}"
    CREATE_USER="${CREATE_USER:-yes}"
    SETUP_LOGROTATE="${SETUP_LOGROTATE:-yes}"
    SETUP_TIMER="${SETUP_TIMER:-yes}"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    display_banner
    check_root "$@"
    parse_args "$@"

    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        gather_interactive
    fi
    apply_defaults

    [[ -n "$SITE_NAME" ]]    || { log_error "Site name is required";          exit 1; }
    [[ -n "$GCS_KEY_FILE" ]] || { log_error "GCS service account key required"; exit 1; }
    [[ -f "$GCS_KEY_FILE" ]] || { log_error "GCS key file not found: $GCS_KEY_FILE"; exit 1; }

    # Kong port
    local suggested_port
    suggested_port=$(find_next_kong_port 8443)
    if [[ -z "$KONG_PORT" ]]; then
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            echo ""
            log_info "Kong internal HTTPS port (loopback only, Traefik proxies to this):"
            read -rp "Port [${suggested_port}]: " input
            KONG_PORT="${input:-$suggested_port}"
        else
            KONG_PORT="$suggested_port"
        fi
    fi

    # ── Deployment summary ────────────────────────────────────────────────────
    echo ""
    log_info "════════════════════════════════════════════"
    log_info "Deployment plan:"
    log_info "════════════════════════════════════════════"
    printf "  %-20s %s\n" "Site name:"     "$SITE_NAME"
    printf "  %-20s %s\n" "Deploy dir:"    "$DEPLOY_DIR"
    printf "  %-20s %s\n" "System user:"   "$SITE_USER (nologin)"
    printf "  %-20s %s\n" "Kong port:"     "$KONG_PORT"
    printf "  %-20s %s\n" "Domain:"        "${DOMAIN:-(not set)}"
    printf "  %-20s %s\n" "GCS bucket:"    "$GCS_BUCKET"
    printf "  %-20s %s\n" "GCS key:"       "$GCS_KEY_FILE"
    printf "  %-20s %s\n" "Logrotate:"     "$SETUP_LOGROTATE"
    printf "  %-20s %s\n" "Updater timer:" "$SETUP_TIMER (15 min ±5)"
    log_info "════════════════════════════════════════════"
    echo ""

    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        read -rp "Proceed? [Y/n]: " input
        if [[ "${input,,}" == "n" ]]; then log_warn "Deployment cancelled"; exit 0; fi
    fi

    # ── Replay command ────────────────────────────────────────────────────────
    echo ""
    log_note "Replay command (save for disaster recovery):"
    echo ""
    printf "  sudo %s/deploy-site.sh \\\\\n" "$SCRIPT_DIR"
    printf "    --site-name '%s' \\\\\n" "$SITE_NAME"
    if [[ "$SITE_USER" != "$SITE_NAME" ]]; then printf "    --site-user '%s' \\\\\n" "$SITE_USER"; fi
    printf "    --deploy-dir '%s' \\\\\n" "$DEPLOY_DIR"
    if [[ -n "$DOMAIN" ]]; then printf "    --domain '%s' \\\\\n" "$DOMAIN"; fi
    printf "    --kong-port '%s' \\\\\n" "$KONG_PORT"
    printf "    --gcs-bucket '%s' \\\\\n" "$GCS_BUCKET"
    printf "    --gcs-key-file '%s' \\\\\n" "$GCS_KEY_FILE"
    if [[ -n "$ARTIFACT_AES_KEY_FILE" ]]; then printf "    --artifact-aes-key-file '%s' \\\\\n" "$ARTIFACT_AES_KEY_FILE"; fi
    if [[ -n "$ARTIFACT_SIGNING_PUB_KEY_FILE" ]]; then printf "    --artifact-signing-pub-key-file '%s' \\\\\n" "$ARTIFACT_SIGNING_PUB_KEY_FILE"; fi
    printf "    --setup-timer '%s'\n" "$SETUP_TIMER"
    echo ""

    # ════════════════════════════════════════════════════════════════════════
    # STEP 1: User management
    # ════════════════════════════════════════════════════════════════════════
    log_step "1/8  User management"

    if [[ "$CREATE_USER" == "yes" ]]; then
        if id "$SITE_USER" &>/dev/null; then
            log_info "User '$SITE_USER' already exists"
        else
            useradd -r -M -d "$DEPLOY_DIR" -s /usr/sbin/nologin "$SITE_USER"
            log_info "Created system user: $SITE_USER (nologin)"
        fi
        if [[ "$ADD_DOCKER_GROUP" == "yes" ]]; then
            usermod -aG docker "$SITE_USER"
            log_warn "Added $SITE_USER to docker group"
        fi
    else
        id "$SITE_USER" &>/dev/null \
            || { log_error "User '$SITE_USER' does not exist"; exit 1; }
    fi

    # ════════════════════════════════════════════════════════════════════════
    # STEP 2: Authenticate to GCS + fetch channel metadata
    # ════════════════════════════════════════════════════════════════════════
    log_step "2/8  Authenticating to GCS and fetching channel metadata"

    log_info "Obtaining GCS access token..."
    local GCS_TOKEN
    GCS_TOKEN="$(_gcs_access_token "${GCS_KEY_FILE}")" \
        || { log_error "Failed to obtain GCS access token — check service account key"; exit 1; }

    log_info "Fetching ${GCS_BUCKET}/channels/prod-latest.json..."
    CHANNEL_META="$(curl -fsSL \
        -H "Authorization: Bearer ${GCS_TOKEN}" \
        "$(_gcs_https_url "${GCS_BUCKET}/channels/prod-latest.json")")"

    INFRA_ARTIFACT="$(echo "${CHANNEL_META}"     | python3 -c "import json,sys; print(json.load(sys.stdin)['infra_artifact'])")"
    FRONTEND_ARTIFACT="$(echo "${CHANNEL_META}"  | python3 -c "import json,sys; print(json.load(sys.stdin)['frontend_artifact'])")"
    WORDPRESS_ARTIFACT="$(echo "${CHANNEL_META}" | python3 -c "import json,sys; print(json.load(sys.stdin)['wordpress_artifact'])")"
    INFRA_HASH="$(echo "${CHANNEL_META}"         | python3 -c "import json,sys; print(json.load(sys.stdin).get('infra_hash',''))")"
    FRONTEND_HASH="$(echo "${CHANNEL_META}"      | python3 -c "import json,sys; print(json.load(sys.stdin)['frontend_git_hash'])")"
    WORDPRESS_HASH="$(echo "${CHANNEL_META}"     | python3 -c "import json,sys; print(json.load(sys.stdin)['wordpress_git_hash'])")"

    log_info "Channel metadata:"
    log_info "  infra:     ${INFRA_ARTIFACT}"
    log_info "  frontend:  ${FRONTEND_ARTIFACT}"
    log_info "  wordpress: ${WORDPRESS_ARTIFACT}"

    # ════════════════════════════════════════════════════════════════════════
    # STEP 3: Create deploy directory + download infra artifact
    # ════════════════════════════════════════════════════════════════════════
    log_step "3/8  Deploy directory + infra artifact"

    mkdir -p "${DEPLOY_DIR}"
    mkdir -p "${DEPLOY_DIR}/artifact-cache"
    mkdir -p "${DEPLOY_DIR}/infra/secrets"

    log_info "Downloading infra artifact from GCS..."
    local infra_tmp
    infra_tmp=$(mktemp /tmp/infra-XXXXXX.tar.gz.download)
    curl -fsSL --retry 3 --retry-delay 5 \
        -H "Authorization: Bearer ${GCS_TOKEN}" \
        -o "${infra_tmp}" \
        "$(_gcs_https_url "${GCS_BUCKET}/artifacts/${INFRA_ARTIFACT}")"

    local decrypt_bootstrap="${SCRIPT_DIR}/lib/decrypt.sh"
    [[ -f "${decrypt_bootstrap}" ]] || { log_error "Bundled decrypt.sh missing: ${decrypt_bootstrap}"; exit 1; }

    if artifact_is_encrypted "${infra_tmp}"; then
        if [[ -z "${ARTIFACT_AES_KEY_FILE}" || ! -f "${ARTIFACT_AES_KEY_FILE}" || \
              -z "${ARTIFACT_SIGNING_PUB_KEY_FILE}" || ! -f "${ARTIFACT_SIGNING_PUB_KEY_FILE}" ]]; then
            log_error "Infra artifact is encrypted but no decryption keys were provided."
            log_error "Re-run with:"
            log_error "  --artifact-aes-key-file <path>          (base64 AES-256 key)"
            log_error "  --artifact-signing-pub-key-file <path>  (PEM RSA public key)"
            rm -f "${infra_tmp}"
            exit 1
        fi
        log_info "Decrypting infra artifact..."
        ARTIFACT_AES_KEY="$(cat "${ARTIFACT_AES_KEY_FILE}")" \
        ARTIFACT_SIGNING_PUBLIC_KEY="$(cat "${ARTIFACT_SIGNING_PUB_KEY_FILE}")" \
        SKIP_ENCRYPTION=false \
        bash "${decrypt_bootstrap}" \
            --bundle "${infra_tmp}" \
            --out-tar "${DEPLOY_DIR}/artifact-cache/${INFRA_ARTIFACT}"
    else
        log_info "Staging unencrypted infra artifact..."
        SKIP_ENCRYPTION=true bash "${decrypt_bootstrap}" \
            --bundle "${infra_tmp}" \
            --out-tar "${DEPLOY_DIR}/artifact-cache/${INFRA_ARTIFACT}"
    fi

    log_info "Extracting infra artifact to ${DEPLOY_DIR}..."
    tar -xzf "${DEPLOY_DIR}/artifact-cache/${INFRA_ARTIFACT}" -C "${DEPLOY_DIR}"
    rm -f "${infra_tmp}"
    log_info "Infra extracted"

    # ════════════════════════════════════════════════════════════════════════
    # STEP 4: Ownership + permissions
    # ════════════════════════════════════════════════════════════════════════
    log_step "4/8  Ownership and permissions"

    chown -R "${SITE_USER}:${SITE_USER}" "$DEPLOY_DIR"

    chown root:root "${DEPLOY_DIR}/artifact-cache"
    chmod 755 "${DEPLOY_DIR}/artifact-cache"
    chown root:root "${DEPLOY_DIR}/infra/secrets"
    chmod 700 "${DEPLOY_DIR}/infra/secrets"

    log_info "artifact-cache: 755 root:root"
    log_info "infra/secrets:  700 root:root"

    if [[ -f "$SCRIPT_DIR/scripts/setup-docker-permissions.sh" ]]; then
        bash "$SCRIPT_DIR/scripts/setup-docker-permissions.sh" "$SITE_USER" "$DEPLOY_DIR"
    fi
    if [[ -f "$SCRIPT_DIR/scripts/setup-docker-network.sh" ]]; then
        bash "$SCRIPT_DIR/scripts/setup-docker-network.sh" "$SITE_NAME"
    fi

    local log_dir="/var/log/${SITE_NAME}"
    mkdir -p "$log_dir"
    chown "${SITE_USER}:${SITE_USER}" "$log_dir"

    # ════════════════════════════════════════════════════════════════════════
    # STEP 5: Provision GCS service account key
    # ════════════════════════════════════════════════════════════════════════
    log_step "5/8  GCS service account key"

    local gcs_dest="${DEPLOY_DIR}/infra/secrets/gcs_service_account.json"
    cp "$GCS_KEY_FILE" "$gcs_dest"
    chmod 600 "$gcs_dest"
    chown root:root "$gcs_dest"
    log_info "GCS key → infra/secrets/gcs_service_account.json"

    if [[ -n "${ARTIFACT_AES_KEY_FILE}" && -f "${ARTIFACT_AES_KEY_FILE}" ]]; then
        cp "${ARTIFACT_AES_KEY_FILE}" "${DEPLOY_DIR}/infra/secrets/artifact_aes_key.txt"
        chmod 600 "${DEPLOY_DIR}/infra/secrets/artifact_aes_key.txt"
        chown root:root "${DEPLOY_DIR}/infra/secrets/artifact_aes_key.txt"
        log_info "AES key      → infra/secrets/artifact_aes_key.txt"
    fi
    if [[ -n "${ARTIFACT_SIGNING_PUB_KEY_FILE}" && -f "${ARTIFACT_SIGNING_PUB_KEY_FILE}" ]]; then
        cp "${ARTIFACT_SIGNING_PUB_KEY_FILE}" "${DEPLOY_DIR}/infra/secrets/artifact_signing_public_key.pem"
        chmod 600 "${DEPLOY_DIR}/infra/secrets/artifact_signing_public_key.pem"
        chown root:root "${DEPLOY_DIR}/infra/secrets/artifact_signing_public_key.pem"
        log_info "Signing key  → infra/secrets/artifact_signing_public_key.pem"
    fi

    # ════════════════════════════════════════════════════════════════════════
    # STEP 6: .env setup + download frontend/wordpress artifacts
    # ════════════════════════════════════════════════════════════════════════
    log_step "6/8  Environment (.env) + artifact download"

    local env_file="${DEPLOY_DIR}/.env"
    if [[ ! -f "$env_file" ]]; then touch "$env_file"; fi

    _env_set "KONG_HTTPS_PORT"    "$KONG_PORT"          "$env_file"
    if [[ -n "$DOMAIN" ]]; then _env_set "SITE_HOSTNAME" "$DOMAIN" "$env_file"; fi
    _env_set "INFRA_HASH"         "$INFRA_HASH"         "$env_file"
    _env_set "INFRA_ARTIFACT"     "./artifact-cache/${INFRA_ARTIFACT}"  "$env_file"
    _env_set "FRONTEND_GIT_HASH"  "$FRONTEND_HASH"      "$env_file"
    _env_set "WORDPRESS_GIT_HASH" "$WORDPRESS_HASH"     "$env_file"

    chmod 600 "$env_file"
    chown root:root "$env_file"

    log_info "Downloading frontend artifact..."
    curl -fsSL --retry 3 --retry-delay 5 \
        -H "Authorization: Bearer ${GCS_TOKEN}" \
        -o "${DEPLOY_DIR}/artifact-cache/${FRONTEND_ARTIFACT}.download" \
        "$(_gcs_https_url "${GCS_BUCKET}/artifacts/${FRONTEND_ARTIFACT}")"
    decrypt_artifact \
        "${DEPLOY_DIR}/artifact-cache/${FRONTEND_ARTIFACT}.download" \
        "${DEPLOY_DIR}/artifact-cache/${FRONTEND_ARTIFACT}" \
        "${SCRIPT_DIR}/lib/decrypt.sh" \
        "${DEPLOY_DIR}/infra/secrets"
    rm -f "${DEPLOY_DIR}/artifact-cache/${FRONTEND_ARTIFACT}.download"
    _env_set "FRONTEND_ARTIFACT" "./artifact-cache/${FRONTEND_ARTIFACT}" "$env_file"

    log_info "Downloading wordpress artifact..."
    curl -fsSL --retry 3 --retry-delay 5 \
        -H "Authorization: Bearer ${GCS_TOKEN}" \
        -o "${DEPLOY_DIR}/artifact-cache/${WORDPRESS_ARTIFACT}.download" \
        "$(_gcs_https_url "${GCS_BUCKET}/artifacts/${WORDPRESS_ARTIFACT}")"
    decrypt_artifact \
        "${DEPLOY_DIR}/artifact-cache/${WORDPRESS_ARTIFACT}.download" \
        "${DEPLOY_DIR}/artifact-cache/${WORDPRESS_ARTIFACT}" \
        "${SCRIPT_DIR}/lib/decrypt.sh" \
        "${DEPLOY_DIR}/infra/secrets"
    rm -f "${DEPLOY_DIR}/artifact-cache/${WORDPRESS_ARTIFACT}.download"
    _env_set "WORDPRESS_ARTIFACT" "./artifact-cache/${WORDPRESS_ARTIFACT}" "$env_file"

    log_info "All artifacts downloaded"

    # ════════════════════════════════════════════════════════════════════════
    # STEP 7: Traefik routing
    # ════════════════════════════════════════════════════════════════════════
    log_step "7/8  Traefik routing"

    local traefik_script="$SCRIPT_DIR/scripts/add-traefik-site.sh"
    if [[ -n "$DOMAIN" ]]; then
        local traefik_cmd="sudo ${traefik_script} ${DOMAIN} ${KONG_PORT} ${SITE_NAME}"
        log_info "Suggested Traefik command:"
        echo ""
        echo "    $traefik_cmd"
        echo ""
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -rp "  [Y] Run now  [e] Edit  [n] Skip  [Y/e/n]: " input
            case "${input,,}" in
                ""|y)
                    [[ -f "$traefik_script" ]] && bash "$traefik_script" "$DOMAIN" "$KONG_PORT" "$SITE_NAME" \
                        || log_warn "add-traefik-site.sh not found"
                    ;;
                e)
                    read -rp "  Domain [${DOMAIN}]: " ed; DOMAIN="${ed:-$DOMAIN}"
                    read -rp "  Port   [${KONG_PORT}]: " ep; KONG_PORT="${ep:-$KONG_PORT}"
                    if [[ -f "$traefik_script" ]]; then bash "$traefik_script" "$DOMAIN" "$KONG_PORT" "$SITE_NAME"
                    else log_warn "add-traefik-site.sh not found"; fi
                    ;;
                n) log_note "Skipping Traefik — run manually: $traefik_cmd" ;;
            esac
        else
            log_note "Non-interactive: run Traefik manually: $traefik_cmd"
        fi
    else
        log_note "No domain set — Traefik routing skipped"
    fi

    # ════════════════════════════════════════════════════════════════════════
    # STEP 8: Log rotation + systemd updater timer
    # ════════════════════════════════════════════════════════════════════════
    log_step "8/8  Log rotation + systemd updater timer"

    if [[ "$SETUP_LOGROTATE" == "yes" && -f "$SCRIPT_DIR/scripts/setup-logrotate.sh" ]]; then
        bash "$SCRIPT_DIR/scripts/setup-logrotate.sh" "$SITE_NAME" "$DEPLOY_DIR"
    fi

    if [[ "$SETUP_TIMER" == "yes" ]]; then
        install_updater_timer "$SITE_NAME" "$DEPLOY_DIR"
        add_update_now_sudoers "$SITE_USER" "$SITE_NAME" || true
        create_update_now_helper "$SITE_NAME" "${DEPLOY_DIR}/bin" "$SITE_USER"
        log_info "Immediate check: ${DEPLOY_DIR}/bin/update-now"
    fi

    # ════════════════════════════════════════════════════════════════════════
    # Summary
    # ════════════════════════════════════════════════════════════════════════
    echo ""
    log_info "════════════════════════════════════════════"
    log_info "Deployment complete!"
    log_info "════════════════════════════════════════════"
    echo ""
    printf "  %-20s %s\n" "Site:" "$SITE_NAME"
    printf "  %-20s %s\n" "Directory:" "$DEPLOY_DIR"
    printf "  %-20s %s\n" "System user:" "$SITE_USER (nologin)"
    if [[ -n "$DOMAIN" ]]; then printf "  %-20s %s\n" "Domain:" "$DOMAIN"; fi
    printf "  %-20s %s\n" "Kong port:" "$KONG_PORT"
    echo ""
    log_info "Next steps:"
    echo "  1. Review .env:      ${DEPLOY_DIR}/.env"
    echo "  2. Start stack:      cd ${DEPLOY_DIR} && docker compose up -d"
    if [[ "$SETUP_TIMER" == "yes" ]]; then
        echo "  3. Check updates:    ${DEPLOY_DIR}/bin/update-now"
    fi
    echo ""
}

main "$@"
