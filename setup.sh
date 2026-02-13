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
        read -p "Remove and re-clone? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$DOCKERHOSTING_DIR"
        else
            log_info "Using existing directory"
            return 0
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

    # Configure firewall
    if [ -f "$DOCKERHOSTING_DIR/scripts/configure-firewall.sh" ]; then
        log_info "Configuring firewall..."
        bash "$DOCKERHOSTING_DIR/scripts/configure-firewall.sh"
    fi

    # Setup log rotation
    if [ -f "$DOCKERHOSTING_DIR/scripts/setup-logrotate.sh" ]; then
        log_info "Configuring log rotation..."
        bash "$DOCKERHOSTING_DIR/scripts/setup-logrotate.sh" "docker-system" "/var/lib/docker/containers"
    fi

    # Create standard directories
    log_info "Creating standard directories..."
    mkdir -p /opt
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
    log_warn "IMPORTANT: Please log out and log back in to apply group changes"
    echo ""
    log_info "Next steps:"
    echo "  1. Log out and log back in"
    echo "  2. Deploy a site using dockerHosting:"
    echo "     cd $DOCKERHOSTING_DIR && sudo ./deploy-site.sh"
    echo "  3. Or manually clone your site repository to /opt/"
    echo ""
    log_info "Useful commands:"
    echo "  - Check Docker: docker --version"
    echo "  - Check firewall: sudo ufw status"
    echo "  - Deploy site: cd $DOCKERHOSTING_DIR && sudo ./deploy-site.sh"
    echo ""
}

# Run main function
main "$@"
