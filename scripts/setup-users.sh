#!/bin/bash

#############################################
# Setup users and permissions for a site
#
# Usage: ./setup-users.sh <site_name> <deploy_dir>
#############################################

set -e

SITE_NAME="$1"
DEPLOY_DIR="$2"

if [ -z "$SITE_NAME" ] || [ -z "$DEPLOY_DIR" ]; then
    echo "[ERROR] Usage: $0 <site_name> <deploy_dir>"
    exit 1
fi

echo "[INFO] Setting up user and permissions for $SITE_NAME..."

# Create user if it doesn't exist
if id "$SITE_NAME" &>/dev/null; then
    echo "[INFO] User $SITE_NAME already exists"
else
    # Create system user with home directory
    useradd -r -m -d "/home/$SITE_NAME" -s /bin/bash "$SITE_NAME"
    echo "[INFO] Created system user: $SITE_NAME"
fi

# Add user to docker group
if getent group docker > /dev/null; then
    usermod -aG docker "$SITE_NAME"
    echo "[INFO] Added $SITE_NAME to docker group"
fi

# Create log directory for the site
LOG_DIR="/var/log/$SITE_NAME"
mkdir -p "$LOG_DIR"
chown -R "$SITE_NAME:$SITE_NAME" "$LOG_DIR"
echo "[INFO] Created log directory: $LOG_DIR"

# Set ownership of deployment directory
if [ -d "$DEPLOY_DIR" ]; then
    chown -R "$SITE_NAME:$SITE_NAME" "$DEPLOY_DIR"
    echo "[INFO] Set ownership of $DEPLOY_DIR to $SITE_NAME:$SITE_NAME"

    # Set proper permissions
    # Directories: 755 (rwxr-xr-x)
    find "$DEPLOY_DIR" -type d -exec chmod 755 {} \;

    # Files: 644 (rw-r--r--)
    find "$DEPLOY_DIR" -type f -exec chmod 644 {} \;

    # Scripts: 755 (rwxr-xr-x)
    find "$DEPLOY_DIR" -type f -name "*.sh" -exec chmod 755 {} \;

    # .env files: 600 (rw-------)
    find "$DEPLOY_DIR" -type f -name ".env*" -exec chmod 600 {} \;

    echo "[INFO] Set permissions for $DEPLOY_DIR"
fi

# Create SSH directory if needed (for git operations)
SSH_DIR="/home/$SITE_NAME/.ssh"
if [ ! -d "$SSH_DIR" ]; then
    mkdir -p "$SSH_DIR"
    chown "$SITE_NAME:$SITE_NAME" "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    echo "[INFO] Created SSH directory: $SSH_DIR"
fi

echo "[INFO] User and permissions setup complete for $SITE_NAME"
