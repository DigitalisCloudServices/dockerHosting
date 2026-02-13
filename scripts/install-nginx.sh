#!/bin/bash

#############################################
# Install and Configure Boundary Nginx
#
# Sets up system-level Nginx as a reverse proxy
# Routes traffic by hostname to Docker-managed site Nginx instances
#############################################

set -e

echo "[INFO] Installing and configuring boundary Nginx..."

# Install Nginx if not present
if ! command -v nginx &> /dev/null; then
    echo "[INFO] Installing nginx..."
    apt-get update
    apt-get install -y nginx
fi

# Stop Nginx during configuration
systemctl stop nginx

# Backup original nginx.conf if it exists
if [ -f /etc/nginx/nginx.conf ] && [ ! -f /etc/nginx/nginx.conf.backup ]; then
    cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup
    echo "[INFO] Backed up original nginx.conf"
fi

# Create directory structure
mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/sites-enabled
mkdir -p /var/log/nginx

# Create optimized nginx.conf for boundary/routing
cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 2048;
    use epoll;
    multi_accept on;
}

http {
    ##
    # Basic Settings
    ##
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    # Server names hash bucket size
    server_names_hash_bucket_size 64;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ##
    # SSL Settings (will be configured per-site)
    ##
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';

    ##
    # Logging Settings
    ##
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    ##
    # Gzip Settings
    ##
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss application/rss+xml font/truetype font/opentype application/vnd.ms-fontobject image/svg+xml;
    gzip_disable "msie6";

    ##
    # Proxy Settings (for Docker backends)
    ##
    proxy_buffering on;
    proxy_buffer_size 4k;
    proxy_buffers 8 4k;
    proxy_busy_buffers_size 8k;

    # Timeouts
    proxy_connect_timeout 60s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;

    # Headers
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Port $server_port;

    # WebSocket support
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";

    ##
    # Client Settings
    ##
    client_max_body_size 100M;
    client_body_timeout 60s;
    client_header_timeout 60s;

    ##
    # Rate Limiting
    ##
    limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;
    limit_req_status 429;

    ##
    # Default Server (catch-all for undefined hosts)
    ##
    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name _;

        return 444;  # Close connection without response
    }

    ##
    # Virtual Host Configs (per-site configurations)
    ##
    include /etc/nginx/sites-enabled/*;
}
EOF

echo "[INFO] Created boundary nginx.conf"

# Create a simple health check endpoint
cat > /etc/nginx/sites-available/health-check <<'EOF'
server {
    listen 80;
    server_name localhost;

    location /nginx-health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF

# Enable health check
ln -sf /etc/nginx/sites-available/health-check /etc/nginx/sites-enabled/health-check

echo "[INFO] Created health check endpoint at http://localhost/nginx-health"

# Test Nginx configuration
echo "[INFO] Testing Nginx configuration..."
if nginx -t; then
    echo "[INFO] Nginx configuration test passed"
else
    echo "[ERROR] Nginx configuration test failed!"
    exit 1
fi

# Enable and start Nginx
systemctl enable nginx
systemctl start nginx

# Verify Nginx is running
if systemctl is-active --quiet nginx; then
    echo "[INFO] Nginx service is running"
else
    echo "[ERROR] Nginx service failed to start!"
    exit 1
fi

# Configure log rotation for Nginx
cat > /etc/logrotate.d/nginx-boundary <<'EOF'
/var/log/nginx/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 www-data adm
    sharedscripts
    prerotate
        if [ -d /etc/logrotate.d/httpd-prerotate ]; then \
            run-parts /etc/logrotate.d/httpd-prerotate; \
        fi
    endscript
    postrotate
        invoke-rc.d nginx rotate >/dev/null 2>&1
    endscript
}
EOF

echo "[INFO] Configured log rotation for Nginx"

echo ""
echo "[INFO] ════════════════════════════════════════════"
echo "[INFO] Boundary Nginx Installation Complete!"
echo "[INFO] ════════════════════════════════════════════"
echo ""
echo "[INFO] Nginx is now running as a boundary/routing layer"
echo "[INFO] Configuration:"
echo "  - Main config: /etc/nginx/nginx.conf"
echo "  - Site configs: /etc/nginx/sites-available/"
echo "  - Enabled sites: /etc/nginx/sites-enabled/"
echo "  - Logs: /var/log/nginx/"
echo ""
echo "[INFO] Health check: curl http://localhost/nginx-health"
echo ""
echo "[INFO] To add a new site:"
echo "  1. Create config in /etc/nginx/sites-available/site-name"
echo "  2. Symlink to /etc/nginx/sites-enabled/site-name"
echo "  3. Test: nginx -t"
echo "  4. Reload: systemctl reload nginx"
echo ""
