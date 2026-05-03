#!/bin/bash

#############################################
# dockerHosting - Server Setup Script
#
# Purpose: Bootstrap a fresh Debian Trixie server
# - Installs basic system packages
# - Clones dockerHosting repository
# - Runs full setup from repository scripts
#############################################

set -e  # Exit on error

# Ensure sbin directories are in PATH (may be missing when invoked via sudo/curl|bash)
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Auto-elevate to root if not already running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script requires root privileges. Re-running with sudo..."
    exec sudo "$0" "$@"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
DOCKERHOSTING_REPO="https://github.com/DigitalisCloudServices/dockerHosting.git"
DOCKERHOSTING_DIR="/opt/dockerHosting"

# Log functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi
}

# Display banner
display_banner() {
    echo ""
    echo "╔═══════════════════════════════════════════════╗"
    echo "║   dockerHosting - Server Setup                ║"
    echo "║   Debian Trixie Server Configuration          ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo ""
}

# Check OS version
check_os() {
    log_info "Checking OS version..."

    if [ ! -f /etc/os-release ]; then
        log_error "Cannot detect OS version"
        exit 1
    fi

    . /etc/os-release

    if [ "$ID" != "debian" ]; then
        log_warn "This script is designed for Debian. Detected: $ID"
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    log_info "OS: $PRETTY_NAME"
}

# Install basic packages needed to clone repo
install_basic_packages() {
    log_info "Installing basic system packages..."

    apt-get update
    apt-get upgrade -y
    apt-get install -y sudo curl git wget ca-certificates gnupg lsb-release apt-transport-https

    log_info "Basic packages installed"
}

# Prompt to add a user to the sudo group
setup_sudo_user() {
    echo ""
    log_info "sudo is installed. You can grant an existing user sudo privileges now."

    local available_users
    available_users=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd)

    if [ -n "$available_users" ]; then
        log_info "Available users (UID 1000–65533):"
        echo "$available_users" | while read -r u; do echo "  - $u"; done
    fi

    echo ""
    read -p "Add a user to the sudo group? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Skipping sudo user setup"
        return 0
    fi

    local username
    while true; do
        read -rp "Enter username to add to sudo group: " username
        if [ -z "$username" ]; then
            log_warn "Username cannot be empty. Try again."
            continue
        fi
        if ! id "$username" &>/dev/null; then
            log_warn "User '$username' does not exist. Try again."
            continue
        fi
        break
    done

    usermod -aG sudo "$username"
    log_info "User '$username' added to the sudo group"
    log_warn "They will need to log out and back in for the change to take effect"
}

