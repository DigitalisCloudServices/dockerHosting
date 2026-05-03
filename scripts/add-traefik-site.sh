#!/bin/bash
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#############################################
# Add a Site to Traefik Routing
#
# Writes a dynamic config file that Traefik
# hot-reloads automatically — no restart needed.
#
# Usage: ./add-traefik-site.sh <domain> <port> [site-name]
#
# SSL: Auto-generated self-signed cert by default.
#      File certs used when /etc/traefik/certs/<site-name>/{fullchain,privkey}.pem exist.
#############################################

set -euo pipefail

# Environment-overridable paths (used by tests to redirect to temp dirs)
TRAEFIK_DYNAMIC_DIR="${TRAEFIK_DYNAMIC_DIR:-/etc/traefik/dynamic}"
TRAEFIK_CERTS_DIR="${TRAEFIK_CERTS_DIR:-/etc/traefik/certs}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${TEMPLATE_DIR:-$(dirname "$SCRIPT_DIR")/templates}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ── helpers ──────────────────────────────────────────────────────────────────

_validate_inputs() {
    local domain="$1" port="$2"

    if [[ -z "$domain" || -z "$port" ]]; then
        echo "Usage: $0 <domain> <port> [site-name]"
        echo ""
        echo "  $0 example.com 3001"
        echo "  $0 example.com 3001 mysite"
        return 1
    fi

    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        log_error "Invalid port: $port (must be 1–65535)"
        return 1
    fi

    if [[ ! -d "$TRAEFIK_DYNAMIC_DIR" ]]; then
        log_error "Traefik dynamic config directory not found: $TRAEFIK_DYNAMIC_DIR"
        log_error "Run install-traefik.sh first."
        return 1
    fi

    if [[ ! -f "$TEMPLATE_DIR/traefik/site.yml.template" ]]; then
        log_error "Template not found: $TEMPLATE_DIR/traefik/site.yml.template"
        return 1
    fi
}

_derive_site_name() {
    local domain="$1" site_name="$2"
    if [[ -z "$site_name" ]]; then
        echo "$domain" | tr '.' '-' | tr -cd '[:alnum:]-'
    else
        echo "$site_name"
    fi
}

_write_base_config() {
    local domain="$1" port="$2" site_name="$3"
    sed \
        -e "s|{{SITE_NAME}}|${site_name}|g" \
        -e "s|{{DOMAIN}}|${domain}|g" \
        -e "s|{{PORT}}|${port}|g" \
        "$TEMPLATE_DIR/traefik/site.yml.template" > "$TRAEFIK_DYNAMIC_DIR/${site_name}.yml"
    chmod 644 "$TRAEFIK_DYNAMIC_DIR/${site_name}.yml"
}

_has_file_cert() {
    local site_name="$1"
    [[ -f "$TRAEFIK_CERTS_DIR/${site_name}/fullchain.pem" && \
       -f "$TRAEFIK_CERTS_DIR/${site_name}/privkey.pem" ]]
}

_append_cert_config() {
    local site_name="$1"
    local config_file="$TRAEFIK_DYNAMIC_DIR/${site_name}.yml"

    if _has_file_cert "$site_name"; then
        log_info "File cert found — adding to config"
        cat >> "$config_file" <<EOF

tls:
  certificates:
    - certFile: ${TRAEFIK_CERTS_DIR}/${site_name}/fullchain.pem
      keyFile: ${TRAEFIK_CERTS_DIR}/${site_name}/privkey.pem
EOF
    else
        log_info "No file cert — Traefik will use auto-generated self-signed cert"
        log_info "To use a real cert, place fullchain.pem + privkey.pem in:"
        log_info "  ${TRAEFIK_CERTS_DIR}/${site_name}/"
    fi
}

_check_traefik_running() {
    if ! docker ps \
        --filter "name=^traefik$" \
        --filter "status=running" \
        --format "{{.Names}}" 2>/dev/null \
        | grep -q "^traefik$"; then
        log_warn "Traefik container is not running — start it with: docker start traefik"
    fi
}

# ── main ─────────────────────────────────────────────────────────────────────

main() {
    local domain="${1:-}"
    local port="${2:-}"
    local site_name="${3:-}"

    _validate_inputs "$domain" "$port" || exit 1
    site_name=$(_derive_site_name "$domain" "$site_name")

    _write_base_config "$domain" "$port" "$site_name"
    _append_cert_config "$site_name"
    _check_traefik_running

    echo ""
    log_info "Site config written — Traefik will route immediately (no reload needed)"
    echo ""
    echo "  Domain:  $domain"
    echo "  Port:    $port"
    echo "  Config:  $TRAEFIK_DYNAMIC_DIR/${site_name}.yml"
    echo ""
    echo "  Verify:  curl -sk https://$domain"
    echo "  API:     curl -s http://127.0.0.1:8080/api/http/routers/${site_name}@file"
    echo ""
}

# Allow sourcing without running main (enables unit testing of individual functions)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
