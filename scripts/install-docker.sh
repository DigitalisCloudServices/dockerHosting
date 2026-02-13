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

# Install Docker Engine, CLI, containerd, and plugins
apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin \
    docker-compose

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

# Install Node Version Manager (optional, useful for many projects)
if [ -n "$SUDO_USER" ]; then
    echo "[INFO] Installing Node Version Manager for $SUDO_USER..."
    sudo -u "$SUDO_USER" bash -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash'

    # Load NVM and install Node 20
    sudo -u "$SUDO_USER" bash -c '
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        nvm install 20
        nvm use 20
    '
fi

# Verify installation
echo ""
echo "[INFO] Docker installation complete!"
docker --version
docker compose version
echo ""
