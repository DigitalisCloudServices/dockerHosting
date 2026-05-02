#!/bin/bash

#############################################
# Install Traefik v3.6 as Boundary Proxy
#
# Replaces system-level nginx with a Docker-based
# reverse proxy using the file provider.
#
# On existing servers with nginx installed, prompts
# to migrate site configs and SSL certs automatically.
#
# Usage: ./install-traefik.sh [--migrate-nginx=yes|no|abort]
#############################################

set -euo pipefail

# Environment-overridable paths (used by tests to redirect to temp dirs)
TRAEFIK_VERSION="${TRAEFIK_VERSION:-v3.6}"
TRAEFIK_DIR="${TRAEFIK_DIR:-/etc/traefik}"
TRAEFIK_DYNAMIC_DIR="${TRAEFIK_DYNAMIC_DIR:-${TRAEFIK_DIR}/dynamic}"
TRAEFIK_CERTS_DIR="${TRAEFIK_CERTS_DIR:-${TRAEFIK_DIR}/certs}"
NGINX_SITES_DIR="${NGINX_SITES_DIR:-/etc/nginx/sites-enabled}"
DOCKERHOSTING_SSL_DIR="${DOCKERHOSTING_SSL_DIR:-/etc/ssl/dockerhosting}"
DEPLOYED_APPS_DIR="${DEPLOYED_APPS_DIR:-/opt/apps}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${TEMPLATE_DIR:-$(dirname "$SCRIPT_DIR")/templates}"

# Parse flags
MIGRATE_NGINX=""
FORCE=false
for arg in "$@"; do
    case "$arg" in
        --migrate-nginx=*) MIGRATE_NGINX="${arg#*=}" ;;
        --force) FORCE=true ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ── nginx detection ─────────────────────────────────────────────────────────

_nginx_is_present() {
    dpkg -l nginx 2>/dev/null | grep -q "^ii" && return 0
    systemctl is-active --quiet nginx 2>/dev/null && return 0
    return 1
}

# ── migration helpers ────────────────────────────────────────────────────────

_backup_nginx() {
    local backup_dir
    backup_dir="/root/nginx-backup-$(date +%Y%m%d-%H%M%S)"
    local nginx_version
    nginx_version=$(dpkg -l nginx 2>/dev/null | awk '/^ii/{print $3}' | head -1 || echo "unknown")
    cp -r /etc/nginx "$backup_dir"
    log_info "Backup: $backup_dir (nginx version: $nginx_version)"
    log_warn "Rollback: apt-get install nginx=$nginx_version && cp -r $backup_dir/ /etc/nginx/"
}

_stop_nginx() {
    log_info "Stopping nginx..."
    systemctl stop nginx 2>/dev/null || true
    systemctl disable nginx 2>/dev/null || true
}

# Process one nginx conf file. Appends to global MIGRATION_WARNINGS array.
_migrate_one_site() {
    local conf="$1"
    local domain port site_name cert_src

    domain=$(grep -oE 'server_name[[:space:]]+[^;]+' "$conf" 2>/dev/null | awk '{print $2}' | head -1 || true)
    port=$(grep -oE 'proxy_pass[[:space:]]+http://(127\.0\.0\.1|localhost):[0-9]+' "$conf" 2>/dev/null \
           | grep -oE '[0-9]+$' | head -1 || true)

    if [[ -z "$domain" || "$domain" == "_" ]]; then
        log_warn "Skipping $conf — no server_name found"
        return 0
    fi

    if [[ -z "$port" ]]; then
        log_warn "No proxy_pass port in $conf"
        MIGRATION_WARNINGS+=("  ⚠  $(basename "$conf") — no proxy_pass port, create Traefik config manually")
        return 0
    fi

    site_name=$(echo "$domain" | tr '.' '-' | tr -cd '[:alnum:]-')
    log_info "Migrating: $domain → port $port"

    cert_src="$DOCKERHOSTING_SSL_DIR/$site_name"
    if [[ -d "$cert_src" ]]; then
        ln -sfn "$cert_src" "$TRAEFIK_CERTS_DIR/$site_name"
        log_info "  Linked certs: $cert_src"
    fi

    if grep -qE 'location[[:space:]]' "$conf" 2>/dev/null; then
        MIGRATION_WARNINGS+=("  ⚠  $(basename "$conf") — custom location blocks; add equivalent Traefik middleware manually")
    fi

    if grep -q 'limit_req' "$conf" 2>/dev/null; then
        MIGRATION_WARNINGS+=("  ⚠  $(basename "$conf") — limit_req detected; review rate-limit middleware in $TRAEFIK_DYNAMIC_DIR/middleware.yml")
    fi

    bash "$SCRIPT_DIR/add-traefik-site.sh" "$domain" "$port" "$site_name"
}

_migrate_nginx_sites() {
    [[ -d "$NGINX_SITES_DIR" ]] || return 0
    log_info "Migrating nginx site configs..."
    local conf
    while IFS= read -r -d '' conf; do
        _migrate_one_site "$conf"
    done < <(find "$NGINX_SITES_DIR" -maxdepth 1 -type f -print0 2>/dev/null || true)
}