# Log the current branch and commit hash of the repository
log_repo_version() {
    local hash branch
    hash=$(git -C "$DOCKERHOSTING_DIR" rev-parse --short HEAD 2>/dev/null)
    branch=$(git -C "$DOCKERHOSTING_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
    log_info "Repository version: ${branch} @ ${hash}"
}

# Clone dockerHosting repository
clone_repository() {
    log_info "Cloning dockerHosting repository..."

    if [ -d "$DOCKERHOSTING_DIR" ]; then
        log_warn "Directory $DOCKERHOSTING_DIR already exists"

        # Check if it's a git repository
        if [ -d "$DOCKERHOSTING_DIR/.git" ]; then
            read -p "Update existing repository? (Y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                log_info "Updating repository..."
                cd "$DOCKERHOSTING_DIR"
                if git pull; then
                    log_info "Repository updated successfully"
                    log_repo_version
                    return 0
                else
                    log_error "Failed to update repository"
                    exit 1
                fi
            else
                log_info "Using existing directory without updating"
                log_repo_version
                return 0
            fi
        else
            # Not a git repo, offer to remove and re-clone
            read -p "Remove and re-clone? (y/N) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                rm -rf "$DOCKERHOSTING_DIR"
            else
                log_info "Using existing directory"
                return 0
            fi
        fi
    fi

    if git clone "$DOCKERHOSTING_REPO" "$DOCKERHOSTING_DIR"; then
        log_info "Repository cloned successfully to $DOCKERHOSTING_DIR"
        log_repo_version
    else
        log_error "Failed to clone repository"
        exit 1
    fi
}

# Check that sudo users have SSH keys before locking down password auth.
# Returns 1 (skip hardening) if the user declines to proceed.
confirm_ssh_keys_before_hardening() {
    echo ""
    log_warn "══════════════════════════════════════════════════════"
    log_warn "  SSH HARDENING — PASSWORD AUTH WILL BE DISABLED"
    log_warn "══════════════════════════════════════════════════════"
    echo ""
    log_warn "After this step, SSH key authentication is the ONLY way in."
    log_warn "If no key is configured for your sudo user you will be locked out."
    echo ""

    # Collect users in the sudo group
    local sudo_users=()
    while IFS= read -r u; do
        sudo_users+=("$u")
    done < <(getent group sudo 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep -v '^$' || true)

    if [ ${#sudo_users[@]} -eq 0 ]; then
        log_warn "No users found in the sudo group."
        log_warn "You should add a sudo user before disabling password auth!"
    else
        log_info "Users in the sudo group and their SSH key status:"
        for u in "${sudo_users[@]}"; do
            local home_dir
            home_dir=$(getent passwd "$u" | cut -d: -f6)
            local auth_keys="$home_dir/.ssh/authorized_keys"
            if [ -f "$auth_keys" ] && grep -qE '^(ssh-|ecdsa-|sk-)' "$auth_keys" 2>/dev/null; then
                local key_count
                key_count=$(grep -cE '^(ssh-|ecdsa-|sk-)' "$auth_keys")
                echo -e "  ${GREEN}✓${NC} $u — $key_count key(s) in $auth_keys"
            else
                echo -e "  ${RED}✗${NC} $u — NO authorized_keys found at $auth_keys"
            fi
        done
    fi

    echo ""
    log_warn "Have you confirmed SSH key access works in a SEPARATE terminal? (type 'yes' to proceed)"
    read -rp "> " confirm
    echo
    if [ "$confirm" != "yes" ]; then
        log_warn "SSH hardening skipped — answer must be exactly 'yes'"
        return 1
    fi
    return 0
}

# Run full setup from repository
# Usage: run_full_setup [--force[=step1,step2,...]]
#   --force            force-run every step even if already configured
#   --force=docker     force only the named step(s); comma-separated
#   Valid step names: packages, docker, traefik, firewall, kernel, audit,
#                     auto-updates, harden-docker, pam, aide, shm, fail2ban,
#                     email, ntp, apparmor, ssh, mfa, bootloader, logrotate
run_full_setup() {
    log_info "Running full setup from repository scripts..."
    echo ""

    # Parse --force / --force=steps
    local FORCE_ALL=false
    local FORCE_STEPS=""
    for arg in "$@"; do
        case "$arg" in
            --force)          FORCE_ALL=true ;;
            --force=*)        FORCE_STEPS="${arg#*=}" ;;
        esac
    done

    # Returns true if a given step name should be forced
    _step_forced() {
        local step="$1"
        [[ "$FORCE_ALL" == true ]] && return 0
        [[ -n "$FORCE_STEPS" ]] && echo "$FORCE_STEPS" | grep -qE "(^|,)${step}(,|$)" && return 0
        return 1
    }

    # Builds the --force flag string for a subscript if the step is forced
    _flag() {
        local step="$1"
        _step_forced "$step" && echo "--force" || echo ""
    }

    cd "$DOCKERHOSTING_DIR"

    # Install packages from repository config
    if [ -f "$DOCKERHOSTING_DIR/scripts/install-packages.sh" ]; then
        log_info "Installing additional packages..."
        # shellcheck disable=SC2046
        bash "$DOCKERHOSTING_DIR/scripts/install-packages.sh" $(_flag packages)
    fi

    # Install Docker
    if [ -f "$DOCKERHOSTING_DIR/scripts/install-docker.sh" ]; then
        log_info "Installing Docker..."
        # shellcheck disable=SC2046
        bash "$DOCKERHOSTING_DIR/scripts/install-docker.sh" $(_flag docker)
    fi

    # Install Traefik as boundary proxy
    if [ -f "$DOCKERHOSTING_DIR/scripts/install-traefik.sh" ]; then
        log_info "Installing Traefik boundary proxy..."
        # shellcheck disable=SC2046
        bash "$DOCKERHOSTING_DIR/scripts/install-traefik.sh" $(_flag traefik)
    fi

    # Configure firewall
    if [ -f "$DOCKERHOSTING_DIR/scripts/configure-firewall.sh" ]; then
        log_info "Configuring firewall..."
        # shellcheck disable=SC2046
        bash "$DOCKERHOSTING_DIR/scripts/configure-firewall.sh" $(_flag firewall)
    fi

    # Harden kernel parameters
    if [ -f "$DOCKERHOSTING_DIR/scripts/harden-kernel.sh" ]; then
        log_info "Hardening kernel parameters..."
        # shellcheck disable=SC2046
        bash "$DOCKERHOSTING_DIR/scripts/harden-kernel.sh" $(_flag kernel)
    fi

    # Configure NTP time synchronisation (chrony)
    if [ -f "$DOCKERHOSTING_DIR/scripts/setup-ntp.sh" ]; then
        log_info "Configuring NTP time synchronisation..."
        # shellcheck disable=SC2046
        bash "$DOCKERHOSTING_DIR/scripts/setup-ntp.sh" $(_flag ntp)
    fi

    # Setup audit logging
    if [ -f "$DOCKERHOSTING_DIR/scripts/setup-audit.sh" ]; then
        log_info "Setting up audit logging..."
        # shellcheck disable=SC2046
        bash "$DOCKERHOSTING_DIR/scripts/setup-audit.sh" $(_flag audit)
    fi

    # Configure automated security updates
    if [ -f "$DOCKERHOSTING_DIR/scripts/setup-auto-updates.sh" ]; then
        log_info "Configuring automated security updates..."
        # shellcheck disable=SC2046
        bash "$DOCKERHOSTING_DIR/scripts/setup-auto-updates.sh" $(_flag auto-updates)
    fi

    # Harden Docker daemon
    if [ -f "$DOCKERHOSTING_DIR/scripts/harden-docker.sh" ]; then
        log_info "Hardening Docker daemon..."
        # shellcheck disable=SC2046
        bash "$DOCKERHOSTING_DIR/scripts/harden-docker.sh" $(_flag harden-docker)
    fi

    # Enable AppArmor mandatory access control
    if [ -f "$DOCKERHOSTING_DIR/scripts/setup-apparmor.sh" ]; then
        log_info "Enabling AppArmor mandatory access control..."
        # shellcheck disable=SC2046
        bash "$DOCKERHOSTING_DIR/scripts/setup-apparmor.sh" $(_flag apparmor)
    fi

    # Configure PAM password policy
    if [ -f "$DOCKERHOSTING_DIR/scripts/setup-pam-policy.sh" ]; then
        log_info "Configuring password policy..."
        # shellcheck disable=SC2046
        bash "$DOCKERHOSTING_DIR/scripts/setup-pam-policy.sh" $(_flag pam)
    fi

    # Setup AIDE file integrity monitoring
    if [ -f "$DOCKERHOSTING_DIR/scripts/setup-aide.sh" ]; then
        log_info "Setting up file integrity monitoring..."
        # shellcheck disable=SC2046
        bash "$DOCKERHOSTING_DIR/scripts/setup-aide.sh" $(_flag aide)
    fi

    # Harden shared memory
    if [ -f "$DOCKERHOSTING_DIR/scripts/harden-shared-memory.sh" ]; then
        log_info "Hardening shared memory..."
        # shellcheck disable=SC2046
        bash "$DOCKERHOSTING_DIR/scripts/harden-shared-memory.sh" $(_flag shm)
    fi

    # Enhanced fail2ban configuration
    if [ -f "$DOCKERHOSTING_DIR/scripts/setup-fail2ban-enhanced.sh" ]; then
        log_info "Configuring enhanced fail2ban protection..."
        # shellcheck disable=SC2046
        bash "$DOCKERHOSTING_DIR/scripts/setup-fail2ban-enhanced.sh" $(_flag fail2ban)
    fi

    # Setup email notifications (optional)
    if [ -f "$DOCKERHOSTING_DIR/scripts/setup-email.sh" ]; then
        echo ""
        log_warn "Email notifications allow the system to send alerts, security notifications, and cron output."
        read -p "Configure email notifications? (y/N) " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # shellcheck disable=SC2046
            bash "$DOCKERHOSTING_DIR/scripts/setup-email.sh" $(_flag email)
        else
            log_info "Skipping email configuration"
        fi
    fi

    # Optional: GRUB bootloader password (prevents single-user-mode bypass)
    if [ -f "$DOCKERHOSTING_DIR/scripts/harden-bootloader.sh" ]; then
        echo ""
        log_warn "GRUB bootloader hardening prevents console/single-user-mode bypass (CIS 1.4)."
        log_warn "Requires remembering a GRUB password — recovery without it needs a rescue disk."
        read -p "Harden GRUB bootloader? (y/N) " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # shellcheck disable=SC2046
            bash "$DOCKERHOSTING_DIR/scripts/harden-bootloader.sh" $(_flag bootloader)
        else
            log_info "Skipping bootloader hardening"
        fi
    fi

    # Optional: USB / removable media hardening
    if [ -f "$DOCKERHOSTING_DIR/scripts/harden-usb.sh" ]; then
        echo ""
        log_warn "USB hardening blacklists usb-storage, FireWire, and Thunderbolt kernel modules (CIS L2)."
        log_warn "Safe to enable on VMs. On bare-metal, confirm USB input devices are not the only keyboard/mouse."
        log_warn "A reboot is required for the blacklist to take full effect."
        read -p "Apply USB/removable media hardening? (y/N) " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # shellcheck disable=SC2046
            bash "$DOCKERHOSTING_DIR/scripts/harden-usb.sh" $(_flag usb)
        else
            log_info "Skipping USB hardening — can be enabled later: scripts/harden-usb.sh"
        fi
    fi

    # Ensure a sudo user exists with SSH keys before locking down password auth
    setup_sudo_user

    # Harden SSH (do this last as it may affect connectivity)
    if [ -f "$DOCKERHOSTING_DIR/scripts/harden-ssh.sh" ]; then
        if ! confirm_ssh_keys_before_hardening; then
            log_warn "Skipping SSH hardening — re-run with --force=ssh once keys are in place"
        else
            # shellcheck disable=SC2046
            bash "$DOCKERHOSTING_DIR/scripts/harden-ssh.sh" $(_flag ssh)
        fi
    fi

    # Optional: SSH MFA (TOTP second factor) — requires per-user enrolment
    if [ -f "$DOCKERHOSTING_DIR/scripts/setup-ssh-mfa.sh" ]; then
        echo ""
        log_warn "SSH MFA adds a TOTP second factor to every SSH login (ISO A.8.5)."
        log_warn "Each user must run 'google-authenticator' after setup or they will be locked out."
        read -p "Configure SSH MFA (TOTP)? (y/N) " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # shellcheck disable=SC2046
            bash "$DOCKERHOSTING_DIR/scripts/setup-ssh-mfa.sh" $(_flag mfa)
        else
            log_info "Skipping SSH MFA — can be enabled later: scripts/setup-ssh-mfa.sh"
        fi
    fi

    # Setup log rotation
    if [ -f "$DOCKERHOSTING_DIR/scripts/setup-logrotate.sh" ]; then
        log_info "Configuring log rotation..."
        bash "$DOCKERHOSTING_DIR/scripts/setup-logrotate.sh" "docker-system" "/var/lib/docker/containers"
    fi

    # Create standard directories
    log_info "Creating standard directories..."
    mkdir -p /opt/apps
    mkdir -p /var/log/docker-sites
}

# Main setup function
main() {
    display_banner
    check_root

    # --update: pull the repo and exit without running full setup
    for arg in "$@"; do
        if [[ "$arg" == "--update" ]]; then
            log_info "Update mode: pulling latest repository..."
            clone_repository
            log_info "Repository is up to date."
            exit 0
        fi
    done

    check_os

    log_info "Starting server setup..."
    echo ""

    # Step 1: Install basic packages
    install_basic_packages
    echo ""

    # Step 2: Clone repository
    clone_repository
    echo ""

    # Step 3: Run full setup from repository (forward --force / --force=steps)
    run_full_setup "$@"

    # Final messages
    echo ""
    log_info "════════════════════════════════════════════"
    log_info "Server setup completed successfully!"
    log_info "════════════════════════════════════════════"
    echo ""
    log_warn "IMPORTANT SECURITY NOTICE:"
    log_warn "  - SSH password authentication is now DISABLED (keys only)"
    log_warn "  - Root login via SSH is DISABLED"
    log_warn "  - Test SSH access in a NEW terminal before logging out!"
    echo ""
    log_info "Security features enabled:"
    echo "  ✓ Firewall (UFW) with default-deny inbound + egress filtering"
    echo "  ✓ Kernel hardening (ASLR, SYN cookies, anti-spoofing)"
    echo "  ✓ NTP time synchronisation (chrony)"
    echo "  ✓ AppArmor mandatory access control"
    echo "  ✓ Audit logging (auditd) for security events"
    echo "  ✓ Automated security updates (daily)"
    echo "  ✓ SSH hardening (key-only auth, rate limiting)"
    echo "  ✓ fail2ban protection (SSH brute-force prevention)"
    if docker ps --filter "name=^traefik$" --filter "status=running" --format "{{.Names}}" 2>/dev/null | grep -q "^traefik$"; then
        echo "  ✓ Traefik v3.6 reverse proxy (ports 80/443, dashboard on :8080 — BasicAuth protected)"
        if [ -f "/etc/traefik/dashboard-credentials" ]; then
            echo "    Dashboard credentials: /etc/traefik/dashboard-credentials"
        fi
    fi
    if [ -f "/etc/msmtprc" ]; then
        echo "  ✓ Email notifications configured"
    fi
    echo ""
    log_warn "REQUIRED: Log out and log back in to apply group changes"
    echo ""
    log_info "Next steps:"
    echo "  1. Test SSH access in a NEW terminal window first!"
    echo "  2. Log out and log back in"
    echo "  3. Deploy a site using dockerHosting:"
    echo "     cd $DOCKERHOSTING_DIR && sudo ./deploy-site.sh"
    echo ""
    log_info "Useful commands:"
    echo "  - Check Docker: docker --version"
    echo "  - Check Traefik: docker ps --filter name=traefik"
    echo "  - Traefik dashboard: http://<server-ip>:8080/dashboard/ (see /etc/traefik/dashboard-credentials)"
    echo "  - Check firewall: sudo ufw status"
    echo "  - Check NTP sync: chronyc tracking"
    echo "  - Check AppArmor: sudo aa-status --summary"
    echo "  - Check audit logs: sudo ausearch -ts recent"
    echo "  - Check security updates: cat /var/log/unattended-upgrades/unattended-upgrades.log"
    echo "  - Scan image for CVEs: sudo $DOCKERHOSTING_DIR/scripts/scan-image.sh <image>"
    echo "  - Deploy site: cd $DOCKERHOSTING_DIR && sudo ./deploy-site.sh"
    echo "  - Add Traefik route: sudo $DOCKERHOSTING_DIR/scripts/add-traefik-site.sh <domain> <port>"
    echo ""
}

# Run main function
main "$@"
