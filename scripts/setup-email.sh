#!/bin/bash

#############################################
# Setup Email Notifications
#
# Configures msmtp as a lightweight MTA to relay
# system emails through a smarthost
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

echo ""
echo "╔═══════════════════════════════════════════════╗"
echo "║   Email Notification Setup                    ║"
echo "╚═══════════════════════════════════════════════╝"
echo ""

# Prompt for email configuration
echo "Configure system email notifications (for alerts, cron jobs, security notifications)"
echo ""

read -p "Email address to receive root/system emails: " ROOT_EMAIL
if [ -z "$ROOT_EMAIL" ]; then
    log_error "Email address is required"
    exit 1
fi

read -p "SMTP server (smarthost) [e.g., smtp.gmail.com]: " SMTP_HOST
if [ -z "$SMTP_HOST" ]; then
    log_error "SMTP server is required"
    exit 1
fi

read -p "SMTP port [587]: " SMTP_PORT
SMTP_PORT=${SMTP_PORT:-587}

read -p "SMTP username: " SMTP_USER
if [ -z "$SMTP_USER" ]; then
    log_error "SMTP username is required"
    exit 1
fi

read -sp "SMTP password: " SMTP_PASS
echo ""
if [ -z "$SMTP_PASS" ]; then
    log_error "SMTP password is required"
    exit 1
fi

read -p "From address [${SMTP_USER}]: " FROM_ADDRESS
FROM_ADDRESS=${FROM_ADDRESS:-$SMTP_USER}

read -p "Use TLS? (Y/n): " USE_TLS
if [[ ! $USE_TLS =~ ^[Nn]$ ]]; then
    TLS_ON="on"
else
    TLS_ON="off"
fi

# Install msmtp and related packages
log_info "Installing msmtp and mailutils..."
apt-get update
apt-get install -y msmtp msmtp-mta mailutils bsd-mailx

# Create msmtp configuration
log_info "Configuring msmtp..."
cat > /etc/msmtprc <<EOF
# msmtp system-wide configuration
# Created by dockerHosting setup

# Set default values for all accounts
defaults
auth           on
tls            ${TLS_ON}
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

# Default account
account        default
host           ${SMTP_HOST}
port           ${SMTP_PORT}
from           ${FROM_ADDRESS}
user           ${SMTP_USER}
password       ${SMTP_PASS}

# Set default account
account default : default
EOF

# Secure the configuration file (contains password)
chmod 600 /etc/msmtprc
chown root:root /etc/msmtprc

log_info "msmtp configuration secured (600 root:root)"

# Create log file
touch /var/log/msmtp.log
chmod 660 /var/log/msmtp.log
chown root:msmtp /var/log/msmtp.log 2>/dev/null || chown root:root /var/log/msmtp.log

# Configure mail aliases to forward root mail
log_info "Configuring mail aliases..."
cat > /etc/aliases <<EOF
# Mail aliases
# Forward all root emails to configured address
root: ${ROOT_EMAIL}
default: ${ROOT_EMAIL}

# Forward other system accounts to root
postmaster: root
abuse: root
nobody: root
EOF

# Set msmtp as the default MTA
log_info "Setting msmtp as default MTA..."
ln -sf /usr/bin/msmtp /usr/sbin/sendmail
ln -sf /usr/bin/msmtp /usr/bin/sendmail

# Configure log rotation for msmtp
log_info "Configuring log rotation..."
cat > /etc/logrotate.d/msmtp <<'LOGEOF'
/var/log/msmtp.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 660 root root
    postrotate
        # No need to restart anything, msmtp reopens log on each send
    endscript
}
LOGEOF

# Test email configuration
log_info "Testing email configuration..."
echo "This is a test email from your dockerHosting server at $(hostname)" | \
    mail -s "Test Email from $(hostname)" "$ROOT_EMAIL" || {
    log_warn "Test email may have failed. Check /var/log/msmtp.log"
}

echo ""
log_info "════════════════════════════════════════════"
log_info "Email Configuration Complete!"
log_info "════════════════════════════════════════════"
echo ""
log_info "Configuration:"
echo "  - SMTP Server: ${SMTP_HOST}:${SMTP_PORT}"
echo "  - From Address: ${FROM_ADDRESS}"
echo "  - Root emails forwarded to: ${ROOT_EMAIL}"
echo "  - Configuration: /etc/msmtprc"
echo "  - Log file: /var/log/msmtp.log"
echo ""
log_info "Test email sent to: ${ROOT_EMAIL}"
log_warn "Check your inbox (and spam folder) for the test email"
echo ""
log_info "System notifications will now be sent to: ${ROOT_EMAIL}"
echo ""
