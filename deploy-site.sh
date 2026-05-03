#!/usr/bin/env bash
# deploy-site.sh — Deploy a new site from a Git repository
#
# Interactive or scripted deployment that:
#   - Creates a per-site system user (nologin shell by default)
#   - Clones the repository and sets ownership
#   - Auto-allocates a Kong HTTPS port from 8443+
#   - Provisions GitHub token and artifact infrastructure
#   - Test-pulls artifacts and detects encryption; provisions keys if needed
#   - Suggests and optionally applies Traefik routing
#   - Installs a 15-minute systemd updater timer with an update-now helper
#
# Usage:
#   Interactive:  sudo ./deploy-site.sh
#   Scripted:     sudo ./deploy-site.sh --git-url <url> --site-name <name> [options]
#
# Options:
#   --git-url <url>              Git repository URL (required)
#   --site-name <name>           Site name — alphanumeric + hyphens (required)
#   --site-user <user>           System user for site files (default: <site-name>)
#   --deploy-dir <path>          Deployment directory (default: /opt/apps/<site-name>)
#   --domain <hostname>          Site hostname for Traefik routing
#   --git-branch <branch>        Git branch (optional, defaults to repo default)
#   --kong-port <port>           Kong internal HTTPS port (default: auto-detect from 8443)
#   --github-token-file <path>   File containing the GitHub token
#   --github-repo <owner/repo>   GitHub repository slug (default: inferred from git URL)
#   --create-user <yes|no>       Create dedicated system user (default: yes)
#   --setup-logrotate <yes|no>   Set up log rotation (default: yes)
#   --setup-timer <yes|no>       Install systemd updater timer (default: yes)
#   --ssh-key-file <path>        SSH private key for Git cloning (optional)
#   --non-interactive            Skip all prompts (requires --git-url and --site-name)

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
    # Collect ports already claimed in deployed site .env files
    if [[ -d /opt/apps ]]; then
        used=$(grep -rh "^KONG_HTTPS_PORT=" /opt/apps/ 2>/dev/null | \
               cut -d= -f2 | tr -d '"' | sort -n || true)
    fi
    # Advance past claimed or listening ports
    while echo "$used" | grep -qx "$port" || \
          ss -tlnp 2>/dev/null | awk '{print $4}' | grep -q ":${port}$"; do
        port=$((port + 1))
    done
    echo "$port"
}

# ── GitHub helpers ────────────────────────────────────────────────────────────

infer_github_repo() {
    # https://github.com/owner/repo.git  →  owner/repo
    # git@github.com:owner/repo.git      →  owner/repo
    echo "$1" | sed -E \
        's|^https?://github\.com/([^/]+/[^.]+)(\.git)?$|\1|;
         s|^git@github\.com:([^/]+/[^.]+)(\.git)?$|\1|'
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

    # 15-minute poll with ±5 min random jitter (10-minute window) so that
    # multiple sites or servers don't hammer GitHub simultaneously.
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
    log_info "Timer enabled: ${svc_name}.timer (every 15 min, ±60 s jitter)"
    log_info "Trigger now:   systemctl start ${svc_name}.service"
}

add_update_now_sudoers() {
    local site_user="$1"
    local site_name="$2"
    local sudoers_file="/etc/sudoers.d/updater-${site_user}"

    cat > "$sudoers_file" <<EOF
# Allow ${site_user} to trigger an on-demand artifact update
${site_user} ALL=(root) NOPASSWD: /usr/bin/systemctl start ${site_name}-updater.service
EOF
    chmod 0440 "$sudoers_file"
    chown root:root "$sudoers_file"
    if ! visudo -c -f "$sudoers_file" 2>/dev/null; then
        log_warn "sudoers validation failed — removing $sudoers_file"
        rm -f "$sudoers_file"
    fi
}