_handle_certbot_cron() {
    [[ -f /etc/cron.d/certbot ]] || return 0
    MIGRATION_WARNINGS+=("  ⚠  /etc/cron.d/certbot — disable if using Traefik ACME: rm /etc/cron.d/certbot")
}

_remove_deployed_helpers() {
    [[ -d "$DEPLOYED_APPS_DIR" ]] || return 0
    log_info "Removing nginx helper scripts from deployed sites..."
    find "$DEPLOYED_APPS_DIR" -maxdepth 3 \( -name "nginx-reload" -o -name "nginx-status" \) \
        -print0 2>/dev/null \
        | while IFS= read -r -d '' f; do
            rm -f "$f"
            log_info "  Removed: $f"
        done
}

_purge_nginx() {
    log_info "Uninstalling nginx..."
    apt-get purge nginx nginx-common -y
    apt-get autoremove -y
}

_print_migration_warnings() {
    [[ "${#MIGRATION_WARNINGS[@]}" -eq 0 ]] && return 0
    echo ""
    log_warn "══════════════════════════════════════════"
    log_warn "MANUAL ACTIONS REQUIRED after migration:"
    log_warn "══════════════════════════════════════════"
    local w
    for w in "${MIGRATION_WARNINGS[@]}"; do
        echo "$w"
    done
    echo ""
}

# ── migration orchestrator ───────────────────────────────────────────────────

migrate_from_nginx() {
    MIGRATION_WARNINGS=()
    log_info "Starting nginx → Traefik migration..."

    _backup_nginx
    _stop_nginx
    mkdir -p "$TRAEFIK_DYNAMIC_DIR" "$TRAEFIK_CERTS_DIR"
    _migrate_nginx_sites
    _handle_certbot_cron
    _remove_deployed_helpers
    _purge_nginx
    _print_migration_warnings

    log_info "Migration complete. nginx removed."
}

# ── prompt ───────────────────────────────────────────────────────────────────

check_nginx_migration() {
    _nginx_is_present || return 0

    echo ""
    log_warn "Existing nginx installation detected."
    echo "  Options:"
    echo "    1) Migrate to Traefik (stop nginx, migrate site configs + SSL certs, uninstall nginx)"
    echo "    2) Skip (leave nginx in place, do not install Traefik)"
    echo "    3) Abort"
    echo ""

    local choice="${MIGRATE_NGINX:-}"
    if [[ -z "$choice" ]]; then
        read -r -p "Choice [1/2/3]: " choice
    fi

    case "$choice" in
        1|yes)  migrate_from_nginx ;;
        2|no)   log_info "Leaving nginx in place. Exiting."; exit 0 ;;
        3|abort) log_error "Aborting."; exit 1 ;;
        *)      log_error "Invalid choice '$choice'. Aborting."; exit 1 ;;
    esac
}

# ── install ──────────────────────────────────────────────────────────────────

DASHBOARD_PASSWORD=""
DASHBOARD_HASH=""

generate_dashboard_password() {
    # Letters, digits, and terminal-safe symbols only.
    # Excluded: - ' ` " \ $ ! | & ; < > ( ) { } ~ * ? [ ] # ^ % space
    DASHBOARD_PASSWORD=$(tr -cd 'A-Za-z0-9@_+=#.' </dev/urandom | head -c 32)
    # Pipe via stdin to avoid leading-dash passwords being parsed as option flags
    DASHBOARD_HASH=$(printf '%s' "$DASHBOARD_PASSWORD" | openssl passwd -apr1 -stdin)
}

write_dashboard_config() {
    local creds_file="$TRAEFIK_DIR/dashboard-credentials"

    # Write dynamic config with BasicAuth router for the dashboard
    cat > "$TRAEFIK_DYNAMIC_DIR/dashboard.yml" <<EOF
---
# Traefik Dashboard - BasicAuth Protected
# Managed by dockerHosting - do not edit by hand
http:
  middlewares:
    dashboard-auth:
      basicAuth:
        users:
          - "admin:${DASHBOARD_HASH}"
  routers:
    dashboard:
      rule: "PathPrefix(\`/\`)"
      service: api@internal
      middlewares:
        - dashboard-auth
      entryPoints:
        - traefik
EOF
    chmod 640 "$TRAEFIK_DYNAMIC_DIR/dashboard.yml"

    # Store plaintext credentials for operator reference (root-only)
    cat > "$creds_file" <<EOF
# Traefik Dashboard Credentials
# Generated: $(date)
# URL: http://<server-ip>:8080/dashboard/
username: admin
password: ${DASHBOARD_PASSWORD}
EOF
    chmod 600 "$creds_file"
    log_info "Dashboard credentials saved to $creds_file (root-readable only)"
}

