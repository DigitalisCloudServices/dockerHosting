#!/bin/bash

#############################################
# Configure Boundary Nginx for a Site
#
# Reads site's .env file and generates boundary Nginx config
# that routes traffic from hostname to Docker-managed site Nginx
#
# Usage: ./configure-nginx-site.sh <site_name> <deploy_dir>
#############################################

set -e

SITE_NAME="$1"
DEPLOY_DIR="$2"

if [ -z "$SITE_NAME" ] || [ -z "$DEPLOY_DIR" ]; then
    echo "[ERROR] Usage: $0 <site_name> <deploy_dir>"
    exit 1
fi

echo "[INFO] Configuring boundary Nginx for $SITE_NAME..."

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$(dirname "$SCRIPT_DIR")/templates"

# Check if template exists
if [ ! -f "$TEMPLATE_DIR/nginx-boundary-site.conf.template" ]; then
    echo "[ERROR] Template not found: $TEMPLATE_DIR/nginx-boundary-site.conf.template"
    exit 1
fi

# Check if .env file exists
ENV_FILE="$DEPLOY_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "[ERROR] .env file not found: $ENV_FILE"
    echo "[INFO] Please create .env file with SITE_HOSTNAME and SITE_PORT variables"
    exit 1
fi

# Source the .env file to read variables
set -a  # automatically export all variables
source "$ENV_FILE"
set +a

# Check required variables
if [ -z "$SITE_HOSTNAME" ]; then
    echo "[ERROR] SITE_HOSTNAME not defined in $ENV_FILE"
    echo "[INFO] Add: SITE_HOSTNAME=yourdomain.com"
    exit 1
fi

if [ -z "$SITE_PORT" ]; then
    echo "[ERROR] SITE_PORT not defined in $ENV_FILE"
    echo "[INFO] Add: SITE_PORT=3001 (or your chosen port)"
    exit 1
fi

echo "[INFO] Configuration:"
echo "  Site Name: $SITE_NAME"
echo "  Hostname: $SITE_HOSTNAME"
echo "  Backend Port: $SITE_PORT"

# Setup SSL certificates (self-signed by default)
if [ -f "$SCRIPT_DIR/setup-ssl.sh" ]; then
    echo "[INFO] Setting up SSL certificates..."
    bash "$SCRIPT_DIR/setup-ssl.sh" "$SITE_NAME" "$SITE_HOSTNAME"
else
    echo "[WARN] setup-ssl.sh not found, skipping SSL setup"
fi

# Create Nginx config from template
NGINX_CONFIG="/etc/nginx/sites-available/$SITE_NAME"

sed -e "s|{{SITE_NAME}}|$SITE_NAME|g" \
    -e "s|{{SITE_HOSTNAME}}|$SITE_HOSTNAME|g" \
    -e "s|{{SITE_PORT}}|$SITE_PORT|g" \
    "$TEMPLATE_DIR/nginx-boundary-site.conf.template" > "$NGINX_CONFIG"

echo "[INFO] Created Nginx config: $NGINX_CONFIG"

# Enable the site by creating symlink
NGINX_ENABLED="/etc/nginx/sites-enabled/$SITE_NAME"
ln -sf "$NGINX_CONFIG" "$NGINX_ENABLED"
echo "[INFO] Enabled site: $NGINX_ENABLED"

# Test Nginx configuration
echo "[INFO] Testing Nginx configuration..."
if nginx -t 2>&1; then
    echo "[INFO] Nginx configuration test passed"
else
    echo "[ERROR] Nginx configuration test failed!"
    echo "[ERROR] Removing invalid configuration..."
    rm -f "$NGINX_ENABLED"
    exit 1
fi

# Reload Nginx to apply changes
echo "[INFO] Reloading Nginx..."
systemctl reload nginx

echo ""
echo "[INFO] ════════════════════════════════════════════"
echo "[INFO] Boundary Nginx Configuration Complete!"
echo "[INFO] ════════════════════════════════════════════"
echo ""
echo "[INFO] Site $SITE_NAME is now configured:"
echo "  Hostname: $SITE_HOSTNAME"
echo "  Routes to: localhost:$SITE_PORT (Docker-managed Nginx)"
echo ""
echo "[INFO] Nginx configuration:"
echo "  Config file: $NGINX_CONFIG"
echo "  Enabled: $NGINX_ENABLED"
echo "  Logs: /var/log/nginx/$SITE_NAME-*.log"
echo ""
echo "[INFO] SSL Configuration:"
echo "  Certificates: /etc/ssl/dockerhosting/$SITE_NAME/"
echo "  Type: Self-signed (development)"
echo "  HTTPS: Enabled (with browser warnings)"
echo ""
echo "[INFO] Test the configuration:"
echo "  curl -k https://$SITE_HOSTNAME/ (if DNS is configured)"
echo "  curl -H 'Host: $SITE_HOSTNAME' -k https://localhost/"
echo ""
echo "[WARN] Remember to:"
echo "  1. Configure your Docker Compose to expose Nginx on port $SITE_PORT"
echo "  2. Update DNS to point $SITE_HOSTNAME to this server"
echo "  3. Upgrade to Let's Encrypt for production:"
echo "     sudo $SCRIPT_DIR/setup-ssl.sh $SITE_NAME $SITE_HOSTNAME --letsencrypt"
echo ""
echo "[INFO] Self-signed certificates will cause browser warnings"
echo "[INFO] Use Let's Encrypt for production to avoid warnings"
echo ""
