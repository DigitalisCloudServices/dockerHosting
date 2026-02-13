#!/bin/bash

#############################################
# Setup log rotation for a site
#
# Usage: ./setup-logrotate.sh <site_name> <deploy_dir>
#############################################

set -e

SITE_NAME="$1"
DEPLOY_DIR="$2"

if [ -z "$SITE_NAME" ]; then
    echo "[ERROR] Usage: $0 <site_name> <deploy_dir>"
    exit 1
fi

echo "[INFO] Setting up log rotation for $SITE_NAME..."

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$(dirname "$SCRIPT_DIR")/templates"

LOGROTATE_CONFIG="/etc/logrotate.d/$SITE_NAME"

# Use template if available, otherwise create default config
if [ -f "$TEMPLATE_DIR/logrotate.conf.template" ]; then
    echo "[INFO] Using logrotate.conf.template"

    # Replace placeholders in template
    sed -e "s|{{SITE_NAME}}|$SITE_NAME|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEMPLATE_DIR/logrotate.conf.template" > "$LOGROTATE_CONFIG"
else
    echo "[INFO] Creating default logrotate configuration"

    # Create default logrotate configuration
    cat > "$LOGROTATE_CONFIG" << EOF
# Log rotation for $SITE_NAME

# Site logs
$DEPLOY_DIR/logs/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 $SITE_NAME $SITE_NAME
    sharedscripts
    postrotate
        # Reload services if needed
        # systemctl reload $SITE_NAME || true
    endscript
}

# Nginx logs (if present)
$DEPLOY_DIR/nginx/logs/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 $SITE_NAME $SITE_NAME
    sharedscripts
    postrotate
        # Reload nginx if present
        docker compose -f $DEPLOY_DIR/docker-compose*.yml exec -T nginx nginx -s reload 2>/dev/null || true
    endscript
}

# Application logs in /var/log
/var/log/$SITE_NAME/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 $SITE_NAME $SITE_NAME
}
EOF
fi

# Set proper permissions on logrotate config
chmod 644 "$LOGROTATE_CONFIG"

echo "[INFO] Logrotate configuration created: $LOGROTATE_CONFIG"

# Test the configuration
if logrotate -d "$LOGROTATE_CONFIG" 2>&1 | grep -i error; then
    echo "[WARN] Logrotate configuration test found issues (see above)"
else
    echo "[INFO] Logrotate configuration test passed"
fi

echo "[INFO] Log rotation setup complete for $SITE_NAME"
