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

    # Default essential packages
    apt-get install -y \
        curl \
        wget \
        git \
        vim \
        nano \
        htop \
        net-tools \
        dnsutils \
        ca-certificates \
        gnupg \
        lsb-release \
        software-properties-common \
        apt-transport-https \
        build-essential \
        make \
        ufw \
        fail2ban \
        logrotate \
        rsync \
        unzip \
        jq \
        tree \
        ncdu \
        tmux \
        screen
fi

echo "[INFO] Package installation complete!"
