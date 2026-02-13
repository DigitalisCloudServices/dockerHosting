#!/bin/bash

#############################################
# Install Docker and Docker Compose
# Based on serverSetup/debian/baseDocker.sh
# Updated for Debian Trixie
#############################################

set -e

echo "[INFO] Installing Docker and Docker Compose..."

# Update package index
apt-get update

# Install prerequisites
apt-get install -y ca-certificates curl gnupg lsb-release

# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add Docker repository to apt sources
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package index with Docker repo
apt-get update

# Remove old docker-compose package if it exists (conflicts with docker-compose-plugin)
if dpkg -l | grep -q "^ii  docker-compose "; then
    echo "[INFO] Removing old docker-compose package..."
    apt-get remove -y docker-compose
fi

# Install Docker Engine, CLI, containerd, and plugins
apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# Allow docker in rootless mode to work on ports lower than 1024
setcap 'cap_net_bind_service=+ep' /usr/bin/docker

# Start and enable Docker service
systemctl start docker
systemctl enable docker
systemctl restart docker

# Add current user to docker group (if not root)
if [ -n "$SUDO_USER" ]; then
    usermod -aG docker "$SUDO_USER"
    echo "[INFO] Added $SUDO_USER to docker group"
fi

# Verify installation
echo ""
echo "[INFO] Docker installation complete!"
docker --version
docker compose version
echo ""
