#!/bin/bash
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#############################################
# Configure egress allowlist for the observability agent
#
# Approach: ipset + systemd timer (no DNS layer change).
# - Creates ipset 'obs_egress_ips' (hash:ip, family inet).
# - Resolves each FQDN in templates/observability/<provider>.egress
#   via getent (uses the system resolver — typically systemd-resolved).
# - Adds the resulting IPs to the set.
# - Adds a ufw rule allowing 443/tcp to that set.
# - Installs a systemd timer (boot + daily) to refresh the set.
#
# Why not dnsmasq+ipset: that pattern auto-populates from live DNS
# lookups, useful for many or unknown FQDNs. We have a fixed 4-FQDN
# list known at install time, so a periodic refresh is sufficient and
# keeps systemd-resolved as the system resolver.
#
# Usage:
#   configure-observability-egress.sh --provider=<name> [--force]
#############################################

set -euo pipefail

OBS_ETC_DIR="${OBS_ETC_DIR:-/etc/observability}"
OBS_SYSTEMD_DIR="${OBS_SYSTEMD_DIR:-/etc/systemd/system}"
IPSET_NAME="${IPSET_NAME:-obs_egress_ips}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${TEMPLATE_DIR:-$(dirname "$SCRIPT_DIR")/templates}"
OBS_TEMPLATE_DIR="$TEMPLATE_DIR/observability"

PROVIDER=""
FORCE=false
NO_DETACH=false

for arg in "$@"; do
    case "$arg" in
        --provider=*) PROVIDER="${arg#*=}" ;;
        --force) FORCE=true ;;
        --no-detach) NO_DETACH=true ;;
    esac
done

# ── Auto-detach via systemd-run ─────────────────────────────────────────────
# Re-exec under a transient systemd unit so the work survives a stalled SSH
# session. The unit is owned by systemd, not by the user session, so SIGHUP
# to the SSH shell does not propagate to it. If SSH dies mid-run, reconnect
# and inspect with `journalctl -u <unit> -b`.
if [[ "${OBS_EGRESS_DETACHED:-0}" != "1" ]] &&
    [[ "$NO_DETACH" == false ]] &&
    command -v systemd-run > /dev/null 2>&1; then
    UNIT="obs-egress-reconfig-$$"
    echo "[INFO] Detaching reconfiguration as systemd unit: $UNIT"
    echo "[INFO] If SSH stalls, reconnect and run: journalctl -u $UNIT -b"
    exec systemd-run \
        --unit="$UNIT" \
        --collect \
        --setenv=OBS_EGRESS_DETACHED=1 \
        --pty --wait --quiet \
        "$0" "$@"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ -z "$PROVIDER" ]]; then
    log_error "Missing --provider=<name>"
    exit 1
fi

# Runtime override takes precedence over the shipped template. Providers
# whose endpoint is operator-supplied (e.g. OpenTelemetry — the OTLP back-end
# varies per deployment) write a runtime file to /etc/observability/.
RUNTIME_EGRESS_FILE="$OBS_ETC_DIR/${PROVIDER}.egress"
TEMPLATE_EGRESS_FILE="$OBS_TEMPLATE_DIR/${PROVIDER}.egress"

if [[ -f "$RUNTIME_EGRESS_FILE" ]]; then
    EGRESS_FILE="$RUNTIME_EGRESS_FILE"
elif [[ -f "$TEMPLATE_EGRESS_FILE" ]]; then
    EGRESS_FILE="$TEMPLATE_EGRESS_FILE"
else
    log_error "Egress FQDN list not found: $RUNTIME_EGRESS_FILE or $TEMPLATE_EGRESS_FILE"
    exit 1
fi

# ── ensure dependencies ─────────────────────────────────────────────────────

