#!/bin/bash

#############################################
# Configure site-specific settings
#
# Usage: ./configure-site.sh <site_name> <deploy_dir>
#
# This script can be customized for specific site requirements
#############################################

set -e

SITE_NAME="$1"
DEPLOY_DIR="$2"

if [ -z "$SITE_NAME" ] || [ -z "$DEPLOY_DIR" ]; then
    echo "[ERROR] Usage: $0 <site_name> <deploy_dir>"
    exit 1
fi

echo "[INFO] Configuring site-specific settings for $SITE_NAME..."

# Create necessary directories
mkdir -p "$DEPLOY_DIR/logs"
mkdir -p "$DEPLOY_DIR/data"
mkdir -p "$DEPLOY_DIR/backups"

# Set ownership
chown -R "$SITE_NAME:$SITE_NAME" "$DEPLOY_DIR/logs"
chown -R "$SITE_NAME:$SITE_NAME" "$DEPLOY_DIR/data"
chown -R "$SITE_NAME:$SITE_NAME" "$DEPLOY_DIR/backups"

echo "[INFO] Created standard directories: logs, data, backups"

# Check for docker-compose files
if ls "$DEPLOY_DIR"/docker-compose*.yml 1> /dev/null 2>&1; then
    echo "[INFO] Found docker-compose files"

    # Validate docker-compose configuration
    cd "$DEPLOY_DIR"
    COMPOSE_FILE=$(ls docker-compose*.yml | tail -1)
    echo "[INFO] Validating $COMPOSE_FILE..."

    if docker compose -f "$COMPOSE_FILE" config > /dev/null 2>&1; then
        echo "[INFO] Docker Compose configuration is valid"
    else
        echo "[WARN] Docker Compose configuration validation failed"
    fi

    cd - > /dev/null
fi

# Check for .env template
if [ -f "$DEPLOY_DIR/.env_template" ] || [ -f "$DEPLOY_DIR/.env_template_prod" ]; then
    echo "[INFO] Environment template found"

    if [ ! -f "$DEPLOY_DIR/.env" ]; then
        echo "[WARN] No .env file found. Remember to create one from the template!"
    fi
fi

# Site-specific configurations can be added here
# For example:
# - Database initialization
# - SSL certificate setup
# - Backup cron jobs
# - Monitoring setup

echo "[INFO] Site configuration complete for $SITE_NAME"
echo ""
echo "[NEXT STEPS]"
echo "  1. Review .env file: $DEPLOY_DIR/.env"
echo "  2. Start services: cd $DEPLOY_DIR && docker compose up -d"
echo "  3. Check logs: docker compose logs -f"
echo ""
