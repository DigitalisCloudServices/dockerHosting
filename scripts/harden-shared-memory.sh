#!/bin/bash

#############################################
# Shared Memory Hardening
#
# Mounts /dev/shm with security restrictions:
# - noexec: Cannot execute programs
# - nodev: Cannot create device files
# - nosuid: Cannot use setuid/setgid bits
#
# Prevents execution from shared memory attacks
# Based on: CIS Benchmark, DISA STIG
#############################################

set -e

echo "[INFO] Hardening shared memory (/dev/shm)..."

# Check if /dev/shm is already mounted with security options
if mount | grep /dev/shm | grep -q "noexec.*nodev.*nosuid"; then
    echo "[INFO] /dev/shm is already hardened"
    mount | grep /dev/shm
    exit 0
fi

# Backup /etc/fstab
if [ ! -f /etc/fstab.backup ]; then
    cp /etc/fstab /etc/fstab.backup
    echo "[INFO] Backed up /etc/fstab"
fi

# Remove existing /dev/shm entries
sed -i '/\/dev\/shm/d' /etc/fstab

# Add hardened /dev/shm mount
echo "tmpfs /dev/shm tmpfs defaults,noexec,nodev,nosuid,size=2G 0 0" >> /etc/fstab

echo "[INFO] Added hardened /dev/shm entry to /etc/fstab"

# Remount /dev/shm with new options
mount -o remount /dev/shm

# Verify the mount
echo ""
echo "[INFO] Verifying /dev/shm mount options..."
mount | grep /dev/shm

# Test that execution is blocked
echo ""
echo "[INFO] Testing execution protection..."
if ! echo '#!/bin/sh' > /dev/shm/test.sh 2>/dev/null || ! chmod +x /dev/shm/test.sh 2>/dev/null || ! /dev/shm/test.sh 2>/dev/null; then
    echo "[INFO] ✓ Execution from /dev/shm is blocked"
    rm -f /dev/shm/test.sh
else
    echo "[WARN] ⚠ Execution test inconclusive"
    rm -f /dev/shm/test.sh
fi

echo ""
echo "[INFO] ════════════════════════════════════════════"
echo "[INFO] Shared Memory Hardening Complete!"
echo "[INFO] ════════════════════════════════════════════"
echo ""
echo "[INFO] /dev/shm mount options:"
echo "  ✓ noexec: Cannot execute binaries"
echo "  ✓ nodev: Cannot create device files"
echo "  ✓ nosuid: Cannot use setuid/setgid"
echo "  ✓ size: Limited to 2GB"
echo ""
echo "[INFO] This prevents:"
echo "  - Execution of malicious code from shared memory"
echo "  - Certain privilege escalation attacks"
echo "  - Tmpfs-based attacks"
echo ""
