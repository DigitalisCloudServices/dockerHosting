#!/bin/bash

#############################################
# Package Cleanup Script
#
# Removes unnecessary packages from servers to minimize attack surface
# Run this on previously configured servers to clean up build tools
# and other packages that are no longer part of the minimal installation
#############################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root or with sudo"
    exit 1
fi

echo ""
echo "╔═══════════════════════════════════════════════╗"
echo "║   Package Cleanup Script                      ║"
echo "║   Removing unnecessary packages               ║"
echo "╚═══════════════════════════════════════════════╝"
echo ""

log_warn "This script will remove the following packages and their dependencies:"
echo "  - Build tools: build-essential, make, gcc, g++"
echo "  - Network debugging: tcpdump, traceroute, nethogs"
echo "  - Performance monitoring: sysstat, dstat"
echo "  - Development tools: python3-pip, python3-venv"
echo "  - Backup tools: duplicity"
echo "  - Nginx plugins: python3-certbot-nginx (certbot is kept)"
echo "  - Utilities: ncdu, tmux, yq, bc, dos2unix, bzip2, tree"
echo ""
log_warn "NVM (Node Version Manager) will be removed from user home directories if found"
echo ""

read -p "Do you want to continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Cleanup cancelled"
    exit 0
fi

echo ""
log_info "Starting package cleanup..."
echo ""

# List of packages to remove
PACKAGES_TO_REMOVE=(
    "build-essential"
    "make"
    "gcc"
    "g++"
    "tcpdump"
    "traceroute"
    "nethogs"
    "sysstat"
    "dstat"
    "python3-pip"
    "python3-venv"
    "duplicity"
    "python3-certbot-nginx"
    "yq"
    "bc"
    "dos2unix"
    "bzip2"
    "tree"
    "ncdu"
    "tmux"
)

# Check which packages are installed
INSTALLED_PACKAGES=()
for pkg in "${PACKAGES_TO_REMOVE[@]}"; do
    if dpkg -l | grep -q "^ii  $pkg"; then
        INSTALLED_PACKAGES+=("$pkg")
        log_info "Found installed package: $pkg"
    fi
done

if [ ${#INSTALLED_PACKAGES[@]} -eq 0 ]; then
    log_info "No packages to remove (already clean)"
else
    echo ""
    log_info "Removing ${#INSTALLED_PACKAGES[@]} packages..."

    # Remove packages
    apt-get remove --purge -y "${INSTALLED_PACKAGES[@]}"

    log_info "Packages removed successfully"
fi

# Remove NVM from user home directories
echo ""
log_info "Checking for NVM installations..."

NVM_FOUND=false
for home_dir in /home/*; do
    if [ -d "$home_dir" ]; then
        username=$(basename "$home_dir")
        nvm_dir="$home_dir/.nvm"

        if [ -d "$nvm_dir" ]; then
            log_info "Found NVM in $home_dir"
            NVM_FOUND=true

            # Remove NVM directory
            rm -rf "$nvm_dir"
            log_info "Removed NVM directory: $nvm_dir"

            # Remove NVM lines from shell rc files
            for rc_file in .bashrc .bash_profile .zshrc .profile; do
                rc_path="$home_dir/$rc_file"
                if [ -f "$rc_path" ]; then
                    # Backup first
                    cp "$rc_path" "$rc_path.backup.$(date +%Y%m%d)"

                    # Remove NVM-related lines
                    sed -i '/NVM_DIR/d' "$rc_path"
                    sed -i '/nvm.sh/d' "$rc_path"
                    sed -i '/bash_completion/d' "$rc_path"

                    log_info "Cleaned NVM references from $rc_path"
                fi
            done
        fi
    fi
done

if [ "$NVM_FOUND" = false ]; then
    log_info "No NVM installations found"
fi

# Check root user as well
if [ -d "/root/.nvm" ]; then
    log_info "Found NVM in /root"
    rm -rf "/root/.nvm"
    log_info "Removed NVM directory: /root/.nvm"

    for rc_file in .bashrc .bash_profile .zshrc .profile; do
        rc_path="/root/$rc_file"
        if [ -f "$rc_path" ]; then
            cp "$rc_path" "$rc_path.backup.$(date +%Y%m%d)"
            sed -i '/NVM_DIR/d' "$rc_path"
            sed -i '/nvm.sh/d' "$rc_path"
            sed -i '/bash_completion/d' "$rc_path"
            log_info "Cleaned NVM references from $rc_path"
        fi
    done
fi

# Autoremove unused dependencies
echo ""
log_info "Removing unused dependencies..."
apt-get autoremove -y

# Clean package cache
log_info "Cleaning package cache..."
apt-get autoclean -y

echo ""
log_info "════════════════════════════════════════════"
log_info "Cleanup Complete!"
log_info "════════════════════════════════════════════"
echo ""

# Show disk space saved
log_info "Disk space information:"
df -h / | tail -n 1

echo ""
log_info "Summary of actions:"
if [ ${#INSTALLED_PACKAGES[@]} -gt 0 ]; then
    echo "  ✓ Removed ${#INSTALLED_PACKAGES[@]} packages"
fi
if [ "$NVM_FOUND" = true ] || [ -d "/root/.nvm" ]; then
    echo "  ✓ Removed NVM installations"
fi
echo "  ✓ Removed unused dependencies"
echo "  ✓ Cleaned package cache"

echo ""
log_warn "IMPORTANT: Shell rc file backups created with .backup.[date] extension"
log_warn "Users should log out and log back in for shell changes to take effect"
echo ""

# List packages kept for specific purposes
echo ""
log_info "Packages kept in minimal installation:"
log_info "  - htop, iotop, lsof: Basic system monitoring"
log_info "  - screen: Terminal multiplexer for long-running sessions"
log_info "  - jq: JSON processor (essential for Docker operations)"
log_info "  - default-mysql-client: Database debugging"
log_info "  - zip, gzip, unzip, tar: Archive handling"
log_info "  - python3: System base (without pip/venv)"
echo ""
log_info "For temporary debugging, install on-demand:"
log_info "  apt-get install tcpdump traceroute  # Network debugging"
echo ""
