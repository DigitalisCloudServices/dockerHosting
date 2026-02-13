#!/bin/bash

#############################################
# dockerHosting - Site Deployment Script
#
# Purpose: Deploy a new site (interactive or scripted)
# - Prompts for Git repository and configuration
# - Clones repository
# - Sets up users and permissions
# - Configures log rotation
# - Sets up environment files
#
# Usage:
#   Interactive: ./deploy-site.sh
#   Scripted:    ./deploy-site.sh --git-url <url> --site-name <name> [options]
#
# Options:
#   --git-url <url>              Git repository URL (required)
#   --site-name <name>           Site name (required)
#   --deploy-dir <path>          Deployment directory (default: /opt/apps/<site-name>)
#   --git-branch <branch>        Git branch (optional)
#   --create-user <yes|no>       Create dedicated user (default: yes)
#   --setup-logrotate <yes|no>   Setup log rotation (default: yes)
#   --setup-systemd <yes|no>     Setup systemd service (default: no)
#   --encryption-key <key>       Encryption key (optional)
#   --ssh-key-file <path>        Path to SSH private key file (optional)
#   --additional-vars <vars>     Additional env vars (optional)
#   --non-interactive            Run without prompts (default: interactive if no args)
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

    # Get the user's actual home directory from the system
    local user_home
    if [ "$site_name" = "root" ]; then
        user_home="/root"
    else
        user_home=$(eval echo ~"$site_name")
    fi

    log_info "Using home directory: $user_home"

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

# Parse command-line arguments
parse_args() {
    # Defaults
    NON_INTERACTIVE=false

    # Check if any arguments provided
    if [ $# -eq 0 ]; then
        return 0  # No args, run interactively
    fi

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --git-url)
                GIT_URL="$2"
                shift 2
                ;;
            --site-name)
                SITE_NAME="$2"
                shift 2
                ;;
            --deploy-dir)
                DEPLOY_DIR="$2"
                shift 2
                ;;
            --git-branch)
                GIT_BRANCH="$2"
                shift 2
                ;;
            --create-user)
                CREATE_USER="$2"
                shift 2
                ;;
            --setup-logrotate)
                SETUP_LOGROTATE="$2"
                shift 2
                ;;
            --setup-systemd)
                SETUP_SYSTEMD="$2"
                shift 2
                ;;
            --encryption-key)
                ENCRYPTION_KEY="$2"
                shift 2
                ;;
            --ssh-key-file)
                if [ ! -f "$2" ]; then
                    log_error "SSH key file not found: $2"
                    exit 1
                fi
                GIT_SSH_KEY=$(cat "$2")
                SSH_KEY_FILE="$2"
                shift 2
                ;;
            --additional-vars)
                ADDITIONAL_VARS="$2"
                shift 2
                ;;
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            *)
                log_error "Unknown argument: $1"
                echo ""
                echo "Usage: $0 [options]"
                echo "  --git-url <url>              Git repository URL"
                echo "  --site-name <name>           Site name"
                echo "  --deploy-dir <path>          Deployment directory"
                echo "  --git-branch <branch>        Git branch"
                echo "  --create-user <yes|no>       Create dedicated user"
                echo "  --setup-logrotate <yes|no>   Setup log rotation"
                echo "  --setup-systemd <yes|no>     Setup systemd service"
                echo "  --encryption-key <key>       Encryption key"
                echo "  --ssh-key-file <path>        SSH private key file"
                echo "  --additional-vars <vars>     Additional environment variables"
                echo "  --non-interactive            Run without prompts"
                exit 1
                ;;
        esac
    done

    # Mark as non-interactive if required args are provided
    if [ -n "$GIT_URL" ] && [ -n "$SITE_NAME" ]; then
        NON_INTERACTIVE=true
    fi

    # Validate required args for non-interactive mode
    if [ "$NON_INTERACTIVE" = true ]; then
        if [ -z "$GIT_URL" ]; then
            log_error "Non-interactive mode requires --git-url"
            exit 1
        fi
        if [ -z "$SITE_NAME" ]; then
            log_error "Non-interactive mode requires --site-name"
            exit 1
        fi
    fi
}