prompt_firewall_8080() {
    command -v ufw &>/dev/null || return 0
    ufw status 2>/dev/null | grep -q "Status: active" || return 0

    echo ""
    log_warn "Traefik dashboard is bound to all interfaces on port 8080."
    log_warn "UFW is active — port 8080 is currently blocked from external access."
    echo "  Options:"
    echo "    1) Allow from a specific IP only (recommended)"
    echo "    2) Allow from anywhere (not recommended)"
    echo "    3) Leave blocked (access via SSH tunnel: ssh -L 8080:localhost:8080 user@server)"
    echo ""
    local choice
    read -r -p "Choice [1/2/3]: " choice
    echo
    case "$choice" in
        1)
            local src_ip
            read -r -p "Source IP address to allow: " src_ip
            echo
            if [[ -z "$src_ip" ]]; then
                log_warn "No IP entered — leaving port 8080 blocked."
            else
                ufw allow from "$src_ip" to any port 8080 proto tcp comment 'Traefik dashboard'
                log_info "Firewall: port 8080 allowed from $src_ip"
            fi
            ;;
        2)
            ufw allow 8080/tcp comment 'Traefik dashboard'
            log_warn "Firewall: port 8080 open to all — ensure dashboard credentials are strong!"
            ;;
        3|*)
            log_info "Port 8080 remains blocked. SSH tunnel: ssh -L 8080:localhost:8080 user@server"
            ;;
    esac
}

write_configs() {
    log_info "Writing Traefik static config..."
    cp "$TEMPLATE_DIR/traefik/traefik.yml" "$TRAEFIK_DIR/traefik.yml"
    chmod 644 "$TRAEFIK_DIR/traefik.yml"

    log_info "Writing shared middleware config..."
    cp "$TEMPLATE_DIR/traefik/middleware.yml" "$TRAEFIK_DYNAMIC_DIR/middleware.yml"
    chmod 644 "$TRAEFIK_DYNAMIC_DIR/middleware.yml"

    generate_dashboard_password
    write_dashboard_config
}

start_traefik() {
    log_info "Pulling traefik:${TRAEFIK_VERSION}..."
    docker pull "traefik:${TRAEFIK_VERSION}"
    docker rm -f traefik 2>/dev/null || true

    log_info "Starting Traefik container..."
    # --network host: required so that 127.0.0.1:PORT in site configs resolves
    # to the host's loopback where backend site containers expose their ports.
    # --userns=host: required because the Linux kernel forbids combining
    # userns-remap (daemon.json: "userns-remap":"default") with --network host.
    # Traefik is a trusted infra component; all tenant containers keep userns protection.
    docker run -d \
        --name traefik \
        --restart unless-stopped \
        --network host \
        --userns=host \
        -v /etc/traefik:/etc/traefik:ro \
        "traefik:${TRAEFIK_VERSION}"
}

verify_traefik() {
    log_info "Waiting for Traefik API..."
    local retries=15
    while [[ $retries -gt 0 ]]; do
        if curl -sf -u "admin:${DASHBOARD_PASSWORD}" http://127.0.0.1:8080/api/version >/dev/null 2>&1; then
            local ver
            ver=$(curl -sf -u "admin:${DASHBOARD_PASSWORD}" http://127.0.0.1:8080/api/version 2>/dev/null \
                  | grep -oP '"Version":"\K[^"]+' || echo "unknown")
            log_info "Traefik is running (version: $ver)"
            return 0
        fi
        retries=$((retries - 1))
        sleep 1
    done
    log_warn "Traefik API not responding after 15s — check: docker logs traefik"
}

main() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi

    local running_image
    running_image=$(docker inspect traefik --format '{{.Config.Image}}' 2>/dev/null || true)
    if [[ "$FORCE" == false ]] && \
       [[ "$running_image" == "traefik:${TRAEFIK_VERSION}" ]] && \
       docker inspect traefik --format '{{.State.Running}}' 2>/dev/null | grep -q "true"; then
        log_info "Traefik ${TRAEFIK_VERSION} is already running — skipping (use --force to reinstall)"
        exit 0
    fi

    log_info "Installing Traefik ${TRAEFIK_VERSION}..."
    check_nginx_migration

    mkdir -p "$TRAEFIK_DYNAMIC_DIR" "$TRAEFIK_CERTS_DIR"
    chmod 750 "$TRAEFIK_DIR"

    write_configs
    start_traefik
    verify_traefik
    prompt_firewall_8080

    echo ""
    log_info "════════════════════════════════════════════"
    log_info "Traefik ${TRAEFIK_VERSION} installation complete!"
    log_info "════════════════════════════════════════════"
    echo ""
    echo "  Dashboard: http://<server-ip>:8080/dashboard/"
    echo "  Username:  admin"
    echo "  Password:  ${DASHBOARD_PASSWORD}"
    echo ""
    log_warn "Save these credentials — the password is stored at:"
    log_warn "  ${TRAEFIK_DIR}/dashboard-credentials  (root-readable only)"
    echo ""
    echo "  Dynamic configs: $TRAEFIK_DYNAMIC_DIR/"
    echo "  SSL certs:       $TRAEFIK_CERTS_DIR/"
    echo ""
    echo "  Add a site:    /opt/dockerHosting/scripts/add-traefik-site.sh <domain> <port>"
    echo "  Remove a site: /opt/dockerHosting/scripts/remove-traefik-site.sh <domain>"
    echo ""
}

# Allow sourcing without running main (enables unit testing of individual functions)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
