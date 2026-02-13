#!/bin/bash

#############################################
# Configure UFW firewall with sensible defaults
#############################################

set -e

echo "[INFO] Configuring UFW firewall..."

# Install UFW if not present
if ! command -v ufw &> /dev/null; then
    echo "[INFO] Installing UFW..."
    apt-get install -y ufw
fi

# Disable UFW temporarily to configure
ufw --force disable

# Set default policies
ufw default deny incoming
ufw default allow outgoing

# Allow SSH (important!)
ufw allow 22/tcp comment 'SSH'

# Allow HTTP and HTTPS
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

# Allow Docker networking (important for container communication)
# Allow traffic on Docker networks
ufw allow from 172.16.0.0/12 to any
ufw allow from 192.168.0.0/16 to any

# Enable UFW
echo "[INFO] Enabling UFW firewall..."
ufw --force enable

# Show status
echo ""
echo "[INFO] Firewall configuration complete!"
ufw status verbose
echo ""

echo "[INFO] Default rules configured:"
echo "  - SSH (22/tcp): ALLOWED"
echo "  - HTTP (80/tcp): ALLOWED"
echo "  - HTTPS (443/tcp): ALLOWED"
echo "  - Docker networks: ALLOWED"
echo ""
echo "[INFO] To allow additional ports, use:"
echo "  sudo ufw allow <port>/tcp"
echo ""