# Main deployment function
main() {
    display_banner
    check_root

    # Parse command-line arguments
    parse_args "$@"

    # If non-interactive, set defaults for unspecified options
    if [ "$NON_INTERACTIVE" = true ]; then
        SITE_NAME=$(echo "$SITE_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
        DEPLOY_DIR="${DEPLOY_DIR:-/opt/apps/$SITE_NAME}"
        CREATE_USER="${CREATE_USER:-yes}"
        SETUP_LOGROTATE="${SETUP_LOGROTATE:-yes}"
        SETUP_SYSTEMD="${SETUP_SYSTEMD:-no}"
        ENCRYPTION_KEY="${ENCRYPTION_KEY:-}"
        GIT_SSH_KEY="${GIT_SSH_KEY:-}"
        ADDITIONAL_VARS="${ADDITIONAL_VARS:-}"
    else
        # Interactive mode: Gather information
        log_info "Please provide the following information:"
        echo ""
    fi

    # Gather information (skip if non-interactive and values already set)
    if [ "$NON_INTERACTIVE" != true ]; then

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

    fi  # End of interactive block

    # Validate Git URL if provided via args
    if [ "$NON_INTERACTIVE" = true ] && ! validate_git_url "$GIT_URL"; then
        log_error "Invalid Git URL: $GIT_URL"
        exit 1
    fi

    # Confirmation / Summary
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

    # Generate replay command (shown before deployment in case of failure)
    log_info "To replicate this deployment, use:"
    echo ""
    echo "sudo ./deploy-site.sh \\"
    echo "  --git-url \"$GIT_URL\" \\"
    echo "  --site-name \"$SITE_NAME\" \\"
    echo "  --deploy-dir \"$DEPLOY_DIR\" \\"
    if [ -n "$GIT_BRANCH" ]; then
        echo "  --git-branch \"$GIT_BRANCH\" \\"
    fi
    echo "  --create-user $CREATE_USER \\"
    echo "  --setup-logrotate $SETUP_LOGROTATE \\"
    if [ -n "$ENCRYPTION_KEY" ]; then
        echo "  --encryption-key \"[REDACTED]\" \\"
    fi
    if [ -n "$GIT_SSH_KEY" ]; then
        if [ -n "$SSH_KEY_FILE" ]; then
            echo "  --ssh-key-file \"$SSH_KEY_FILE\" \\"
        else
            echo "  --ssh-key-file \"/path/to/ssh/key\" \\"
        fi
    fi
    if [ -n "$ADDITIONAL_VARS" ]; then
        echo "  --additional-vars \"$ADDITIONAL_VARS\" \\"
    fi
    echo "  --setup-systemd $SETUP_SYSTEMD"
    echo ""

    # Confirm only in interactive mode
    if [ "$NON_INTERACTIVE" != true ]; then
        read -p "Proceed with deployment? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_warn "Deployment cancelled"
            exit 0
        fi
    fi

    # Execute deployment steps
    echo ""
    log_info "Starting deployment..."
    echo ""

    # Create user and setup deployment directory structure
    if [ "$CREATE_USER" = "yes" ]; then
        log_step "Setting up user and deployment directory..."

        if [ -f "$SCRIPT_DIR/scripts/setup-users.sh" ]; then
            bash "$SCRIPT_DIR/scripts/setup-users.sh" "$SITE_NAME" "$DEPLOY_DIR"
        else
            log_warn "setup-users.sh not found, creating user manually..."

            # Check if user exists
            if id "$SITE_NAME" &>/dev/null; then
                log_info "User $SITE_NAME already exists"
            else
                useradd -r -m -d "$DEPLOY_DIR" -s /bin/bash "$SITE_NAME"
                log_info "Created user: $SITE_NAME with home: $DEPLOY_DIR"
            fi

            # Add user to docker group
            usermod -aG docker "$SITE_NAME"
        fi

        # Setup Git SSH keys if provided
        if [ -n "$GIT_SSH_KEY" ]; then
            setup_git_ssh_key "$SITE_NAME" "$GIT_SSH_KEY" "$GIT_URL"
        fi
    fi

    # Git repository directory (subdirectory of deployment directory)
    GIT_DIR="$DEPLOY_DIR/git"

    # Clone repository into git subdirectory
    if [ "$CREATE_USER" = "yes" ] && [ -n "$GIT_SSH_KEY" ]; then
        log_step "Cloning repository as user $SITE_NAME into $GIT_DIR..."

        # Clone as the site user
        if [ -n "$GIT_BRANCH" ]; then
            log_info "Cloning branch: $GIT_BRANCH"
            sudo -u "$SITE_NAME" git clone -b "$GIT_BRANCH" "$GIT_URL" "$GIT_DIR"
        else
            sudo -u "$SITE_NAME" git clone "$GIT_URL" "$GIT_DIR"
        fi

        log_info "Repository cloned successfully to $GIT_DIR"
    else
        # Clone as root (original behavior for HTTPS or when no SSH key)
        log_step "Cloning repository into $GIT_DIR..."

        if [ -n "$GIT_BRANCH" ]; then
            log_info "Cloning branch: $GIT_BRANCH"
            git clone -b "$GIT_BRANCH" "$GIT_URL" "$GIT_DIR"
        else
            git clone "$GIT_URL" "$GIT_DIR"
        fi

        log_info "Repository cloned successfully to $GIT_DIR"
    fi

    # Set ownership of git directory if user was created
    if [ "$CREATE_USER" = "yes" ]; then
        log_info "Setting ownership of $GIT_DIR to $SITE_NAME"
        chown -R "$SITE_NAME:$SITE_NAME" "$GIT_DIR"
    fi

    setup_environment "$GIT_DIR" "$ENCRYPTION_KEY" "$ADDITIONAL_VARS"
    setup_logging "$SITE_NAME" "$GIT_DIR" "$SETUP_LOGROTATE"
    setup_systemd_service "$SITE_NAME" "$GIT_DIR" "$SETUP_SYSTEMD"
    run_site_config "$GIT_DIR" "$SITE_NAME"

    # Final messages
    echo ""
    log_info "════════════════════════════════════════════"
    log_info "Deployment completed successfully!"
    log_info "════════════════════════════════════════════"
    echo ""
    log_info "Site deployed to: $DEPLOY_DIR"
    log_info "  - Helper scripts: $DEPLOY_DIR/bin/"
    log_info "  - Git repository: $GIT_DIR"
    log_info ""
    log_info "Next steps:"
    echo "  1. Review and update .env file: $GIT_DIR/.env"
    echo "  2. Navigate to repository: cd $GIT_DIR"
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
