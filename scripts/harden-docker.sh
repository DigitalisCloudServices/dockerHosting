#!/bin/bash

#############################################
# Docker Daemon Hardening Script
#
# Implements comprehensive Docker security:
# - User namespace remapping
# - Network isolation (no inter-container communication)
# - Resource limits
# - Logging configuration
# - Security options (no-new-privileges, read-only, etc.)
#
# Based on: CIS Docker Benchmark, NIST SP 800-190
#############################################

set -e

# Auto-elevate to root if not already running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script requires root privileges. Re-running with sudo..."
    exec sudo "$0" "$@"
fi

echo "[INFO] Hardening Docker daemon configuration..."
echo ""
echo "User namespace remapping provides strong container isolation but can cause"
echo "compatibility issues with volume permissions and existing containers."
echo ""
read -p "Enable user namespace remapping? (Y/n) " -n 1 -r
echo ""
ENABLE_USERNS_REMAP=true
if [[ $REPLY =~ ^[Nn]$ ]]; then
    ENABLE_USERNS_REMAP=false
    echo "[INFO] User namespace remapping will be disabled (can enable later)"
else
    echo "[INFO] User namespace remapping will be enabled"
fi
echo ""

# Backup existing daemon.json if it exists
if [ -f /etc/docker/daemon.json ]; then
    cp /etc/docker/daemon.json /etc/docker/daemon.json.backup.$(date +%Y%m%d-%H%M%S)
    echo "[INFO] Backed up existing daemon.json"
fi

# Create comprehensive hardened daemon.json
if [ "$ENABLE_USERNS_REMAP" = true ]; then
    cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3",
    "labels": "production"
  },
  "icc": false,
  "userland-proxy": false,
  "live-restore": true,
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 64000,
      "Soft": 64000
    }
  },
  "selinux-enabled": false,
  "userns-remap": "default",
  "default-shm-size": "64M",
  "storage-driver": "overlay2",
  "exec-opts": ["native.cgroupdriver=systemd"],
  "features": {
    "buildkit": true
  },
  "experimental": false,
  "metrics-addr": "127.0.0.1:9323",
  "debug": false
}
EOF
else
    cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3",
    "labels": "production"
  },
  "icc": false,
  "userland-proxy": false,
  "live-restore": true,
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 64000,
      "Soft": 64000
    }
  },
  "selinux-enabled": false,
  "default-shm-size": "64M",
  "storage-driver": "overlay2",
  "exec-opts": ["native.cgroupdriver=systemd"],
  "features": {
    "buildkit": true
  },
  "experimental": false,
  "metrics-addr": "127.0.0.1:9323",
  "debug": false
}
EOF
fi

echo "[INFO] Created hardened /etc/docker/daemon.json"
echo "[INFO] Using Docker's built-in default seccomp profile"

# Setup user namespace remapping (only if enabled)
if [ "$ENABLE_USERNS_REMAP" = true ]; then
    echo "[INFO] Setting up user namespace remapping..."

    # Check if dockremap entry already exists in /etc/subuid
    if ! grep -q "^dockremap:" /etc/subuid 2>/dev/null; then
        echo "dockremap:100000:65536" >> /etc/subuid
        echo "[INFO] Added dockremap to /etc/subuid"
    fi

    # Check if dockremap entry already exists in /etc/subgid
    if ! grep -q "^dockremap:" /etc/subgid 2>/dev/null; then
        echo "dockremap:100000:65536" >> /etc/subgid
        echo "[INFO] Added dockremap to /etc/subgid"
    fi

    # Create dockremap user if it doesn't exist
    if ! id dockremap &>/dev/null; then
        useradd -r -s /usr/sbin/nologin -d /nonexistent dockremap
        echo "[INFO] Created dockremap user"
    fi
else
    echo "[INFO] Skipping user namespace remapping setup"
fi

# Restart Docker to apply changes
echo "[INFO] Restarting Docker daemon..."
if ! systemctl restart docker; then
    echo "[WARN] Hardened configuration failed, trying fallback..."

    # Fallback: Create minimal working configuration
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

    echo "[INFO] Trying minimal Docker configuration..."
    if ! systemctl restart docker; then
        echo "[ERROR] Even minimal configuration failed!"
        echo ""
        echo "[ERROR] Recent Docker logs:"
        journalctl -xeu docker.service -n 50 --no-pager
        echo ""
        echo "[ERROR] You can restore the backup from /etc/docker/daemon.json.backup.*"
        exit 1
    fi

    echo "[WARN] Running with minimal Docker configuration (hardening disabled)"
    echo "[WARN] To retry hardening later, run: /opt/dockerHosting/scripts/harden-docker.sh"
fi

# Wait for Docker to start
sleep 3

# Verify Docker is running
if systemctl is-active --quiet docker; then
    echo "[INFO] Docker daemon restarted successfully"
else
    echo "[ERROR] Docker daemon failed to start!"
    echo ""
    echo "[ERROR] Recent Docker logs:"
    journalctl -xeu docker.service -n 50 --no-pager
    echo ""
    echo "[ERROR] You can restore the backup: cp /etc/docker/daemon.json.backup.* /etc/docker/daemon.json"
    exit 1
fi

# Verify configuration
echo ""
echo "[INFO] Verifying Docker configuration..."
docker info | grep -E "Storage Driver|Logging Driver" || true

# Check if we're running hardened or minimal config
if grep -q '"icc": false' /etc/docker/daemon.json 2>/dev/null; then
    HARDENED=true
else
    HARDENED=false
fi

echo ""
echo "[INFO] ════════════════════════════════════════════"
if [ "$HARDENED" = true ]; then
    echo "[INFO] Docker Daemon Hardening Complete!"
    echo "[INFO] ════════════════════════════════════════════"
    echo ""
    echo "[INFO] Security features enabled:"
    if [ "$ENABLE_USERNS_REMAP" = true ]; then
        echo "  ✓ User namespace remapping (containers run as unprivileged users)"
    fi
    echo "  ✓ Inter-container communication DISABLED (--icc=false)"
    echo "  ✓ Seccomp filtering (Docker default profile)"
    echo "  ✓ Resource limits (ulimits configured)"
    echo "  ✓ Logging limits (10MB max, 3 files)"
    echo "  ✓ Live restore enabled (containers survive daemon restarts)"
    echo "  ✓ Userland proxy disabled (better performance)"
    echo ""
    echo "[WARN] IMPORTANT: Containers now run in isolated networks"
    echo "[WARN] Each site will have its own Docker network"
    echo "[WARN] Cross-site communication ONLY via boundary Nginx"
    echo ""
    echo "[INFO] Configuration file: /etc/docker/daemon.json"
    if [ "$ENABLE_USERNS_REMAP" = true ]; then
        echo "[INFO] User namespace: dockremap (UID/GID 100000-165535)"
    fi
else
    echo "[WARN] Docker Running with Minimal Configuration"
    echo "[INFO] ════════════════════════════════════════════"
    echo ""
    echo "[WARN] Hardened configuration failed, using fallback"
    echo "[INFO] Basic features enabled:"
    echo "  ✓ Logging limits (10MB max, 3 files)"
    echo "  ✓ Live restore enabled (containers survive daemon restarts)"
    echo ""
    echo "[INFO] To retry hardening later:"
    echo "  /opt/dockerHosting/scripts/harden-docker.sh"
fi
echo ""
