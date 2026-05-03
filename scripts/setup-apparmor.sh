#!/bin/bash
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#############################################
# AppArmor Setup
#
# Enables AppArmor MAC (Mandatory Access Control) and loads the
# Docker default profile so every container gets a baseline
# confinement policy even if the compose file doesn't specify one.
#
# Based on: CIS Docker Benchmark 2.8, CIS Linux Level 2
#############################################

set -euo pipefail

echo "[INFO] Configuring AppArmor mandatory access control..."

FORCE=false
for arg in "$@"; do [[ "$arg" == "--force" ]] && FORCE=true; done

if [[ "$FORCE" == false ]] && command -v aa-status &>/dev/null && aa-status --enabled 2>/dev/null; then
    echo "[INFO] AppArmor already enabled — skipping (use --force to reconfigure)"
    aa-status --summary 2>/dev/null || true
    exit 0
fi

# Install apparmor tooling
echo "[INFO] Installing AppArmor packages..."
apt-get install -y apparmor apparmor-utils apparmor-profiles apparmor-profiles-extra

# Ensure AppArmor is enabled in the kernel
if ! grep -q "apparmor=1" /proc/cmdline 2>/dev/null && ! grep -q "security=apparmor" /proc/cmdline 2>/dev/null; then
    echo "[INFO] AppArmor not enabled on current kernel cmdline — adding GRUB parameters..."

    GRUB_FILE=/etc/default/grub
    if [[ -f "$GRUB_FILE" ]]; then
        if ! grep -q "apparmor=1" "$GRUB_FILE"; then
            # Append to existing GRUB_CMDLINE_LINUX
            sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 apparmor=1 security=apparmor"/' "$GRUB_FILE"
            echo "[INFO] Updated GRUB_CMDLINE_LINUX in $GRUB_FILE"
            update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
            echo "[WARN] A REBOOT is required for AppArmor kernel parameters to take effect"
        fi
    else
        echo "[WARN] /etc/default/grub not found — AppArmor kernel parameters must be added manually"
    fi
else
    echo "[INFO] AppArmor kernel parameters already set"
fi

# If AppArmor is active now (was already in cmdline from last boot), load profiles
if aa-status --enabled 2>/dev/null; then
    echo "[INFO] AppArmor is active — loading profiles..."

    # Load Docker-specific AppArmor profile if present (installed by docker-ce)
    if [[ -f /etc/apparmor.d/docker ]]; then
        apparmor_parser -r /etc/apparmor.d/docker 2>/dev/null \
            && echo "[INFO] Loaded /etc/apparmor.d/docker" \
            || echo "[WARN] Could not load /etc/apparmor.d/docker"
    fi

    # Load any extra profiles from apparmor-profiles-extra that are in complain mode
    for profile in /etc/apparmor.d/usr.sbin.* /etc/apparmor.d/usr.bin.*; do
        [[ -f "$profile" ]] || continue
        apparmor_parser -r "$profile" 2>/dev/null \
            && echo "[INFO] Loaded $(basename "$profile")" \
            || true
    done

    echo ""
    echo "[INFO] AppArmor status:"
    aa-status --summary 2>/dev/null || aa-status 2>/dev/null | tail -5 || true
else
    echo "[WARN] AppArmor not active on running kernel — profiles will load after reboot"
fi

# Write a note about the Docker default profile for daemon.json
# Docker uses the 'docker-default' profile automatically when AppArmor is active.
# No daemon.json change is needed — Docker detects AppArmor and applies the profile.
echo ""
echo "[INFO] ════════════════════════════════════════════"
echo "[INFO] AppArmor Setup Complete!"
echo "[INFO] ════════════════════════════════════════════"
echo ""
echo "[INFO] Configuration summary:"
echo "  - AppArmor packages:   apparmor + apparmor-utils + profiles"
echo "  - Docker containers:   automatically confined by 'docker-default' profile"
echo "  - Custom profiles:     /etc/apparmor.d/"
if grep -q "apparmor=1" /proc/cmdline 2>/dev/null; then
    echo "  - Status:             ACTIVE"
else
    echo "  - Status:             PENDING REBOOT (kernel parameter added to GRUB)"
fi
echo ""
echo "[INFO] Useful commands:"
echo "  - Current status:      aa-status"
echo "  - Enforce a profile:   aa-enforce /etc/apparmor.d/<profile>"
echo "  - Complain mode:       aa-complain /etc/apparmor.d/<profile>"
echo "  - Generate profile:    aa-genprof <binary>"
echo ""
