#!/bin/bash
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#############################################
# Install host-level observability agent
#
# Pluggable: a single installer that dispatches to provider-specific
# templates in templates/observability/<provider>.*
#
# Today only "newrelic" is supported. Adding another provider:
#   1. Drop templates/observability/<provider>.compose.template
#   2. Drop templates/observability/<provider>.egress (one FQDN per line)
#   3. Drop templates/observability/<provider>.validate.sh (key validator)
#   4. Add the name to SUPPORTED_PROVIDERS below
#
# Singleton per host. Lifecycle managed by systemd, not by any site's
# compose stack. Sites MUST NOT run their own copy of the agent — two
# agents on one host double-count host metrics.
#
# Usage:
#   install-observability.sh --provider=<name> --observability-key=<key> [--force]
#############################################

set -euo pipefail

SUPPORTED_PROVIDERS="newrelic"

# Environment-overridable paths (tests redirect to temp dirs)
OBS_ETC_DIR="${OBS_ETC_DIR:-/etc/observability}"
OBS_OPT_DIR="${OBS_OPT_DIR:-/opt/observability}"
OBS_SYSTEMD_DIR="${OBS_SYSTEMD_DIR:-/etc/systemd/system}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${TEMPLATE_DIR:-$(dirname "$SCRIPT_DIR")/templates}"
OBS_TEMPLATE_DIR="$TEMPLATE_DIR/observability"

PROVIDER=""
KEY=""
FORCE=false

for arg in "$@"; do
    case "$arg" in
        --provider=*) PROVIDER="${arg#*=}" ;;
        --observability-key=*) KEY="${arg#*=}" ;;
        --force) FORCE=true ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ── argument validation ─────────────────────────────────────────────────────

validate_args() {
    if [[ -z "$PROVIDER" ]]; then
        log_error "Missing --provider=<name>. Supported: ${SUPPORTED_PROVIDERS}"
        exit 1
    fi

    if ! echo "$SUPPORTED_PROVIDERS" | tr ' ' '\n' | grep -qx "$PROVIDER"; then
        log_error "Unknown provider '$PROVIDER'. Supported: ${SUPPORTED_PROVIDERS}"
        exit 1
    fi

    local compose_tmpl="$OBS_TEMPLATE_DIR/${PROVIDER}.compose.template"
    local egress_tmpl="$OBS_TEMPLATE_DIR/${PROVIDER}.egress"
    local validate_tmpl="$OBS_TEMPLATE_DIR/${PROVIDER}.validate.sh"

    for f in "$compose_tmpl" "$egress_tmpl" "$validate_tmpl"; do
        if [[ ! -f "$f" ]]; then
            log_error "Missing template: $f"
            exit 1
        fi
    done

    if [[ -z "$KEY" ]]; then
        log_error "Missing --observability-key=<key>"
        exit 1
    fi

    if ! bash "$validate_tmpl" "$KEY"; then
        # validator prints its own error
        exit 1
    fi
}

# ── idempotency check ───────────────────────────────────────────────────────

# Returns 0 if the existing install matches the requested state and we can exit.
already_configured() {
    [[ "$FORCE" == true ]] && return 1

    local env_file="$OBS_ETC_DIR/${PROVIDER}.env"
    local provider_file="$OBS_ETC_DIR/provider"
    local compose_file="$OBS_OPT_DIR/${PROVIDER}/docker-compose.yml"

    [[ -f "$env_file" ]] || return 1
    [[ -f "$provider_file" ]] || return 1
    [[ -f "$compose_file" ]] || return 1

    # Provider must match
    [[ "$(cat "$provider_file" 2> /dev/null)" == "$PROVIDER" ]] || return 1

    # Key must match
    grep -qxF "${PROVIDER_KEY_ENV_NAME}=${KEY}" "$env_file" 2> /dev/null || return 1

    # Service must be active
    systemctl is-active --quiet observability-agent.service 2> /dev/null || return 1

    return 0
}

# ── env name for each provider's licence key ────────────────────────────────

PROVIDER_KEY_ENV_NAME=""

set_key_env_name() {
    case "$PROVIDER" in
        newrelic) PROVIDER_KEY_ENV_NAME="NRIA_LICENSE_KEY" ;;
        *)
            log_error "No key env name configured for provider '$PROVIDER'"
            exit 1
            ;;
    esac
}

# ── write configs ───────────────────────────────────────────────────────────

write_dirs() {
    install -d -m 700 -o root -g root "$OBS_ETC_DIR"
    install -d -m 755 -o root -g root "$OBS_OPT_DIR"
    install -d -m 755 -o root -g root "$OBS_OPT_DIR/$PROVIDER"
}

