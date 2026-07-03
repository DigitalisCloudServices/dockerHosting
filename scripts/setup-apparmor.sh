#!/bin/bash
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#############################################
# AppArmor Setup
#
# Enables AppArmor MAC (Mandatory Access Control) and loads the
# Docker default profile so every container gets a baseline
# confinement policy even if the compose file doesn't specify one.
#
# Custom AppArmor profiles (under templates/apparmor.d/) are also synced
# into /etc/apparmor.d/ and reloaded.  This section ALWAYS runs — even on
# hosts where AppArmor is already enabled and the rest of setup short-
# circuits — so that re-running setup.sh picks up profiles added since
# the host's last run.  See sync_custom_profiles() below.
#
#   Add a new profile        → drop the file under templates/apparmor.d/
#                              and re-run setup.sh on every host
#   Modify a profile         → edit templates/apparmor.d/<name>,
#                              re-run setup.sh; sync detects the diff
#                              and reloads via apparmor_parser -r
#   Reference from compose   → security_opt: [ "apparmor:<name>" ]
#
# Persistence across reboots: apparmor.service (provided by the apparmor
# package) auto-loads everything under /etc/apparmor.d/ at boot, so once
# a profile file is installed there it survives kernel restarts.
#
# Based on: CIS Docker Benchmark 2.8, CIS Linux Level 2
#############################################

set -euo pipefail

echo "[INFO] Configuring AppArmor mandatory access control..."

FORCE=false
for arg in "$@"; do
    [[ "$arg" == "--force" ]] && FORCE=true
done

DOCKERHOSTING_DIR="${DOCKERHOSTING_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

# Sync custom dockerHosting AppArmor profiles from templates/apparmor.d/ into
# /etc/apparmor.d/.  Always runs (even when the early-return below short-circuits
# the rest of setup), so a host re-running setup.sh picks up new profiles that
# were added since its last run.  Idempotent: only writes when the source differs.
#
# Profiles are required by certain container workloads (e.g. the VelaAir web
# container's velaair-fuse profile permits fuse.* mount(2) at /app/tiles for the
# gcsfuse-backed tile layer, which the default docker-default profile denies).
sync_custom_profiles() {
    [[ -d "$DOCKERHOSTING_DIR/templates/apparmor.d" ]] || return 0

    local src dst
    local installed=0
    for src in "$DOCKERHOSTING_DIR"/templates/apparmor.d/*; do
        [[ -f "$src" ]] || continue
        dst="/etc/apparmor.d/$(basename "$src")"
        if [[ ! -f "$dst" ]] || ! cmp -s "$src" "$dst"; then
            install -m 0644 -o root -g root "$src" "$dst"
            echo "[INFO] Installed custom AppArmor profile: $(basename "$dst")"
            installed=$((installed + 1))
        fi
    done

    # Reload installed profiles if AppArmor is active on the running kernel.
    # Otherwise the kernel will load them automatically at next boot via
    # apparmor.service reading /etc/apparmor.d/.
    if command -v aa-status &> /dev/null && aa-status --enabled 2> /dev/null; then
        for src in "$DOCKERHOSTING_DIR"/templates/apparmor.d/*; do
            [[ -f "$src" ]] || continue
            dst="/etc/apparmor.d/$(basename "$src")"
            if apparmor_parser -r "$dst" 2> /dev/null; then
                echo "[INFO] Loaded $(basename "$dst")"
            else
                echo "[WARN] Could not load $(basename "$dst") — check syntax with: apparmor_parser -d $dst"
            fi
        done
    elif [[ $installed -gt 0 ]]; then
        echo "[INFO] AppArmor not active yet — installed profiles will load at next reboot"
    fi
}

sync_custom_profiles

if [[ "$FORCE" == false ]] && command -v aa-status &> /dev/null && aa-status --enabled 2> /dev/null; then
    echo "[INFO] AppArmor already enabled — skipping host-level setup (use --force to reconfigure)"
    echo "[INFO] Custom profiles were synced above.  Run with --force to also rerun GRUB / package setup."
    aa-status --summary 2> /dev/null || true
    exit 0
fi

# Install apparmor tooling
echo "[INFO] Installing AppArmor packages..."
apt-get install -y apparmor apparmor-utils apparmor-profiles apparmor-profiles-extra

# Ensure AppArmor is enabled in the kernel
if ! grep -q "apparmor=1" /proc/cmdline 2> /dev/null && ! grep -q "security=apparmor" /proc/cmdline 2> /dev/null; then
    echo "[INFO] AppArmor not enabled on current kernel cmdline — adding GRUB parameters..."

    GRUB_FILE=/etc/default/grub
    if [[ -f "$GRUB_FILE" ]]; then
        if ! grep -q "apparmor=1" "$GRUB_FILE"; then
            # Append to existing GRUB_CMDLINE_LINUX
            sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 apparmor=1 security=apparmor"/' "$GRUB_FILE"
            echo "[INFO] Updated GRUB_CMDLINE_LINUX in $GRUB_FILE"
            update-grub 2> /dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2> /dev/null || true
            echo "[WARN] A REBOOT is required for AppArmor kernel parameters to take effect"
        fi
    else
        echo "[WARN] /etc/default/grub not found — AppArmor kernel parameters must be added manually"
    fi
else
    echo "[INFO] AppArmor kernel parameters already set"
fi

# If AppArmor is active now (was already in cmdline from last boot), load profiles.
# Custom dockerHosting profiles were already synced + reloaded earlier by
# sync_custom_profiles() — this block handles the docker-default + apparmor-profiles-extra
# load that goes with the freshly-installed packages.
if aa-status --enabled 2> /dev/null; then
    echo "[INFO] AppArmor is active — loading docker + extra profiles..."

    # Load Docker-specific AppArmor profile if present (installed by docker-ce)
    if [[ -f /etc/apparmor.d/docker ]]; then
        apparmor_parser -r /etc/apparmor.d/docker 2> /dev/null &&
            echo "[INFO] Loaded /etc/apparmor.d/docker" ||
            echo "[WARN] Could not load /etc/apparmor.d/docker"
    fi

    # Load any extra profiles from apparmor-profiles-extra that are in complain mode
    for profile in /etc/apparmor.d/usr.sbin.* /etc/apparmor.d/usr.bin.*; do
        [[ -f "$profile" ]] || continue
        apparmor_parser -r "$profile" 2> /dev/null &&
            echo "[INFO] Loaded $(basename "$profile")" ||
            true
    done

    echo ""
    echo "[INFO] AppArmor status:"
    aa-status --summary 2> /dev/null || aa-status 2> /dev/null | tail -5 || true
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
if grep -q "apparmor=1" /proc/cmdline 2> /dev/null; then
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
