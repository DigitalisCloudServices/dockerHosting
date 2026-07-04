#!/bin/bash
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#############################################
# Update the upstream port in an existing Traefik dynamic config.
#
# Surgical replacement — preserves hand customisations (multi-host
# router rules, extra middlewares, TLS blocks). Only rewrites
# occurrences of `127.0.0.1:<digits>` inside the site's config file.
#
# Usage: ./update-traefik-port.sh <site-name> <new-port>
#
# Exits 0 on success (including no-op when port already matches).
# Exits 1 on invalid input or missing config file.
#############################################

set -euo pipefail

TRAEFIK_DYNAMIC_DIR="${TRAEFIK_DYNAMIC_DIR:-/etc/traefik/dynamic}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

_validate_inputs() {
    local site_name="$1" port="$2"

    if [[ -z "$site_name" || -z "$port" ]]; then
        echo "Usage: $0 <site-name> <new-port>"
        return 1
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        log_error "Invalid port: $port (must be 1–65535)"
        return 1
    fi
}

# Extract the (first) upstream port currently written into the site's config.
# Prints nothing and returns 1 if no port line is found.
_current_port() {
    local config_file="$1"
    local port
    port=$(grep -oE '127\.0\.0\.1:[0-9]+' "$config_file" 2> /dev/null |
        head -1 | cut -d: -f2)
    if [[ -z "$port" ]]; then
        return 1
    fi
    echo "$port"
}

# In-place substitution that works with both GNU sed (Debian prod) and BSD sed
# (macOS dev). Uses a temp file so we don't depend on sed -i portability.
_patch_port() {
    local config_file="$1" new_port="$2"
    local tmp
    tmp=$(mktemp)
    sed -E "s|(127\.0\.0\.1):[0-9]+|\1:${new_port}|g" "$config_file" > "$tmp"
    # Preserve original mode + owner.
    if [[ -f "$config_file" ]]; then
        chmod --reference="$config_file" "$tmp" 2> /dev/null ||
            chmod 644 "$tmp"
    fi
    mv "$tmp" "$config_file"
}

main() {
    local site_name="${1:-}"
    local new_port="${2:-}"

    _validate_inputs "$site_name" "$new_port" || exit 1

    local config_file="$TRAEFIK_DYNAMIC_DIR/${site_name}.yml"
    if [[ ! -f "$config_file" ]]; then
        log_error "Traefik config not found: $config_file"
        exit 1
    fi

    local current_port
    if ! current_port=$(_current_port "$config_file"); then
        log_error "No upstream port found in $config_file — nothing to patch"
        exit 1
    fi

    if [[ "$current_port" == "$new_port" ]]; then
        log_info "Traefik upstream port already ${new_port} — no change"
        exit 0
    fi

    log_warn "Traefik upstream port drift: ${current_port} → ${new_port}"
    _patch_port "$config_file" "$new_port"
    log_info "Patched $config_file (${current_port} → ${new_port})"
    log_info "Traefik hot-reloads dynamic configs; no restart needed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