ensure_packages() {
    local need=()
    command -v ipset > /dev/null 2>&1 || need+=(ipset)
    command -v getent > /dev/null 2>&1 || true # getent is in libc-bin, always present
    if ((${#need[@]} > 0)); then
        log_info "Installing required packages: ${need[*]}"
        apt-get update
        apt-get install -y "${need[@]}"
    fi
}

# ── ipset setup ─────────────────────────────────────────────────────────────

create_ipset() {
    # ipset persists in memory; we recreate idempotently. Persistence across
    # reboots is provided by the refresh service ExecStartPre below.
    if ipset list "$IPSET_NAME" > /dev/null 2>&1; then
        log_info "ipset '$IPSET_NAME' already exists"
        if [[ "$FORCE" == true ]]; then
            log_info "Flushing existing ipset (--force)"
            ipset flush "$IPSET_NAME"
        fi
    else
        ipset create "$IPSET_NAME" hash:ip family inet timeout 0
        log_info "Created ipset '$IPSET_NAME'"
    fi
}

populate_ipset() {
    local fqdn ip added=0 total=0
    while IFS= read -r fqdn; do
        # Strip comments and trim
        fqdn="${fqdn%%#*}"
        fqdn="$(echo "$fqdn" | tr -d '[:space:]')"
        [[ -z "$fqdn" ]] && continue
        total=$((total + 1))

        # getent returns one or more "<ip>  <canonical>  <alias>..." lines.
        # Take all IPv4 addresses.
        while IFS=' ' read -r ip _; do
            [[ -z "$ip" ]] && continue
            # Skip IPv6 — ipset is family inet
            [[ "$ip" == *:* ]] && continue
            if ipset add "$IPSET_NAME" "$ip" -exist; then
                added=$((added + 1))
            fi
        done < <(getent ahostsv4 "$fqdn" 2> /dev/null | awk '{print $1}' | sort -u | sed 's/.*/& /')
    done < "$EGRESS_FILE"

    log_info "ipset '$IPSET_NAME': $added entries from $total FQDNs"
}

# ── ufw rule ────────────────────────────────────────────────────────────────

apply_ufw_rule() {
    if ! command -v ufw > /dev/null 2>&1; then
        log_warn "ufw not installed — skipping firewall rule. Outbound to observability endpoints may not work."
        return 0
    fi

    # ufw does not natively understand ipsets, so we drop a raw iptables rule
    # via ufw's before.rules mechanism. The rule is idempotent: we tag it with
    # a comment and remove any prior copy before re-adding.
    local before_rules="/etc/ufw/before.rules"
    local marker="# dockerHosting:observability-egress"
    local rule="-A ufw-before-output -p tcp -m set --match-set ${IPSET_NAME} dst --dport 443 -j ACCEPT ${marker}"

    if [[ ! -f "$before_rules" ]]; then
        log_warn "$before_rules not found — skipping ipset ufw rule"
        return 0
    fi

    # Remove any prior dockerHosting:observability-egress lines
    if grep -q "$marker" "$before_rules" 2> /dev/null; then
        local tmp
        tmp="$(mktemp)"
        grep -v "$marker" "$before_rules" > "$tmp"
        mv -f "$tmp" "$before_rules"
        chmod 640 "$before_rules"
    fi

    # Insert the rule before the COMMIT in the *filter table section.
    # before.rules uses iptables-restore syntax with explicit *filter / COMMIT blocks.
    awk -v rule="$rule" '
        BEGIN { in_filter = 0; inserted = 0 }
        /^\*filter/ { in_filter = 1 }
        in_filter && /^COMMIT/ && !inserted {
            print rule
            inserted = 1
            in_filter = 0
        }
        { print }
    ' "$before_rules" > "${before_rules}.tmp"
    mv -f "${before_rules}.tmp" "$before_rules"
    chmod 640 "$before_rules"

    log_info "Added ufw rule for ipset '$IPSET_NAME' (443/tcp out)"

    # Apply the rule to the running firewall directly. We avoid `ufw reload`
    # because it flushes and rebuilds the ruleset non-atomically, which drops
    # the conntrack ESTABLISHED accept rule long enough to kill in-flight SSH
    # sessions. The rule is already persisted in before.rules above, so reboot
    # / future reloads pick it up.
    if ufw status 2> /dev/null | grep -q "Status: active"; then
        if ! iptables -C ufw-before-output -p tcp -m set --match-set "$IPSET_NAME" dst \
            --dport 443 -j ACCEPT 2> /dev/null; then
            iptables -I ufw-before-output -p tcp -m set --match-set "$IPSET_NAME" dst \
                --dport 443 -j ACCEPT
            log_info "Inserted live iptables rule for ipset '$IPSET_NAME'"
        else
            log_info "Live iptables rule for ipset '$IPSET_NAME' already present"
        fi
    fi
}

# ── refresh service + timer ─────────────────────────────────────────────────

install_refresh_unit() {
    local refresh_script="/usr/local/sbin/observability-egress-refresh"
    local svc="$OBS_SYSTEMD_DIR/observability-egress-refresh.service"
    local tmr="$OBS_SYSTEMD_DIR/observability-egress-refresh.timer"

    cat > "$refresh_script" << 'REFRESH_EOF'
#!/bin/bash
# Re-resolve the observability provider's FQDN allowlist into the ipset.
# Installed by configure-observability-egress.sh.
set -euo pipefail

IPSET_NAME="obs_egress_ips"
OBS_ETC_DIR="/etc/observability"
OBS_TEMPLATE_DIR="/opt/dockerHosting/templates/observability"

provider_file="$OBS_ETC_DIR/provider"
[[ -f "$provider_file" ]] || { echo "no provider configured"; exit 0; }
provider="$(cat "$provider_file")"

runtime_egress="$OBS_ETC_DIR/${provider}.egress"
template_egress="$OBS_TEMPLATE_DIR/${provider}.egress"
if [[ -f "$runtime_egress" ]]; then
    egress_file="$runtime_egress"
elif [[ -f "$template_egress" ]]; then
    egress_file="$template_egress"
else
    echo "no egress file for $provider"; exit 0
fi

# Recreate the set fresh so stale IPs eventually age out.
if ipset list "$IPSET_NAME" >/dev/null 2>&1; then
    ipset create "${IPSET_NAME}_new" hash:ip family inet timeout 0
else
    ipset create "$IPSET_NAME" hash:ip family inet timeout 0
    ipset create "${IPSET_NAME}_new" hash:ip family inet timeout 0
fi

while IFS= read -r fqdn; do
    fqdn="${fqdn%%#*}"
    fqdn="$(echo "$fqdn" | tr -d '[:space:]')"
    [[ -z "$fqdn" ]] && continue
    while IFS=' ' read -r ip _; do
        [[ -z "$ip" || "$ip" == *:* ]] && continue
        ipset add "${IPSET_NAME}_new" "$ip" -exist
    done < <(getent ahostsv4 "$fqdn" 2>/dev/null | awk '{print $1}' | sort -u | sed 's/.*/& /')
done < "$egress_file"

# Atomic swap
ipset swap "${IPSET_NAME}_new" "$IPSET_NAME"
ipset destroy "${IPSET_NAME}_new"
REFRESH_EOF
    chmod 755 "$refresh_script"

    cat > "$svc" << EOF
[Unit]
Description=Refresh observability egress ipset from provider FQDN list
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$refresh_script
EOF
    chmod 644 "$svc"

    cat > "$tmr" << 'EOF'
[Unit]
Description=Daily refresh of observability egress ipset

[Timer]
OnBootSec=2min
OnUnitActiveSec=24h
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    chmod 644 "$tmr"

    systemctl daemon-reload
    systemctl enable --now observability-egress-refresh.timer
    log_info "Installed observability-egress-refresh.timer (boot + daily)"
}

# ── main ────────────────────────────────────────────────────────────────────

main() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi

    ensure_packages
    create_ipset
    populate_ipset
    apply_ufw_rule
    install_refresh_unit

    log_info "Egress allowlist configured for provider '$PROVIDER'"
    log_info "View ipset: ipset list $IPSET_NAME"
    log_info "View timer: systemctl status observability-egress-refresh.timer"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
