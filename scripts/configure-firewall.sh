#!/bin/bash
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#############################################
# Configure UFW firewall with sensible defaults.
#
# Design note: this script must never disable a running ufw, and must
# never trigger a full disable→enable cycle. On Debian Trixie's
# iptables-nft backend, that transition has been observed to drop
# in-flight SSH sessions (the conntrack ESTABLISHED accept rule is not
# reliably matching across the flush window). Instead:
#   - If ufw is already active, apply each rule incrementally with
#     `ufw allow …` / `ufw default …` (no disable/enable).
#   - If ufw is inactive, stage SSH allow FIRST in the config, then
#     remaining rules, then default-deny policies, and only then call
#     `ufw enable` once. SSH being the first rule guarantees the cold
#     enable cannot orphan the management session.
#############################################

set -e

FORCE=false
NO_DETACH=false
RESET=false
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        --no-detach) NO_DETACH=true ;;
        --reset)
            RESET=true
            FORCE=true # reset only makes sense when we proceed to reconfigure
            ;;
    esac
done

# ── Auto-detach via systemd-run ─────────────────────────────────────────────
# Re-exec under a transient systemd unit so the reconfiguration survives a
# stalled SSH session. The unit is owned by systemd, not by the user session,
# so SIGHUP to the SSH shell does not propagate to it. We `--wait --pty` so
# interactive output is preserved; if the SSH session dies mid-run, reconnect
# and inspect with `journalctl -u <unit> -b` (the unit name is printed below).
if [[ "${UFW_DETACHED:-0}" != "1" ]] &&
    [[ "$NO_DETACH" == false ]] &&
    command -v systemd-run > /dev/null 2>&1; then
    UNIT="ufw-reconfig-$$"
    echo "[INFO] Detaching firewall reconfiguration as systemd unit: $UNIT"
    echo "[INFO] If SSH stalls, reconnect and run: journalctl -u $UNIT -b"
    exec systemd-run \
        --unit="$UNIT" \
        --collect \
        --setenv=UFW_DETACHED=1 \
        --pty --wait --quiet \
        "$0" "$@"
fi

echo "[INFO] Configuring UFW firewall..."

if ! command -v ufw &> /dev/null; then
    echo "[INFO] Installing UFW..."
    apt-get install -y ufw
fi

UFW_ACTIVE=false
if ufw status 2> /dev/null | grep -q "Status: active"; then
    UFW_ACTIVE=true
fi

if [[ "$UFW_ACTIVE" == true && "$FORCE" == false ]]; then
    echo "[INFO] Firewall already active — skipping (use --force to reapply rules in place)"
    ufw status verbose
    exit 0
fi

# ── Optional clean slate ────────────────────────────────────────────────────
# --reset wipes ufw user rules and disables it before we reconfigure. Safe
# for the live SSH session: `ufw --force reset` sets policies back to ACCEPT
# (effectively no firewall) and backs up the prior config to /etc/ufw/*.<ts>.
# We then fall through into the normal cold-start path below, which already
# includes the tcp_loose conntrack safeguard.
if [[ "$RESET" == true ]]; then
    echo "[INFO] Resetting UFW (--reset) — prior rules backed up to /etc/ufw/*.<timestamp>"
    ufw --force reset > /dev/null
    UFW_ACTIVE=false
fi

# ── SSH first, always ───────────────────────────────────────────────────────
# Add SSH inbound before anything else so a cold `ufw enable` (below) loads
# this rule alongside the new default-deny in a single atomic apply.
echo "[INFO] Ensuring SSH inbound allow rule is present..."
ufw allow in 22/tcp comment 'SSH' > /dev/null

# ── Other inbound ───────────────────────────────────────────────────────────
ufw allow in 80/tcp comment 'HTTP' > /dev/null
ufw allow in 443/tcp comment 'HTTPS' > /dev/null
ufw allow in from 172.16.0.0/12 > /dev/null
ufw allow in from 192.168.0.0/16 > /dev/null

# ── Outbound ────────────────────────────────────────────────────────────────
ufw allow out 53/udp comment 'DNS' > /dev/null
ufw allow out 53/tcp comment 'DNS (TCP)' > /dev/null
ufw allow out 853/tcp comment 'DNS over TLS' > /dev/null
ufw allow out 80/tcp comment 'HTTP out' > /dev/null
ufw allow out 443/tcp comment 'HTTPS out' > /dev/null
ufw allow out 123/udp comment 'NTP' > /dev/null
ufw allow out 587/tcp comment 'SMTP submission' > /dev/null
ufw allow out on lo > /dev/null

# ── Default policies ────────────────────────────────────────────────────────
# Applied AFTER allow rules. On a running ufw, each `ufw default` writes the
# new policy and performs an internal sync that preserves established
# conntrack. On an inactive ufw, these are config-only until `ufw enable`.
ufw default deny incoming > /dev/null
ufw default deny outgoing > /dev/null
ufw default deny forward > /dev/null

if [[ "$UFW_ACTIVE" == false ]]; then
    # Preserve existing connections (notably the SSH session running this
    # script) across the cold start. Until ufw enables, nf_conntrack is not
    # loaded and the live SSH connection has no entry in the conntrack table.
    # When ufw enable loads conntrack, mid-stream packets from that session
    # cannot be matched against a SYN and — with the kernel default
    # nf_conntrack_tcp_loose=0 — are classified as INVALID and dropped by
    # ufw's INVALID-drop rule. Setting tcp_loose=1 makes conntrack accept
    # mid-stream packets as ESTABLISHED so the existing session survives.
    modprobe nf_conntrack > /dev/null 2>&1 || true
    if [[ -w /proc/sys/net/netfilter/nf_conntrack_tcp_loose ]]; then
        echo "[INFO] Setting nf_conntrack_tcp_loose=1 to preserve in-flight sessions"
        echo 1 > /proc/sys/net/netfilter/nf_conntrack_tcp_loose
    fi

    echo "[INFO] Enabling UFW firewall (cold start)..."
    ufw --force enable
else
    echo "[INFO] Rules applied to running firewall (no disable/enable cycle)"
fi

echo ""
echo "[INFO] Firewall configuration complete!"
ufw status verbose
echo ""

echo "[INFO] Default rules configured:"
echo "  - Inbound:  SSH (22), HTTP (80), HTTPS (443), Docker bridge networks"
echo "  - Outbound: DNS (53), DNS-over-TLS (853), HTTP (80), HTTPS (443), NTP (123/udp), SMTP (587), loopback"
echo "  - All other inbound/outbound: DENIED"
echo ""
echo "[INFO] To allow additional ports, use:"
echo "  sudo ufw allow <port>/tcp    # inbound"
echo "  sudo ufw allow out <port>/tcp  # outbound"
echo ""
