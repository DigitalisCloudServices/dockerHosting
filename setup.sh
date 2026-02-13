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
    apt-get install -y curl git wget ca-certificates gnupg lsb-release apt-transport-https

    log_info "Basic packages installed"
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
                    return 0
                else
                    log_error "Failed to update repository"
                    exit 1
                fi
            else
                log_info "Using existing directory without updating"
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
    else
        log_error "Failed to clone repository"
        exit 1
    fi
}

# Run full setup from repository
run_full_setup() {
    log_info "Running full setup from repository scripts..."
    echo ""

    cd "$DOCKERHOSTING_DIR"

    # Install packages from repository config
    if [ -f "$DOCKERHOSTING_DIR/scripts/install-packages.sh" ]; then
        log_info "Installing additional packages..."
        bash "$DOCKERHOSTING_DIR/scripts/install-packages.sh"
    fi

    # Install Docker
    if [ -f "$DOCKERHOSTING_DIR/scripts/install-docker.sh" ]; then
        log_info "Installing Docker..."
        bash "$DOCKERHOSTING_DIR/scripts/install-docker.sh"
    fi

    # Install and configure boundary Nginx
    if [ -f "$DOCKERHOSTING_DIR/scripts/install-nginx.sh" ]; then
        log_info "Installing boundary Nginx..."
        bash "$DOCKERHOSTING_DIR/scripts/install-nginx.sh"
    fi

    # Configure firewall
    if [ -f "$DOCKERHOSTING_DIR/scripts/configure-firewall.sh" ]; then
        log_info "Configuring firewall..."
        bash "$DOCKERHOSTING_DIR/scripts/configure-firewall.sh"
    fi

    # Harden kernel parameters
    if [ -f "$DOCKERHOSTING_DIR/scripts/harden-kernel.sh" ]; then
        log_info "Hardening kernel parameters..."
        bash "$DOCKERHOSTING_DIR/scripts/harden-kernel.sh"
    fi

    # Setup audit logging
    if [ -f "$DOCKERHOSTING_DIR/scripts/setup-audit.sh" ]; then
        log_info "Setting up audit logging..."
        bash "$DOCKERHOSTING_DIR/scripts/setup-audit.sh"
    fi

    # Configure automated security updates
    if [ -f "$DOCKERHOSTING_DIR/scripts/setup-auto-updates.sh" ]; then
        log_info "Configuring automated security updates..."
        bash "$DOCKERHOSTING_DIR/scripts/setup-auto-updates.sh"
    fi

    # Harden Docker daemon
    if [ -f "$DOCKERHOSTING_DIR/scripts/harden-docker.sh" ]; then
        log_info "Hardening Docker daemon..."
        bash "$DOCKERHOSTING_DIR/scripts/harden-docker.sh"
    fi

    # Configure PAM password policy
    if [ -f "$DOCKERHOSTING_DIR/scripts/setup-pam-policy.sh" ]; then
        log_info "Configuring password policy..."
        bash "$DOCKERHOSTING_DIR/scripts/setup-pam-policy.sh"
    fi

    # Setup AIDE file integrity monitoring
    if [ -f "$DOCKERHOSTING_DIR/scripts/setup-aide.sh" ]; then
        log_info "Setting up file integrity monitoring..."
        bash "$DOCKERHOSTING_DIR/scripts/setup-aide.sh"
    fi

    # Harden shared memory
    if [ -f "$DOCKERHOSTING_DIR/scripts/harden-shared-memory.sh" ]; then
        log_info "Hardening shared memory..."
        bash "$DOCKERHOSTING_DIR/scripts/harden-shared-memory.sh"
    fi

    # Enhanced fail2ban configuration
    if [ -f "$DOCKERHOSTING_DIR/scripts/setup-fail2ban-enhanced.sh" ]; then
        log_info "Configuring enhanced fail2ban protection..."
        bash "$DOCKERHOSTING_DIR/scripts/setup-fail2ban-enhanced.sh"
    fi

    # Setup email notifications (optional)
    if [ -f "$DOCKERHOSTING_DIR/scripts/setup-email.sh" ]; then
        echo ""
        log_warn "Email notifications allow the system to send alerts, security notifications, and cron output."
        read -p "Configure email notifications? (y/N) " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            bash "$DOCKERHOSTING_DIR/scripts/setup-email.sh"
        else
            log_info "Skipping email configuration"
        fi
    fi

    # Harden SSH (do this last as it may affect connectivity)
    if [ -f "$DOCKERHOSTING_DIR/scripts/harden-ssh.sh" ]; then
        log_warn "Hardening SSH configuration..."
        log_warn "IMPORTANT: Ensure you have SSH keys configured before this step!"
        bash "$DOCKERHOSTING_DIR/scripts/harden-ssh.sh"
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
    check_os

    log_info "Starting server setup..."
    echo ""

    # Step 1: Install basic packages
    install_basic_packages
    echo ""

    # Step 2: Clone repository
    clone_repository
    echo ""

    # Step 3: Run full setup from repository
    run_full_setup

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
    echo "  ✓ Firewall (UFW) with default-deny"
    echo "  ✓ Kernel hardening (ASLR, SYN cookies, anti-spoofing)"
    echo "  ✓ Audit logging (auditd) for security events"
    echo "  ✓ Automated security updates (daily)"
    echo "  ✓ SSH hardening (key-only auth, rate limiting)"
    echo "  ✓ fail2ban protection (SSH brute-force prevention)"
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
    echo "  - Check firewall: sudo ufw status"
    echo "  - Check audit logs: sudo ausearch -ts recent"
    echo "  - Check security updates: cat /var/log/unattended-upgrades/unattended-upgrades.log"
    echo "  - Deploy site: cd $DOCKERHOSTING_DIR && sudo ./deploy-site.sh"
    echo ""
}

# Run main function
main "$@"
