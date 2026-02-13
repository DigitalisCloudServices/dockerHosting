#!/bin/bash

#############################################
# dockerHosting - Server Setup Script
#
# Purpose: Initial setup for Debian Trixie server
# - Installs Docker and Docker Compose
# - Installs essential packages
# - Configures firewall
# - Sets up log rotation
# - Prepares server for hosting Docker-based sites
#############################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Main setup function
main() {
    display_banner
    check_root
    check_os

    log_info "Starting server setup..."

    # Update system
    log_info "Updating system packages..."
    apt-get update
    apt-get upgrade -y

    # Install packages
    log_info "Installing essential packages..."
    if [ -f "$SCRIPT_DIR/scripts/install-packages.sh" ]; then
        bash "$SCRIPT_DIR/scripts/install-packages.sh"
    else
        log_warn "install-packages.sh not found, installing basic packages..."
        apt-get install -y curl git wget ca-certificates gnupg lsb-release \
            software-properties-common apt-transport-https make vim \
            htop net-tools ufw logrotate
    fi

    # Install Docker
    log_info "Installing Docker..."
    if [ -f "$SCRIPT_DIR/scripts/install-docker.sh" ]; then
        bash "$SCRIPT_DIR/scripts/install-docker.sh"
    else
        log_error "install-docker.sh not found in scripts directory"
        exit 1
    fi

    # Configure firewall
    log_info "Configuring firewall..."
    if [ -f "$SCRIPT_DIR/scripts/configure-firewall.sh" ]; then
        bash "$SCRIPT_DIR/scripts/configure-firewall.sh"
    else
        log_warn "configure-firewall.sh not found, skipping firewall setup"
    fi

    # Setup base log rotation
    log_info "Configuring log rotation..."
    if [ -f "$SCRIPT_DIR/scripts/setup-logrotate.sh" ]; then
        bash "$SCRIPT_DIR/scripts/setup-logrotate.sh" "docker-system" "/var/lib/docker/containers"
    fi

    # Create standard directories
    log_info "Creating standard directories..."
    mkdir -p /opt
    mkdir -p /var/log/docker-sites

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
    echo "  2. Run './deploy-site.sh' to deploy a new site"
    echo "  3. Or manually clone your site repository to /opt/"
    echo ""
    log_info "Useful commands:"
    echo "  - Check Docker: docker --version"
    echo "  - Check firewall: sudo ufw status"
    echo "  - Deploy site: ./deploy-site.sh"
    echo ""
}

# Run main function
main "$@"