write_provider_marker() {
    local provider_file="$OBS_ETC_DIR/provider"
    local tmp="${provider_file}.tmp"
    printf '%s\n' "$PROVIDER" > "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$provider_file"
}

write_env_file() {
    local env_file="$OBS_ETC_DIR/${PROVIDER}.env"
    local tmp="${env_file}.tmp"

    # Atomic write — tmp file inherits umask, then we lock it down before moving
    touch "$tmp"
    chmod 600 "$tmp"
    chown root:root "$tmp"
    printf '%s=%s\n' "$PROVIDER_KEY_ENV_NAME" "$KEY" > "$tmp"
    mv -f "$tmp" "$env_file"
    chmod 600 "$env_file"

    log_info "Wrote $env_file (mode 600, root:root)"
}

write_compose_file() {
    local src="$OBS_TEMPLATE_DIR/${PROVIDER}.compose.template"
    local dst="$OBS_OPT_DIR/${PROVIDER}/docker-compose.yml"
    cp "$src" "$dst"
    chmod 644 "$dst"
    log_info "Wrote $dst"
}

write_systemd_unit() {
    local src="$TEMPLATE_DIR/observability-agent.service.template"
    local dst="$OBS_SYSTEMD_DIR/observability-agent.service"
    if [[ ! -f "$src" ]]; then
        log_error "Missing systemd template: $src"
        exit 1
    fi
    cp "$src" "$dst"
    chmod 644 "$dst"
    log_info "Wrote $dst"
}

# ── lifecycle ───────────────────────────────────────────────────────────────

start_service() {
    log_info "Reloading systemd and starting observability-agent.service..."
    systemctl daemon-reload
    if systemctl is-active --quiet observability-agent.service 2> /dev/null; then
        systemctl restart observability-agent.service
    else
        systemctl enable --now observability-agent.service
    fi
}

# Poll up to 60s for the container to be running and (where applicable) healthy.
verify_running() {
    local container="newrelic-infra"
    case "$PROVIDER" in
        newrelic) container="newrelic-infra" ;;
    esac

    log_info "Waiting up to 60s for $container to be running..."
    local i=0
    while ((i < 60)); do
        local state
        state=$(docker inspect "$container" --format '{{.State.Status}}' 2> /dev/null || true)
        if [[ "$state" == "running" ]]; then
            local health
            health=$(docker inspect "$container" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2> /dev/null || echo "none")
            log_info "Container $container is running (health: $health)"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done

    log_warn "Container $container did not reach running state within 60s"
    log_warn "Check: docker logs $container"
    log_warn "Check: journalctl -u observability-agent.service --no-pager -n 50"
    return 1
}

configure_egress() {
    local egress_script="$SCRIPT_DIR/configure-observability-egress.sh"
    if [[ ! -x "$egress_script" ]]; then
        log_warn "Egress script not executable at $egress_script — skipping firewall config"
        log_warn "Outbound traffic to provider endpoints may be blocked by ufw"
        return 0
    fi

    log_info "Configuring egress allowlist for provider '$PROVIDER'..."
    local -a extra_args=()
    [[ "$FORCE" == true ]] && extra_args+=("--force")
    bash "$egress_script" --provider="$PROVIDER" "${extra_args[@]}"
}

# ── main ────────────────────────────────────────────────────────────────────

main() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi

    validate_args
    set_key_env_name

    if already_configured; then
        log_info "Observability agent for '$PROVIDER' already configured and running — skipping (use --force to reconfigure)"
        exit 0
    fi

    log_info "Installing observability agent: provider=$PROVIDER"

    write_dirs
    write_provider_marker
    write_env_file
    write_compose_file
    write_systemd_unit
    configure_egress
    start_service
    verify_running || true

    echo ""
    log_info "════════════════════════════════════════════"
    log_info "Observability agent installed: $PROVIDER"
    log_info "════════════════════════════════════════════"
    echo ""
    echo "  Provider:     $PROVIDER"
    echo "  Config:       $OBS_ETC_DIR/${PROVIDER}.env (root-only, mode 600)"
    echo "  Compose:      $OBS_OPT_DIR/${PROVIDER}/docker-compose.yml"
    echo "  Systemd unit: observability-agent.service"
    echo ""
    echo "  Status:       systemctl status observability-agent"
    echo "  Logs:         journalctl -u observability-agent -n 50"
    echo "  Agent logs:   docker logs newrelic-infra"
    echo ""
    case "$PROVIDER" in
        newrelic)
            echo "  Host should appear in New Relic (EU region) within ~2 minutes."
            echo "  Filter by custom attribute: managed_by = dockerHosting"
            ;;
    esac
    echo ""
    log_warn "Sites on this host MUST NOT run their own copy of the agent."
    log_warn "Two agents = double-counted host metrics + duplicate container reports."
    echo ""
}

# Allow sourcing for tests
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
