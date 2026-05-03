#!/bin/bash
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#############################################
# GRUB Bootloader Hardening
#
# Sets a GRUB superuser password to prevent an attacker with physical
# (or console) access from booting into single-user/rescue mode and
# bypassing filesystem-level access controls.
#
# IMPORTANT:
#   - You MUST remember this password. Recovery requires a rescue disk.
#   - This only protects against console-level tampering. Disk encryption
#     (LUKS) is the stronger control for data-at-rest — add it separately.
#
# Based on: CIS Benchmark 1.4.1 (GRUB password), 1.4.2 (single-user auth)
#############################################

set -euo pipefail

GRUB_CONF=/etc/grub.d/40_custom
GRUB_DEFAULT=/etc/default/grub

echo "[INFO] Hardening GRUB bootloader..."

FORCE=false
for arg in "$@"; do [[ "$arg" == "--force" ]] && FORCE=true; done

if [[ "$FORCE" == false ]] && grep -q "set superusers" "$GRUB_CONF" 2>/dev/null; then
    echo "[INFO] GRUB superuser already configured — skipping (use --force to reconfigure)"
    exit 0
fi

# Verify GRUB is installed
if ! command -v grub-mkconfig &>/dev/null && ! command -v grub2-mkconfig &>/dev/null; then
    echo "[WARN] grub-mkconfig not found — GRUB may not be the bootloader on this system"
    echo "[WARN] Skipping bootloader hardening"
    exit 0
fi

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  GRUB BOOTLOADER HARDENING"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "  This will set a GRUB superuser password to block single-user"
echo "  mode bypass. YOU MUST REMEMBER THIS PASSWORD — recovery"
echo "  without it requires a rescue/live disk."
echo ""
echo "  The normal boot entry will still start automatically without"
echo "  prompting for the GRUB password (only editing/recovery menus"
echo "  require it)."
echo ""
read -rp "Continue? (type 'yes' to proceed) " confirm
echo
if [[ "$confirm" != "yes" ]]; then
    echo "[INFO] Bootloader hardening aborted — no changes made"
    exit 0
fi

# Prompt for GRUB password
echo "[INFO] Enter the GRUB superuser password (shown as asterisks):"
GRUB_PASS=""
while [[ -z "$GRUB_PASS" ]]; do
    read -rsp "Password: " GRUB_PASS; echo
    read -rsp "Confirm:  " GRUB_PASS2; echo
    if [[ "$GRUB_PASS" != "$GRUB_PASS2" ]]; then
        echo "[WARN] Passwords do not match — try again"
        GRUB_PASS=""
    elif [[ ${#GRUB_PASS} -lt 12 ]]; then
        echo "[WARN] Password must be at least 12 characters — try again"
        GRUB_PASS=""
    fi
done

# Hash the password using grub-mkpasswd-pbkdf2
echo "[INFO] Generating PBKDF2 password hash..."
GRUB_HASH=$(echo -e "${GRUB_PASS}\n${GRUB_PASS}" | grub-mkpasswd-pbkdf2 2>/dev/null \
    | grep "grub.pbkdf2" | awk '{print $NF}')

if [[ -z "$GRUB_HASH" ]]; then
    echo "[ERROR] Failed to generate GRUB password hash"
    exit 1
fi

# Backup 40_custom
cp "$GRUB_CONF" "${GRUB_CONF}.backup.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

# Append superuser block to 40_custom (idempotent via guard above)
cat >> "$GRUB_CONF" <<EOF

# GRUB Superuser — added by dockerHosting security hardening
# Prevents single-user/rescue mode bypass (CIS 1.4.1)
set superusers="root"
password_pbkdf2 root ${GRUB_HASH}
EOF

echo "[INFO] Added GRUB superuser block to $GRUB_CONF"

# Mark the default menu entry as unrestricted so it boots without prompting
# (--unrestricted is added to the generated entry in /etc/grub.d/10_linux)
if ! grep -q "GRUB_DISABLE_SUBMENU" "$GRUB_DEFAULT" 2>/dev/null; then
    echo 'GRUB_DISABLE_SUBMENU=y' >> "$GRUB_DEFAULT"
fi

# Patch 10_linux to add --unrestricted to the default entry class line
LINUX_SCRIPT=/etc/grub.d/10_linux
if [[ -f "$LINUX_SCRIPT" ]] && ! grep -q "\-\-unrestricted" "$LINUX_SCRIPT"; then
    # Insert --unrestricted into the menuentry class so normal boot is passwordless
    sed -i 's/menuentry \(.*\) {$/menuentry \1 --unrestricted {/' "$LINUX_SCRIPT" 2>/dev/null || \
    echo "[WARN] Could not auto-patch 10_linux — normal boot entries may prompt for password"
fi

# Regenerate GRUB config
echo "[INFO] Regenerating GRUB configuration..."
if command -v grub-mkconfig &>/dev/null; then
    grub-mkconfig -o /boot/grub/grub.cfg
elif command -v grub2-mkconfig &>/dev/null; then
    grub2-mkconfig -o /boot/grub2/grub.cfg
fi

echo ""
echo "[INFO] ════════════════════════════════════════════"
echo "[INFO] GRUB Bootloader Hardening Complete!"
echo "[INFO] ════════════════════════════════════════════"
echo ""
echo "[INFO] Summary:"
echo "  - Normal boot:       passwordless (--unrestricted)"
echo "  - GRUB edit/rescue:  requires GRUB superuser password"
echo "  - Password hash:     PBKDF2-SHA512"
echo ""
echo "[WARN] CRITICAL: Store the GRUB password securely (e.g. password manager)."
echo "[WARN] Loss of this password requires a rescue disk to recover boot access."
echo ""
