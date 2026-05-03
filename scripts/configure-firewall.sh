#!/bin/bash
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#############################################
# Configure UFW firewall with sensible defaults
#############################################

set -e

echo "[INFO] Configuring UFW firewall..."

FORCE=false
for arg in "$@"; do [[ "$arg" == "--force" ]] && FORCE=true; done

if [[ "$FORCE" == false ]] && command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    echo "[INFO] Firewall already configured and active — skipping (use --force to reconfigure)"
    ufw status verbose
    exit 0
fi

# Install UFW if not present
if ! command -v ufw &> /dev/null; then
    echo "[INFO] Installing UFW..."
    apt-get install -y ufw
fi

# Disable UFW temporarily to configure
ufw --force disable

# Set default policies — deny all inbound; explicit allow-list for outbound
ufw default deny incoming
ufw default deny outgoing
ufw default deny forward

# --- INBOUND ---
ufw allow in 22/tcp  comment 'SSH'
ufw allow in 80/tcp  comment 'HTTP'
ufw allow in 443/tcp comment 'HTTPS'

# Allow traffic from Docker bridge networks (container → host)
ufw allow in from 172.16.0.0/12
ufw allow in from 192.168.0.0/16

# --- OUTBOUND ---
# DNS (standard — UDP + TCP for large responses/zone transfers)
ufw allow out 53/udp  comment 'DNS'
ufw allow out 53/tcp  comment 'DNS (TCP)'
# DNS over TLS (encrypted DNS — e.g. systemd-resolved stub, Unbound)
ufw allow out 853/tcp comment 'DNS over TLS'
# HTTP/HTTPS (apt updates, Docker pulls, Let's Encrypt, DNS over HTTPS via 443)
ufw allow out 80/tcp  comment 'HTTP out'
ufw allow out 443/tcp comment 'HTTPS out'
# NTP (chrony)
ufw allow out 123/udp comment 'NTP'
# SMTP submission (msmtp / email notifications)
ufw allow out 587/tcp comment 'SMTP submission'
# Loopback (always required for local inter-process communication)
ufw allow out on lo

# Enable UFW
echo "[INFO] Enabling UFW firewall..."
ufw --force enable

# Show status
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