create_update_now_helper() {
    local site_name="$1"
    local helpers_dir="$2"
    local site_user="$3"

    mkdir -p "$helpers_dir"
    cat > "${helpers_dir}/update-now" <<HELPER
#!/bin/bash
# Trigger an immediate artifact update check for ${site_name}
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
    GIT_URL=""
    SITE_NAME=""
    SITE_USER=""
    DEPLOY_DIR=""
    GIT_BRANCH=""
    DOMAIN=""
    KONG_PORT=""
    GITHUB_TOKEN=""
    GITHUB_TOKEN_FILE=""
    GITHUB_REPO=""
    CREATE_USER="yes"
    ADD_DOCKER_GROUP="no"
    SETUP_LOGROTATE="yes"
    SETUP_TIMER="yes"
    GIT_SSH_KEY=""
    SSH_KEY_FILE=""

    [[ $# -eq 0 ]] && return 0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --git-url)            GIT_URL="$2";            shift 2 ;;
            --site-name)          SITE_NAME="$2";          shift 2 ;;
            --site-user)          SITE_USER="$2";          shift 2 ;;
            --deploy-dir)         DEPLOY_DIR="$2";         shift 2 ;;
            --domain)             DOMAIN="$2";             shift 2 ;;
            --git-branch)         GIT_BRANCH="$2";         shift 2 ;;
            --kong-port)          KONG_PORT="$2";          shift 2 ;;
            --github-token-file)  GITHUB_TOKEN_FILE="$2";  shift 2 ;;
            --github-repo)        GITHUB_REPO="$2";        shift 2 ;;
            --create-user)        CREATE_USER="$2";        shift 2 ;;
            --setup-logrotate)    SETUP_LOGROTATE="$2";    shift 2 ;;
            --setup-timer)        SETUP_TIMER="$2";        shift 2 ;;
            --ssh-key-file)
                [[ ! -f "$2" ]] && { log_error "SSH key file not found: $2"; exit 1; }
                GIT_SSH_KEY=$(cat "$2")
                SSH_KEY_FILE="$2"
                shift 2 ;;
            --non-interactive)    NON_INTERACTIVE=true;    shift ;;
            --help|-h)
                grep '^#   ' "$0" | sed 's/^#   //'
                exit 0 ;;
            *)
                log_error "Unknown argument: $1"
                echo "Run with --help for usage."
                exit 1 ;;
        esac
    done

    # Auto non-interactive when required flags present
    [[ -n "$GIT_URL" && -n "$SITE_NAME" ]] && NON_INTERACTIVE=true

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        [[ -z "$GIT_URL" ]]   && { log_error "--git-url required"; exit 1; }
        [[ -z "$SITE_NAME" ]] && { log_error "--site-name required"; exit 1; }
    fi
}

# ── Interactive gathering ─────────────────────────────────────────────────────

