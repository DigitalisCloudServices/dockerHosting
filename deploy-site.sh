#!/bin/bash

#############################################
# dockerHosting - Site Deployment Script
#
# Purpose: Interactive script to deploy a new site
# - Prompts for Git repository and configuration
# - Clones repository
# - Sets up users and permissions
# - Configures log rotation
# - Sets up environment files
#############################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
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
    echo "║   dockerHosting - Site Deployment             ║"
    echo "║   Deploy a new site from Git repository       ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo ""
}

# Prompt for user input
prompt_input() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local is_secret="${4:-false}"

    if [ -n "$default" ]; then
        prompt="$prompt [default: $default]"
    fi

    echo -n "$prompt: "

    if [ "$is_secret" = true ]; then
        read -s input
        echo ""  # New line after secret input
    else
        read input
    fi

    if [ -z "$input" ] && [ -n "$default" ]; then
        input="$default"
    fi

    eval "$var_name='$input'"
}

# Validate Git URL
validate_git_url() {
    local url="$1"

    if [[ ! "$url" =~ ^(https?|git)://.*\.git$ ]] && [[ ! "$url" =~ ^git@.*:.+\.git$ ]] && [[ ! "$url" =~ \.git$ ]]; then
        log_warn "URL doesn't end with .git - this might not be a valid Git repository"
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    return 0
}

# Clone repository
clone_repository() {
    local git_url="$1"
    local deploy_dir="$2"
    local git_branch="$3"

    log_step "Cloning repository..."

    if [ -d "$deploy_dir" ]; then
        log_warn "Directory $deploy_dir already exists"
        read -p "Remove and re-clone? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$deploy_dir"
        else
            log_info "Using existing directory"
            return 0
        fi
    fi

    # Clone the repository
    if [ -n "$git_branch" ]; then
        log_info "Cloning branch: $git_branch"
        git clone -b "$git_branch" "$git_url" "$deploy_dir"
    else
        git clone "$git_url" "$deploy_dir"
    fi

    log_info "Repository cloned successfully to $deploy_dir"
}

# Setup user and permissions
setup_user_permissions() {
    local site_name="$1"
    local deploy_dir="$2"
    local create_user="$3"

    log_step "Setting up user and permissions..."

    if [ "$create_user" = "yes" ]; then
        if [ -f "$SCRIPT_DIR/scripts/setup-users.sh" ]; then
            bash "$SCRIPT_DIR/scripts/setup-users.sh" "$site_name" "$deploy_dir"
        else
            log_warn "setup-users.sh not found, creating user manually..."

            # Check if user exists
            if id "$site_name" &>/dev/null; then
                log_info "User $site_name already exists"
            else
                useradd -r -m -d "/home/$site_name" -s /bin/bash "$site_name"
                log_info "Created user: $site_name"
            fi

            # Add user to docker group
            usermod -aG docker "$site_name"

            # Set ownership
            chown -R "$site_name:$site_name" "$deploy_dir"
            log_info "Set ownership of $deploy_dir to $site_name"
        fi
    else
        log_info "Skipping user creation"
    fi
}

# Setup SSH key for Git authentication
setup_git_ssh_key() {
    local site_name="$1"
    local ssh_key="$2"
    local git_url="$3"

    if [ -z "$ssh_key" ]; then
        log_info "No SSH key provided, skipping Git SSH setup"
        return 0
    fi

    log_step "Setting up Git SSH authentication..."

    # Determine home directory
    local user_home
    if [ "$site_name" = "root" ]; then
        user_home="/root"
    else
        user_home="/home/$site_name"
    fi

    # Create .ssh directory
    mkdir -p "$user_home/.ssh"
    chmod 700 "$user_home/.ssh"

    # Determine key type and filename
    local key_file="$user_home/.ssh/id_ed25519"
    if echo "$ssh_key" | grep -q "BEGIN RSA PRIVATE KEY"; then
        key_file="$user_home/.ssh/id_rsa"
    elif echo "$ssh_key" | grep -q "BEGIN OPENSSH PRIVATE KEY"; then
        key_file="$user_home/.ssh/id_ed25519"
    fi

    # Save the SSH key
    echo "$ssh_key" > "$key_file"
    chmod 600 "$key_file"
    chown "$site_name:$site_name" "$key_file"
    log_info "Saved SSH key: $key_file"

    # Extract Git host from URL
    local git_host=""
    if [[ "$git_url" =~ git@([^:]+): ]]; then
        git_host="${BASH_REMATCH[1]}"
    elif [[ "$git_url" =~ https?://([^/]+) ]]; then
        git_host="${BASH_REMATCH[1]}"
    fi

    # Create SSH config for the Git host
    if [ -n "$git_host" ]; then
        local ssh_config="$user_home/.ssh/config"

        # Check if config already has entry for this host
        if [ -f "$ssh_config" ] && grep -q "Host $git_host" "$ssh_config"; then
            log_info "SSH config already has entry for $git_host"
        else
            cat >> "$ssh_config" <<EOF

# Git SSH configuration for $git_host
Host $git_host
    HostName $git_host
    User git
    IdentityFile $key_file
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF
            chmod 600 "$ssh_config"
            chown "$site_name:$site_name" "$ssh_config"
            log_info "Created SSH config for $git_host"
        fi
    fi

    # Set ownership of .ssh directory
    chown -R "$site_name:$site_name" "$user_home/.ssh"

    log_info "Git SSH authentication configured for user: $site_name"
}

# Setup log rotation
setup_logging() {
    local site_name="$1"
    local deploy_dir="$2"
    local setup_logrotate="$3"

    if [ "$setup_logrotate" = "yes" ]; then
        log_step "Setting up log rotation..."

        if [ -f "$SCRIPT_DIR/scripts/setup-logrotate.sh" ]; then
            bash "$SCRIPT_DIR/scripts/setup-logrotate.sh" "$site_name" "$deploy_dir"
        else
            log_warn "setup-logrotate.sh not found, skipping log rotation setup"
        fi
    else
        log_info "Skipping log rotation setup"
    fi
}

# Setup environment file
setup_environment() {
    local deploy_dir="$1"
    local encryption_key="$2"
    local additional_vars="$3"

    log_step "Setting up environment file..."

    local env_file="$deploy_dir/.env"

    # Check if .env template exists in the repository
    if [ -f "$deploy_dir/.env_template" ]; then
        log_info "Found .env_template in repository"
        cp "$deploy_dir/.env_template" "$env_file"
    elif [ -f "$deploy_dir/.env_template_prod" ]; then
        log_info "Found .env_template_prod in repository"
        cp "$deploy_dir/.env_template_prod" "$env_file"
    elif [ -f "$SCRIPT_DIR/templates/env.template" ]; then
        log_info "Using default env.template"
        cp "$SCRIPT_DIR/templates/env.template" "$env_file"
    else
        log_info "Creating new .env file"
        touch "$env_file"
    fi

    # Add encryption key if provided
    if [ -n "$encryption_key" ]; then
        echo "" >> "$env_file"
        echo "# Encryption key" >> "$env_file"
        echo "ENCRYPTION_KEY=$encryption_key" >> "$env_file"
        log_info "Added encryption key to .env"
    fi

    # Add additional variables if provided
    if [ -n "$additional_vars" ]; then
        echo "" >> "$env_file"
        echo "# Additional variables" >> "$env_file"
        echo "$additional_vars" >> "$env_file"
        log_info "Added additional variables to .env"
    fi

    chmod 600 "$env_file"
    log_info "Environment file created: $env_file"
}

# Setup systemd service (optional)
setup_systemd_service() {
    local site_name="$1"
    local deploy_dir="$2"
    local setup_service="$3"

    if [ "$setup_service" = "yes" ]; then
        log_step "Setting up systemd service..."

        if [ -f "$SCRIPT_DIR/templates/systemd.service.template" ]; then
            local service_file="/etc/systemd/system/${site_name}.service"

            # Replace placeholders in template
            sed -e "s|{{SITE_NAME}}|$site_name|g" \
                -e "s|{{DEPLOY_DIR}}|$deploy_dir|g" \
                "$SCRIPT_DIR/templates/systemd.service.template" > "$service_file"

            systemctl daemon-reload
            log_info "Systemd service created: $service_file"
            log_info "Enable with: systemctl enable $site_name"
            log_info "Start with: systemctl start $site_name"
        else
            log_warn "systemd.service.template not found, skipping service creation"
        fi
    else
        log_info "Skipping systemd service setup"
    fi
}

# Run site-specific configuration
run_site_config() {
    local deploy_dir="$1"
    local site_name="$2"

    log_step "Running site-specific configuration..."

    # Check if the repository has its own setup script
    if [ -f "$deploy_dir/scripts/install-system-config.sh" ]; then
        log_info "Found site-specific install-system-config.sh"
        read -p "Run site-specific configuration script? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            cd "$deploy_dir"
            bash "$deploy_dir/scripts/install-system-config.sh"
            cd "$SCRIPT_DIR"
        fi
    fi

    # Check for setup.sh in the repository
    if [ -f "$deploy_dir/setup.sh" ]; then
        log_info "Found setup.sh in repository"
        read -p "Run repository setup.sh? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            cd "$deploy_dir"
            bash "$deploy_dir/setup.sh"
            cd "$SCRIPT_DIR"
        fi
    fi
}

# Main deployment function
main() {
    display_banner
    check_root

    # Gather information
    log_info "Please provide the following information:"
    echo ""

    prompt_input "Git repository URL" "" "GIT_URL"

    if ! validate_git_url "$GIT_URL"; then
        log_error "Invalid Git URL"
        exit 1
    fi

    prompt_input "Site name (alphanumeric, lowercase)" "" "SITE_NAME"
    SITE_NAME=$(echo "$SITE_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')

    if [ -z "$SITE_NAME" ]; then
        log_error "Site name is required"
        exit 1
    fi

    prompt_input "Deployment directory" "/opt/apps/$SITE_NAME" "DEPLOY_DIR"
    prompt_input "Git branch (leave empty for default)" "" "GIT_BRANCH"

    echo ""
    log_info "Optional configuration:"

    prompt_input "Create dedicated user for this site? (yes/no)" "yes" "CREATE_USER"
    prompt_input "Setup log rotation? (yes/no)" "yes" "SETUP_LOGROTATE"
    prompt_input "Setup systemd service? (yes/no)" "no" "SETUP_SYSTEMD"

    echo ""
    prompt_input "Encryption key (leave empty to skip)" "" "ENCRYPTION_KEY" true

    echo ""
    log_info "Git SSH authentication (for private repositories):"
    read -p "Provide SSH private key for Git? (y/N) " -n 1 -r
    echo
    GIT_SSH_KEY=""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Paste SSH private key (press Ctrl+D when done):"
        GIT_SSH_KEY=$(cat)
        if [ -n "$GIT_SSH_KEY" ]; then
            log_info "SSH key captured (will be configured for site user)"
        else
            log_warn "No SSH key provided"
        fi
    fi

    echo ""
    prompt_input "Additional environment variables (format: KEY=VALUE, leave empty to skip)" "" "ADDITIONAL_VARS"

    # Confirmation
    echo ""
    log_info "════════════════════════════════════════════"
    log_info "Deployment Summary:"
    log_info "════════════════════════════════════════════"
    echo "  Git URL: $GIT_URL"
    echo "  Site name: $SITE_NAME"
    echo "  Deploy directory: $DEPLOY_DIR"
    echo "  Git branch: ${GIT_BRANCH:-default}"
    echo "  Create user: $CREATE_USER"
    echo "  Git SSH key: $([ -n "$GIT_SSH_KEY" ] && echo "provided" || echo "not provided")"
    echo "  Setup log rotation: $SETUP_LOGROTATE"
    echo "  Setup systemd service: $SETUP_SYSTEMD"
    log_info "════════════════════════════════════════════"
    echo ""

    read -p "Proceed with deployment? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warn "Deployment cancelled"
        exit 0
    fi

    # Execute deployment steps
    echo ""
    log_info "Starting deployment..."
    echo ""

    # Create user FIRST if needed (before cloning)
    if [ "$CREATE_USER" = "yes" ]; then
        log_step "Setting up user..."

        if [ -f "$SCRIPT_DIR/scripts/setup-users.sh" ]; then
            bash "$SCRIPT_DIR/scripts/setup-users.sh" "$SITE_NAME" "$DEPLOY_DIR"
        else
            log_warn "setup-users.sh not found, creating user manually..."

            # Check if user exists
            if id "$SITE_NAME" &>/dev/null; then
                log_info "User $SITE_NAME already exists"
            else
                useradd -r -m -d "/home/$SITE_NAME" -s /bin/bash "$SITE_NAME"
                log_info "Created user: $SITE_NAME"
            fi

            # Add user to docker group
            usermod -aG docker "$SITE_NAME"
        fi

        # Setup Git SSH keys BEFORE cloning if provided
        if [ -n "$GIT_SSH_KEY" ]; then
            setup_git_ssh_key "$SITE_NAME" "$GIT_SSH_KEY" "$GIT_URL"
        fi
    fi

    # Clone repository (as user if SSH key provided, otherwise as root)
    if [ "$CREATE_USER" = "yes" ] && [ -n "$GIT_SSH_KEY" ]; then
        log_step "Cloning repository as user $SITE_NAME..."

        # Clone as the site user
        if [ -n "$GIT_BRANCH" ]; then
            log_info "Cloning branch: $GIT_BRANCH"
            sudo -u "$SITE_NAME" git clone -b "$GIT_BRANCH" "$GIT_URL" "$DEPLOY_DIR"
        else
            sudo -u "$SITE_NAME" git clone "$GIT_URL" "$DEPLOY_DIR"
        fi

        log_info "Repository cloned successfully to $DEPLOY_DIR"
    else
        # Clone as root (original behavior for HTTPS or when no SSH key)
        clone_repository "$GIT_URL" "$DEPLOY_DIR" "$GIT_BRANCH"
    fi

    # Set ownership if user was created
    if [ "$CREATE_USER" = "yes" ]; then
        log_info "Setting ownership of $DEPLOY_DIR to $SITE_NAME"
        chown -R "$SITE_NAME:$SITE_NAME" "$DEPLOY_DIR"
    fi

    setup_environment "$DEPLOY_DIR" "$ENCRYPTION_KEY" "$ADDITIONAL_VARS"
    setup_logging "$SITE_NAME" "$DEPLOY_DIR" "$SETUP_LOGROTATE"
    setup_systemd_service "$SITE_NAME" "$DEPLOY_DIR" "$SETUP_SYSTEMD"
    run_site_config "$DEPLOY_DIR" "$SITE_NAME"

    # Final messages
    echo ""
    log_info "════════════════════════════════════════════"
    log_info "Deployment completed successfully!"
    log_info "════════════════════════════════════════════"
    echo ""
    log_info "Site deployed to: $DEPLOY_DIR"
    log_info "Next steps:"
    echo "  1. Review and update .env file: $DEPLOY_DIR/.env"
    echo "  2. Navigate to site: cd $DEPLOY_DIR"
    echo "  3. Start services: docker compose up -d"
    echo ""

    if [ "$SETUP_SYSTEMD" = "yes" ]; then
        log_info "Systemd service commands:"
        echo "  - Enable: systemctl enable $SITE_NAME"
        echo "  - Start: systemctl start $SITE_NAME"
        echo "  - Status: systemctl status $SITE_NAME"
        echo ""
    fi
}

# Run main function
main "$@"
