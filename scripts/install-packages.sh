#!/bin/bash

#############################################
# Install essential packages for Debian Trixie
#############################################

set -e

echo "[INFO] Installing essential packages..."

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(dirname "$SCRIPT_DIR")/config"

# Check if packages.list exists
if [ -f "$CONFIG_DIR/packages.list" ]; then
    echo "[INFO] Installing packages from packages.list..."

    # Read packages from file and install
    PACKAGES=$(grep -v '^#' "$CONFIG_DIR/packages.list" | grep -v '^$' | tr '\n' ' ')

    if [ -n "$PACKAGES" ]; then
        apt-get install -y $PACKAGES
    fi
else
    echo "[WARN] packages.list not found, installing default packages..."

    # Default essential packages (minimal installation)
    apt-get install -y \
        curl \
        wget \
        git \
        rsync \
        ca-certificates \
        gnupg \
        lsb-release \
        apt-transport-https \
        nano \
        htop \
        iotop \
        lsof \
        net-tools \
        dnsutils \
        unattended-upgrades \
        ufw \
        fail2ban \
        logrotate \
        unzip \
        zip \
        gzip \
        tar \
        screen \
        jq \
        default-mysql-client \
        python3
fi

echo "[INFO] Package installation complete!"
