#!/bin/bash

#############################################
# SSL/TLS Certificate Setup
#
# Generates self-signed certificates for initial setup
# Can be upgraded to Let's Encrypt certificates later
#
# Usage: ./setup-ssl.sh <site_name> <hostname> [--letsencrypt]
#############################################

set -e

SITE_NAME="$1"
HOSTNAME="$2"
USE_LETSENCRYPT="$3"

if [ -z "$SITE_NAME" ] || [ -z "$HOSTNAME" ]; then
    echo "[ERROR] Usage: $0 <site_name> <hostname> [--letsencrypt]"
    exit 1
fi

# Certificate directories
CERT_DIR="/etc/ssl/dockerhosting"
SITE_CERT_DIR="$CERT_DIR/$SITE_NAME"

echo "[INFO] Setting up SSL certificates for $SITE_NAME ($HOSTNAME)..."

# Create certificate directory
mkdir -p "$SITE_CERT_DIR"

if [ "$USE_LETSENCRYPT" == "--letsencrypt" ]; then
    #############################################
    # Let's Encrypt (Production) Certificate
    #############################################
    echo "[INFO] Generating Let's Encrypt certificate..."

    # Check if certbot is installed
    if ! command -v certbot &> /dev/null; then
        echo "[ERROR] certbot is not installed"
        exit 1
    fi

    # Check if port 80 is accessible
    echo "[WARN] Ensure port 80 is accessible from the internet for Let's Encrypt validation"
    read -p "Continue with Let's Encrypt? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "[INFO] Cancelled"
        exit 0
    fi

    # Run certbot in standalone mode
    certbot certonly --standalone \
        --non-interactive \
        --agree-tos \
        --email admin@$HOSTNAME \
        --domains $HOSTNAME \
        --cert-name $SITE_NAME

    # Create symlinks in our cert directory
    ln -sf /etc/letsencrypt/live/$SITE_NAME/fullchain.pem "$SITE_CERT_DIR/fullchain.pem"
    ln -sf /etc/letsencrypt/live/$SITE_NAME/privkey.pem "$SITE_CERT_DIR/privkey.pem"
    ln -sf /etc/letsencrypt/live/$SITE_NAME/chain.pem "$SITE_CERT_DIR/chain.pem"

    echo "[INFO] Let's Encrypt certificate installed"
    echo "[INFO] Certificate location: /etc/letsencrypt/live/$SITE_NAME/"
    echo "[INFO] Symlinks created in: $SITE_CERT_DIR"

    # Setup automatic renewal
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        echo "[INFO] Setting up automatic certificate renewal..."
        (crontab -l 2>/dev/null || true; echo "0 3 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
        echo "[INFO] Added renewal cron job (runs daily at 3 AM)"
    fi

else
    #############################################
    # Self-Signed Certificate (Development)
    #############################################
    echo "[INFO] Generating self-signed certificate..."

    # Check if certificates already exist
    if [ -f "$SITE_CERT_DIR/fullchain.pem" ] && [ -f "$SITE_CERT_DIR/privkey.pem" ]; then
        echo "[WARN] Certificates already exist for $SITE_NAME"
        read -p "Regenerate certificates? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "[INFO] Using existing certificates"
            exit 0
        fi
    fi

    # Generate private key
    openssl genrsa -out "$SITE_CERT_DIR/privkey.pem" 2048
    chmod 600 "$SITE_CERT_DIR/privkey.pem"

    # Generate self-signed certificate (valid for 365 days)
    openssl req -new -x509 -key "$SITE_CERT_DIR/privkey.pem" \
        -out "$SITE_CERT_DIR/fullchain.pem" \
        -days 365 \
        -subj "/C=US/ST=State/L=City/O=Organization/OU=IT/CN=$HOSTNAME" \
        -addext "subjectAltName = DNS:$HOSTNAME,DNS:*.$HOSTNAME"

    chmod 644 "$SITE_CERT_DIR/fullchain.pem"

    # Create chain.pem (same as fullchain for self-signed)
    cp "$SITE_CERT_DIR/fullchain.pem" "$SITE_CERT_DIR/chain.pem"

    echo "[INFO] Self-signed certificate generated"
    echo "[INFO] Certificate location: $SITE_CERT_DIR"
    echo "[WARN] This is a self-signed certificate - browsers will show security warnings"
fi

# Verify certificates
echo ""
echo "[INFO] Verifying certificate..."
openssl x509 -in "$SITE_CERT_DIR/fullchain.pem" -noout -subject -dates

# Set proper ownership
chown -R root:root "$SITE_CERT_DIR"

echo ""
echo "[INFO] ════════════════════════════════════════════"
echo "[INFO] SSL Certificate Setup Complete!"
echo "[INFO] ════════════════════════════════════════════"
echo ""
echo "[INFO] Certificate files:"
echo "  Certificate: $SITE_CERT_DIR/fullchain.pem"
echo "  Private Key: $SITE_CERT_DIR/privkey.pem"
echo "  Chain: $SITE_CERT_DIR/chain.pem"
echo ""

if [ "$USE_LETSENCRYPT" != "--letsencrypt" ]; then
    echo "[INFO] To upgrade to Let's Encrypt certificate:"
    echo "  sudo $0 $SITE_NAME $HOSTNAME --letsencrypt"
    echo ""
    echo "[WARN] Self-signed certificates are for development only"
    echo "[WARN] Use Let's Encrypt for production"
fi

echo ""
