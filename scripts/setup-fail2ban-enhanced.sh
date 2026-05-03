#!/bin/bash
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#############################################
# Enhanced fail2ban Configuration
#
# Extends fail2ban protection beyond SSH:
# - Nginx HTTP authentication failures
# - Nginx rate limiting violations
# - Nginx bad bot detection
# - SSL handshake abuse
# - Nginx 4xx errors (scanning attempts)
#
# Based on: Common attack patterns, OWASP guidelines
#############################################

set -e

echo "[INFO] Setting up enhanced fail2ban configuration..."

FORCE=false
for arg in "$@"; do [[ "$arg" == "--force" ]] && FORCE=true; done

if [[ "$FORCE" == false ]] && [[ -f /etc/fail2ban/jail.d/sshd-enhanced.conf ]]; then
    echo "[INFO] Enhanced fail2ban already configured — skipping (use --force to reconfigure)"
    exit 0
fi

# Ensure fail2ban is installed
if ! command -v fail2ban-client &> /dev/null; then
    echo "[ERROR] fail2ban is not installed"
    exit 1
fi

mkdir -p /etc/fail2ban/jail.d

# Remove stale nginx jail config if present from a previous run
rm -f /etc/fail2ban/jail.d/nginx-enhanced.conf

echo "[INFO] Configured fail2ban jails (SSH only — Traefik logs to stdout, not a file)"

# Update SSH jail with stricter settings (already exists, enhance it)
cat > /etc/fail2ban/jail.d/sshd-enhanced.conf <<'EOF'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
findtime = 600
bantime = 3600
# Ban persistent attackers for longer
bantime.increment = true
bantime.multipliers = 1 2 4 8 16 32 64
bantime.maxtime = 604800
EOF

echo "[INFO] Enhanced SSH jail configuration"

# Restart fail2ban to apply changes
echo "[INFO] Restarting fail2ban..."
systemctl restart fail2ban

# Wait for fail2ban to start
sleep 2

# Verify fail2ban is running
if systemctl is-active --quiet fail2ban; then
    echo "[INFO] fail2ban restarted successfully"
else
    echo "[ERROR] fail2ban failed to start!"
    echo "[ERROR] Check logs: journalctl -xeu fail2ban"
    exit 1
fi

# Display active jails
echo ""
echo "[INFO] Active fail2ban jails:"
fail2ban-client status

echo ""
echo "[INFO] ════════════════════════════════════════════"
echo "[INFO] fail2ban Enhanced Protection Complete!"
echo "[INFO] ════════════════════════════════════════════"
echo ""
echo "[INFO] Protection enabled for:"
echo "  ✓ SSH brute-force (3 attempts, 1 hour ban, progressive)"
echo ""
echo "[INFO] Ban time escalation (SSH):"
echo "  1st ban: 1 hour"
echo "  2nd ban: 2 hours"
echo "  3rd ban: 4 hours"
echo "  4th ban: 8 hours"
echo "  ... up to 7 days maximum"
echo ""
echo "[INFO] Useful commands:"
echo "  - Check status: fail2ban-client status"
echo "  - Check specific jail: fail2ban-client status nginx-http-auth"
echo "  - List banned IPs: fail2ban-client banned"
echo "  - Unban IP: fail2ban-client unban <ip>"
echo "  - View logs: tail -f /var/log/fail2ban.log"
echo ""
