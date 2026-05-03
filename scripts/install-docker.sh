#!/bin/bash
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#############################################
# Install Docker and Docker Compose
# Based on serverSetup/debian/baseDocker.sh
# Updated for Debian Trixie
#############################################

set -e

FORCE=false
for arg in "$@"; do [[ "$arg" == "--force" ]] && FORCE=true; done

if [[ "$FORCE" == false ]] && command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
    echo "[INFO] Docker is already installed and running — skipping (use --force to reinstall)"
    docker --version
    docker compose version
    exit 0
fi

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

# Lower CPU/IO scheduling weight so containers yield to SSH and system processes
# under contention. Default weight is 100; 20 deprioritises containers without
# starving them. Applied to both daemon and containerd (where container processes
# actually live).
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/resource-limits.conf <<'EOF'
[Service]
CPUWeight=20
IOWeight=20
EOF

mkdir -p /etc/systemd/system/containerd.service.d
cat > /etc/systemd/system/containerd.service.d/resource-limits.conf <<'EOF'
[Service]
CPUWeight=20
IOWeight=20
EOF

systemctl daemon-reload

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
