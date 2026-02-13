#!/bin/bash

#############################################
# Quick Docker Recovery Script
# Restores Docker to a working state
#############################################

set -e

# Auto-elevate to root if not already running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script requires root privileges. Re-running with sudo..."
    exec sudo "$0" "$@"
fi

echo "[INFO] Recovering Docker configuration..."

# Find the most recent backup
BACKUP=$(ls -t /etc/docker/daemon.json.backup.* 2>/dev/null | head -n1)

if [ -z "$BACKUP" ]; then
    echo "[WARN] No backup found, creating minimal working configuration..."

    # Create minimal daemon.json
    cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true,
  "storage-driver": "overlay2",
  "exec-opts": ["native.cgroupdriver=systemd"]
}
EOF
    echo "[INFO] Created minimal daemon.json"
else
    echo "[INFO] Restoring from backup: $BACKUP"
    cp "$BACKUP" /etc/docker/daemon.json
fi

# Restart Docker
echo "[INFO] Restarting Docker..."
systemctl restart docker

# Wait and verify
sleep 3

if systemctl is-active --quiet docker; then
    echo ""
    echo "[INFO] ✓ Docker recovered successfully!"
    docker version
else
    echo ""
    echo "[ERROR] Docker still failing. Check logs:"
    echo "  sudo journalctl -xeu docker.service -n 50"
fi