gather_interactive() {
    log_info "Please provide the following information:"
    echo ""

    while [[ -z "$GIT_URL" ]]; do
        read -rp "Git repository URL: " GIT_URL
    done

    local suggested
    suggested=$(basename "$GIT_URL" .git | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
    read -rp "Site name [${suggested}]: " input
    SITE_NAME="${input:-$suggested}"

    read -rp "System user for site [${SITE_NAME}]: " input
    SITE_USER="${input:-}"

    local default_dir="/opt/apps/${SITE_NAME}"
    read -rp "Deployment directory [${default_dir}]: " input
    DEPLOY_DIR="${input:-$default_dir}"

    read -rp "Git branch (leave empty for default): " GIT_BRANCH

    read -rp "Site hostname for Traefik (e.g. example.com, optional): " DOMAIN

    echo ""
    log_info "User setup:"
    read -rp "Create system user '${SITE_USER:-$SITE_NAME}' with nologin shell? [Y/n]: " input
    [[ "${input,,}" == "n" ]] && CREATE_USER="no"

    if [[ "$CREATE_USER" == "yes" ]]; then
        echo ""
        log_warn "The docker group grants root-equivalent container access."
        log_note "Sudoers-based restricted access will be set up instead (recommended)."
        read -rp "Add user to docker group anyway? [y/N]: " input
        [[ "${input,,}" == "y" ]] && ADD_DOCKER_GROUP="yes"
    fi

    echo ""
    log_info "GitHub token (classic, needs 'repo' scope for private repositories):"
    if [[ -n "$GITHUB_TOKEN_FILE" ]]; then
        log_info "Using token file: $GITHUB_TOKEN_FILE"
    else
        read -rsp "Paste GitHub token (input hidden, press Enter): " GITHUB_TOKEN
        echo ""
    fi

    echo ""
    log_info "SSH key for Git (only needed for private repos over SSH, not HTTPS):"
    read -rp "Provide SSH private key for cloning? [y/N]: " input
    if [[ "${input,,}" == "y" ]]; then
        echo "Paste SSH private key (Ctrl+D when done):"
        GIT_SSH_KEY=$(cat)
    fi
}

# ── Apply defaults ────────────────────────────────────────────────────────────

apply_defaults() {
    SITE_NAME=$(echo "$SITE_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
    SITE_USER="${SITE_USER:-$SITE_NAME}"
    DEPLOY_DIR="${DEPLOY_DIR:-/opt/apps/$SITE_NAME}"
    CREATE_USER="${CREATE_USER:-yes}"
    SETUP_LOGROTATE="${SETUP_LOGROTATE:-yes}"
    SETUP_TIMER="${SETUP_TIMER:-yes}"

    if [[ -n "$GITHUB_TOKEN_FILE" && -f "$GITHUB_TOKEN_FILE" ]]; then
        GITHUB_TOKEN=$(cat "$GITHUB_TOKEN_FILE")
    fi

    if [[ -z "$GITHUB_REPO" ]]; then
        local inferred
        inferred=$(infer_github_repo "$GIT_URL")
        [[ "$inferred" != "$GIT_URL" ]] && GITHUB_REPO="$inferred"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    display_banner
    check_root "$@"
    parse_args "$@"

    [[ "$NON_INTERACTIVE" != "true" ]] && gather_interactive
    apply_defaults

    [[ -z "$SITE_NAME" ]] && { log_error "Site name is required"; exit 1; }
    [[ -z "$GIT_URL" ]]   && { log_error "Git URL is required"; exit 1; }

    local DEPLOY_DIR="${DEPLOY_DIR}"

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
    printf "  %-20s %s\n" "Git URL:"       "$GIT_URL"
    printf "  %-20s %s\n" "Branch:"        "${GIT_BRANCH:-default}"
    printf "  %-20s %s\n" "Deploy dir:"    "$DEPLOY_DIR"
    printf "  %-20s %s\n" "System user:"   "$SITE_USER (nologin)"
    printf "  %-20s %s\n" "Docker group:"  "$ADD_DOCKER_GROUP"
    printf "  %-20s %s\n" "Kong port:"     "$KONG_PORT"
    printf "  %-20s %s\n" "Domain:"        "${DOMAIN:-(not set)}"
    printf "  %-20s %s\n" "GitHub repo:"   "${GITHUB_REPO:-(infer from .env_template_prod)}"
    printf "  %-20s %s\n" "GitHub token:"  "$([ -n "$GITHUB_TOKEN" ] && echo "provided" || echo "not provided")"
    printf "  %-20s %s\n" "Logrotate:"     "$SETUP_LOGROTATE"
    printf "  %-20s %s\n" "Updater timer:" "$SETUP_TIMER (15 min)"
    log_info "════════════════════════════════════════════"
    echo ""

    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        read -rp "Proceed? [Y/n]: " input
        [[ "${input,,}" == "n" ]] && { log_warn "Deployment cancelled"; exit 0; }
    fi

    # ── Replay command ────────────────────────────────────────────────────────
    echo ""
    log_note "Replay command (save this for disaster recovery):"
    echo ""
    printf "  sudo %s/deploy-site.sh \\\\\n" "$SCRIPT_DIR"
    printf "    --git-url '%s' \\\\\n" "$GIT_URL"
    printf "    --site-name '%s' \\\\\n" "$SITE_NAME"
    [[ "$SITE_USER" != "$SITE_NAME" ]] && printf "    --site-user '%s' \\\\\n" "$SITE_USER"
    printf "    --deploy-dir '%s' \\\\\n" "$DEPLOY_DIR"
    [[ -n "$GIT_BRANCH" ]]  && printf "    --git-branch '%s' \\\\\n" "$GIT_BRANCH"
    [[ -n "$DOMAIN" ]]      && printf "    --domain '%s' \\\\\n" "$DOMAIN"
    printf "    --kong-port '%s' \\\\\n" "$KONG_PORT"
    [[ -n "$GITHUB_REPO" ]] && printf "    --github-repo '%s' \\\\\n" "$GITHUB_REPO"
    [[ -n "$SSH_KEY_FILE" ]] && printf "    --ssh-key-file '%s' \\\\\n" "$SSH_KEY_FILE"
    printf "    --setup-timer '%s'\n" "$SETUP_TIMER"
    echo ""

    # ════════════════════════════════════════════════════════════════════════
    # STEP 1: User management
    # ════════════════════════════════════════════════════════════════════════
    log_step "1/9  User management"

    if [[ "$CREATE_USER" == "yes" ]]; then
        if id "$SITE_USER" &>/dev/null; then
            log_info "User '$SITE_USER' already exists"
        else
            # System user: no interactive login, home = deploy dir (for env purposes)
            useradd -r -M -d "$DEPLOY_DIR" -s /usr/sbin/nologin "$SITE_USER"
            log_info "Created system user: $SITE_USER (nologin)"
        fi

        if [[ "$ADD_DOCKER_GROUP" == "yes" ]]; then
            usermod -aG docker "$SITE_USER"
            log_warn "Added $SITE_USER to docker group (grants root-equivalent container access)"
        fi
    else
        id "$SITE_USER" &>/dev/null \
            || { log_error "User '$SITE_USER' does not exist (pass --create-user yes)"; exit 1; }
        log_info "Using existing user: $SITE_USER"
    fi

    # ════════════════════════════════════════════════════════════════════════
    # STEP 2: Clone repository
    # ════════════════════════════════════════════════════════════════════════
    log_step "2/9  Cloning repository → $DEPLOY_DIR"

    if [[ -d "$DEPLOY_DIR/.git" ]]; then
        log_warn "Repository already present at $DEPLOY_DIR"
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -rp "Remove and re-clone? [y/N]: " input
            if [[ "${input,,}" == "y" ]]; then
                rm -rf "$DEPLOY_DIR"
            else
                log_info "Reusing existing clone"
            fi
        fi
    fi

    if [[ ! -d "$DEPLOY_DIR/.git" ]]; then
        mkdir -p "$(dirname "$DEPLOY_DIR")"

        if [[ -n "$GIT_SSH_KEY" ]]; then
            local tmp_key
            tmp_key=$(mktemp)
            printf '%s\n' "$GIT_SSH_KEY" > "$tmp_key"
            chmod 600 "$tmp_key"
            local clone_env="GIT_SSH_COMMAND='ssh -i ${tmp_key} -o StrictHostKeyChecking=accept-new'"
            if [[ -n "$GIT_BRANCH" ]]; then
                eval "$clone_env git clone -b '$GIT_BRANCH' '$GIT_URL' '$DEPLOY_DIR'"
            else
                eval "$clone_env git clone '$GIT_URL' '$DEPLOY_DIR'"
            fi
            rm -f "$tmp_key"
        else
            if [[ -n "$GIT_BRANCH" ]]; then
                git clone -b "$GIT_BRANCH" "$GIT_URL" "$DEPLOY_DIR"
            else
                git clone "$GIT_URL" "$DEPLOY_DIR"
            fi
        fi
        log_info "Repository cloned to $DEPLOY_DIR"
    fi

    # ════════════════════════════════════════════════════════════════════════
    # STEP 3: Ownership + permissions
    # ════════════════════════════════════════════════════════════════════════
    log_step "3/9  Ownership and permissions"

    # Site user owns the project tree
    chown -R "${SITE_USER}:${SITE_USER}" "$DEPLOY_DIR"
    log_info "Ownership: ${SITE_USER}:${SITE_USER} → $DEPLOY_DIR"

    # Sensitive subdirs: root-only (update.sh runs as root)
    mkdir -p "${DEPLOY_DIR}/artifact-cache"
    chown root:root "${DEPLOY_DIR}/artifact-cache"
    chmod 755 "${DEPLOY_DIR}/artifact-cache"

    mkdir -p "${DEPLOY_DIR}/infra/secrets"
    chown root:root "${DEPLOY_DIR}/infra/secrets"
    chmod 700 "${DEPLOY_DIR}/infra/secrets"

    log_info "artifact-cache:  755 root:root"
    log_info "infra/secrets:   700 root:root"

    # Setup Docker sudo rules + network for the site user
    if [[ -f "$SCRIPT_DIR/scripts/setup-docker-permissions.sh" ]]; then
        log_info "Setting up Docker sudoers for $SITE_USER..."
        bash "$SCRIPT_DIR/scripts/setup-docker-permissions.sh" "$SITE_USER" "$DEPLOY_DIR"
    fi

    if [[ -f "$SCRIPT_DIR/scripts/setup-docker-network.sh" ]]; then
        bash "$SCRIPT_DIR/scripts/setup-docker-network.sh" "$SITE_NAME"
    fi

    # Log directory
    local log_dir="/var/log/${SITE_NAME}"
    mkdir -p "$log_dir"
    chown "${SITE_USER}:${SITE_USER}" "$log_dir"
    log_info "Log dir: $log_dir"

    # ════════════════════════════════════════════════════════════════════════
    # STEP 4: GitHub token
    # ════════════════════════════════════════════════════════════════════════
    log_step "4/9  GitHub token"

    local token_file="${DEPLOY_DIR}/infra/secrets/github_token.txt"
    if [[ -n "$GITHUB_TOKEN" ]]; then
        printf '%s' "$GITHUB_TOKEN" > "$token_file"
        chmod 600 "$token_file"
        chown root:root "$token_file"
        log_info "Token saved → infra/secrets/github_token.txt"
    elif [[ -f "$token_file" ]]; then
        GITHUB_TOKEN=$(cat "$token_file")
        log_info "Existing token found at $token_file"
    else
        log_warn "No GitHub token — skipping (update.sh will fail until a token is added)"
        log_note "Add it later: echo 'ghp_...' > ${token_file} && chmod 600 ${token_file}"
    fi

    # ════════════════════════════════════════════════════════════════════════
    # STEP 5: .env setup
    # ════════════════════════════════════════════════════════════════════════
    log_step "5/9  Environment (.env)"

    local env_file="${DEPLOY_DIR}/.env"
    if [[ ! -f "$env_file" ]]; then
        if [[ -f "${DEPLOY_DIR}/.env_template_prod" ]]; then
            cp "${DEPLOY_DIR}/.env_template_prod" "$env_file"
            log_info "Created .env from .env_template_prod"
        elif [[ -f "${DEPLOY_DIR}/.env_template" ]]; then
            cp "${DEPLOY_DIR}/.env_template" "$env_file"
            log_info "Created .env from .env_template"
        else
            touch "$env_file"
            log_info "Created empty .env"
        fi
    else
        log_info ".env already exists"
    fi

    # Inject / update known values
    [[ -n "$GITHUB_REPO" ]] && _env_set "GITHUB_REPO"    "$GITHUB_REPO"  "$env_file"
    [[ -n "$KONG_PORT" ]]   && _env_set "KONG_HTTPS_PORT" "$KONG_PORT"   "$env_file"
    [[ -n "$DOMAIN" ]]      && _env_set "SITE_HOSTNAME"   "$DOMAIN"      "$env_file"

    # Pull back GITHUB_REPO in case it came from the template
    [[ -z "$GITHUB_REPO" ]] && GITHUB_REPO=$(_env_get "GITHUB_REPO" "$env_file")

    chmod 600 "$env_file"
    chown root:root "$env_file"
    log_info ".env written (600 root:root)"

    # ════════════════════════════════════════════════════════════════════════
    # STEP 6: Test pull + encryption detection
    # ════════════════════════════════════════════════════════════════════════
    log_step "6/9  Test pull (GitHub access + encryption detection)"

    local update_sh="${DEPLOY_DIR}/infra/bootstrap/update.sh"
    local artifact_cache="${DEPLOY_DIR}/artifact-cache"

    if [[ ! -f "$update_sh" ]]; then
        log_warn "update.sh not found at $update_sh — skipping test pull"
    elif [[ -z "$GITHUB_TOKEN" ]]; then
        log_warn "No GitHub token available — skipping test pull"
    else
        log_info "Running: update.sh --pull-only"
        if (cd "$DEPLOY_DIR" && bash "$update_sh" --pull-only); then
            log_info "Test pull succeeded"
        else
            log_warn "Test pull failed — check token permissions and GITHUB_REPO in .env"
            if [[ "$NON_INTERACTIVE" != "true" ]]; then
                read -rp "Continue anyway? [y/N]: " input
                [[ "${input,,}" != "y" ]] && { log_error "Deployment aborted"; exit 1; }
            fi
        fi

        # Detect encryption from a content-addressed bundle (not the staged frontend.tar.gz)
        local sample_bundle
        sample_bundle=$(find "$artifact_cache" -maxdepth 1 -name "*-*.tar.gz" 2>/dev/null | head -1 || true)

        if [[ -z "$sample_bundle" ]]; then
            log_note "No bundles found in artifact-cache — encryption mode unknown"
        elif artifact_is_encrypted "$sample_bundle"; then
            echo ""
            log_warn "Artifact is ENCRYPTED (payload.enc detected inside bundle)"
            log_info "Provisioning encryption keys for ${SITE_NAME}..."
            echo ""

            local pub_key_file="${DEPLOY_DIR}/infra/secrets/artifact_signing_public_key.pem"
            local aes_key_file="${DEPLOY_DIR}/infra/secrets/artifact_aes_key.txt"

            if [[ ! -f "$pub_key_file" ]]; then
                echo "  Paste RSA-4096 signing public key (PEM format, Ctrl+D when done):"
                local pub_key
                pub_key=$(cat)
                if [[ -n "$pub_key" ]]; then
                    printf '%s\n' "$pub_key" > "$pub_key_file"
                    chmod 600 "$pub_key_file"
                    chown root:root "$pub_key_file"
                    log_info "Signing public key saved"
                else
                    log_warn "No public key provided — artifact decryption will fail at startup"
                fi
            else
                log_info "Signing public key already present"
            fi

            if [[ ! -f "$aes_key_file" ]]; then
                read -rsp "  AES-256 key (base64-encoded, input hidden): " AES_KEY
                echo ""
                if [[ -n "$AES_KEY" ]]; then
                    printf '%s' "$AES_KEY" > "$aes_key_file"
                    chmod 600 "$aes_key_file"
                    chown root:root "$aes_key_file"
                    log_info "AES key saved"
                else
                    log_warn "No AES key provided — artifact decryption will fail at startup"
                fi
            else
                log_info "AES key already present"
            fi

            # Verify with decrypt.sh --dry-run if both keys are available
            local decrypt_sh="${DEPLOY_DIR}/infra/artifact-crypto/decrypt.sh"
            if [[ -f "$decrypt_sh" && -f "$pub_key_file" && -f "$aes_key_file" ]]; then
                log_info "Verifying keys with decrypt.sh --dry-run..."
                if ARTIFACT_SIGNING_PUBLIC_KEY="$(cat "$pub_key_file")" \
                   ARTIFACT_AES_KEY="$(cat "$aes_key_file")" \
                   SKIP_ENCRYPTION=false \
                   bash "$decrypt_sh" --bundle "$sample_bundle" --dry-run; then
                    log_info "Key verification passed"
                else
                    log_warn "Key verification FAILED — check the keys are for this repo"
                fi
            fi
        else
            log_info "Artifact is unencrypted (null-key mode) — no crypto keys needed"
        fi
    fi

    # ════════════════════════════════════════════════════════════════════════
    # STEP 7: Traefik routing
    # ════════════════════════════════════════════════════════════════════════
    log_step "7/9  Traefik routing"

    local traefik_domain="${DOMAIN:-$(_env_get "SITE_HOSTNAME" "$env_file")}"
    local traefik_script="$SCRIPT_DIR/scripts/add-traefik-site.sh"
    local traefik_cmd="sudo ${traefik_script} ${traefik_domain:-<domain>} ${KONG_PORT}"

    echo ""
    if [[ -n "$traefik_domain" ]]; then
        log_info "Suggested Traefik command:"
        echo ""
        echo "    $traefik_cmd"
        echo ""
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -rp "  [Y] Run now  [e] Edit domain/port  [n] Skip  [Y/e/n]: " input
            case "${input,,}" in
                ""|y)
                    if [[ -f "$traefik_script" ]]; then
                        bash "$traefik_script" "$traefik_domain" "$KONG_PORT" "$SITE_NAME"
                    else
                        log_warn "add-traefik-site.sh not found at $traefik_script"
                    fi
                    ;;
                e)
                    read -rp "  Domain [${traefik_domain}]: " ed
                    traefik_domain="${ed:-$traefik_domain}"
                    read -rp "  Port   [${KONG_PORT}]: " ep
                    local edit_port="${ep:-$KONG_PORT}"
                    if [[ -f "$traefik_script" ]]; then
                        bash "$traefik_script" "$traefik_domain" "$edit_port" "$SITE_NAME"
                    fi
                    ;;
                n)
                    log_note "Skipping Traefik — run manually when ready:"
                    echo "    $traefik_cmd"
                    ;;
            esac
        else
            log_note "Non-interactive: run Traefik manually: $traefik_cmd"
        fi
    else
        log_note "No domain set — Traefik routing skipped"
        log_note "Run later: sudo ${traefik_script} <domain> ${KONG_PORT}"
    fi

    # ════════════════════════════════════════════════════════════════════════
    # STEP 8: Log rotation
    # ════════════════════════════════════════════════════════════════════════
    log_step "8/9  Log rotation"
    if [[ "$SETUP_LOGROTATE" == "yes" && -f "$SCRIPT_DIR/scripts/setup-logrotate.sh" ]]; then
        bash "$SCRIPT_DIR/scripts/setup-logrotate.sh" "$SITE_NAME" "$DEPLOY_DIR"
    else
        log_info "Skipped"
    fi

    # ════════════════════════════════════════════════════════════════════════
    # STEP 9: Systemd updater timer
    # ════════════════════════════════════════════════════════════════════════
    log_step "9/9  Systemd updater timer"

    if [[ "$SETUP_TIMER" == "yes" ]]; then
        install_updater_timer "$SITE_NAME" "$DEPLOY_DIR"
        add_update_now_sudoers "$SITE_USER" "$SITE_NAME" || true
        create_update_now_helper "$SITE_NAME" "${DEPLOY_DIR}/bin" "$SITE_USER"
        log_info "Immediate check helper: ${DEPLOY_DIR}/bin/update-now"
    else
        log_info "Skipped (--setup-timer no)"
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
    [[ -n "$traefik_domain" ]] && printf "  %-20s %s\n" "Domain:" "$traefik_domain"
    printf "  %-20s %s\n" "Kong port:" "$KONG_PORT"
    echo ""
    log_info "Next steps:"
    echo "  1. Review .env:        ${DEPLOY_DIR}/.env"
    echo "  2. Start stack:        cd ${DEPLOY_DIR} && sudo docker compose up -d"
    if [[ "$SETUP_TIMER" == "yes" ]]; then
        echo "  3. Check for updates:  ${DEPLOY_DIR}/bin/update-now"
        echo "     Watch update logs:  journalctl -fu ${SITE_NAME}-updater.service"
    fi
    echo ""
}

main "$@"
