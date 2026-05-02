#!/bin/bash

#############################################
# Remove a Site from Traefik Routing
#
# Deletes the dynamic config file for a site.
# Traefik hot-reloads automatically — no restart needed.
#
# Usage: ./remove-traefik-site.sh <domain-or-site-name>
#
# Examples:
#   ./remove-traefik-site.sh example.com
#   ./remove-traefik-site.sh example-com
#############################################

set -euo pipefail

# Environment-overridable path (used by tests to redirect to temp dirs)
TRAEFIK_DYNAMIC_DIR="${TRAEFIK_DYNAMIC_DIR:-/etc/traefik/dynamic}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ── helpers ──────────────────────────────────────────────────────────────────

_domain_to_site_name() {
    echo "$1" | tr '.' '-' | tr -cd '[:alnum:]-'
}

_list_sites() {
    local sites
    sites=$(find "$TRAEFIK_DYNAMIC_DIR" -maxdepth 1 -name "*.yml" -not -name "middleware.yml" \
        -exec basename {} .yml \; 2>/dev/null | sort)
    if [[ -z "$sites" ]]; then
        echo "  (none)"
    else
        echo "$sites" | sed 's/^/  /'
    fi
}

# ── main ─────────────────────────────────────────────────────────────────────

main() {
    local input="${1:-}"

    if [[ -z "$input" ]]; then
        echo "Usage: $0 <domain-or-site-name>"
        echo ""
        echo "  $0 example.com"
        echo "  $0 example-com"
        echo ""
        echo "Existing sites:"
        _list_sites
        exit 1
    fi

    local site_name config_file
    site_name=$(_domain_to_site_name "$input")
    config_file="$TRAEFIK_DYNAMIC_DIR/${site_name}.yml"

    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        echo ""
        echo "Existing sites:"
        _list_sites
        exit 1
    fi

    rm -f "$config_file"
    log_info "Removed: $config_file"
    log_info "Traefik will stop routing $input immediately (no reload needed)"
    echo ""
}

# Allow sourcing without running main (enables unit testing of individual functions)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
