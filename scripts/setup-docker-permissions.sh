#!/bin/bash

#############################################
# Setup Docker Permissions for Site User
#
# Creates sudo rules allowing controlled Docker operations
# without granting root-equivalent docker group access
#
# Usage: ./setup-docker-permissions.sh <site_user> <deploy_dir>
#############################################

set -e

SITE_USER="$1"
DEPLOY_DIR="$2"

if [ -z "$SITE_USER" ] || [ -z "$DEPLOY_DIR" ]; then
    echo "[ERROR] Usage: $0 <site_user> <deploy_dir>"
    exit 1
fi

echo "[INFO] Setting up Docker permissions for $SITE_USER..."

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$(dirname "$SCRIPT_DIR")/templates"

# Check if template exists
if [ ! -f "$TEMPLATE_DIR/docker-sudoers.template" ]; then
    echo "[ERROR] Template not found: $TEMPLATE_DIR/docker-sudoers.template"
    exit 1
fi

# Create sudoers file from template
SUDOERS_FILE="/etc/sudoers.d/docker-$SITE_USER"

# Replace placeholders in template
sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
    -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
    "$TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"

# Set proper permissions for sudoers file
chmod 0440 "$SUDOERS_FILE"
chown root:root "$SUDOERS_FILE"

echo "[INFO] Created sudoers file: $SUDOERS_FILE"

# Validate sudoers file
if visudo -c -f "$SUDOERS_FILE"; then
    echo "[INFO] Sudoers file validation passed"
else
    echo "[ERROR] Sudoers file validation failed!"
    rm -f "$SUDOERS_FILE"
    exit 1
fi

# Create helper scripts in user's deployment directory
HELPERS_DIR="$DEPLOY_DIR/bin"
mkdir -p "$HELPERS_DIR"

# Helper: docker-up
cat > "$HELPERS_DIR/docker-up" <<'SCRIPT_EOF'
#!/bin/bash
set -e
cd "$(dirname "$0")/.."
echo "[INFO] Starting Docker Compose services..."
sudo docker compose up -d "$@"
echo "[INFO] Services started successfully"
echo "[INFO] Testing boundary Nginx configuration..."
if sudo nginx -t 2>&1; then
    echo "[INFO] Reloading boundary Nginx..."
    sudo systemctl reload nginx
    echo "[INFO] Done!"
else
    echo "[ERROR] Nginx configuration test failed!"
    exit 1
fi
SCRIPT_EOF

# Helper: docker-down
cat > "$HELPERS_DIR/docker-down" <<'SCRIPT_EOF'
#!/bin/bash
set -e
cd "$(dirname "$0")/.."
echo "[INFO] Stopping Docker Compose services..."
sudo docker compose down "$@"
echo "[INFO] Services stopped successfully"
SCRIPT_EOF

# Helper: docker-restart
cat > "$HELPERS_DIR/docker-restart" <<'SCRIPT_EOF'
#!/bin/bash
set -e
cd "$(dirname "$0")/.."
echo "[INFO] Restarting Docker Compose services..."
sudo docker compose restart "$@"
echo "[INFO] Services restarted successfully"
SCRIPT_EOF

# Helper: docker-logs
cat > "$HELPERS_DIR/docker-logs" <<'SCRIPT_EOF'
#!/bin/bash
cd "$(dirname "$0")/.."
sudo docker compose logs "$@"
SCRIPT_EOF

# Helper: docker-ps
cat > "$HELPERS_DIR/docker-ps" <<'SCRIPT_EOF'
#!/bin/bash
cd "$(dirname "$0")/.."
sudo docker compose ps "$@"
SCRIPT_EOF

# Helper: docker-pull
cat > "$HELPERS_DIR/docker-pull" <<'SCRIPT_EOF'
#!/bin/bash
set -e
cd "$(dirname "$0")/.."
echo "[INFO] Pulling latest images..."
sudo docker compose pull "$@"
echo "[INFO] Images pulled successfully"
SCRIPT_EOF

# Helper: docker-exec
cat > "$HELPERS_DIR/docker-exec" <<'SCRIPT_EOF'
#!/bin/bash
cd "$(dirname "$0")/.."
if [ -z "$1" ]; then
    echo "Usage: docker-exec <service> [command]"
    echo "Example: docker-exec web bash"
    exit 1
fi
sudo docker compose exec "$@"
SCRIPT_EOF

# Helper: nginx-reload
cat > "$HELPERS_DIR/nginx-reload" <<'SCRIPT_EOF'
#!/bin/bash
set -e
echo "[INFO] Testing boundary Nginx configuration..."
if sudo nginx -t 2>&1; then
    echo "[INFO] Reloading boundary Nginx..."
    sudo systemctl reload nginx
    echo "[INFO] Nginx reloaded successfully"
else
    echo "[ERROR] Nginx configuration test failed!"
    exit 1
fi
SCRIPT_EOF

# Helper: nginx-status
cat > "$HELPERS_DIR/nginx-status" <<'SCRIPT_EOF'
#!/bin/bash
sudo systemctl status nginx
SCRIPT_EOF

# Make all helper scripts executable
chmod +x "$HELPERS_DIR"/docker-*
chmod +x "$HELPERS_DIR"/nginx-*

# Set ownership to site user
chown -R "$SITE_USER:$SITE_USER" "$HELPERS_DIR"

echo "[INFO] Created helper scripts in $HELPERS_DIR"

# Create README for helper scripts
cat > "$HELPERS_DIR/README.md" <<'README_EOF'
# Docker Helper Scripts

These scripts provide convenient access to Docker Compose operations
with proper permissions (via sudo).

## Available Commands

### Docker Operations
- `./docker-up` - Start all services (and reload nginx)
- `./docker-down` - Stop all services
- `./docker-restart [service]` - Restart services
- `./docker-logs [service]` - View logs
- `./docker-ps` - List running containers
- `./docker-pull` - Pull latest images
- `./docker-exec <service> [command]` - Execute command in container

### Nginx Operations
- `./nginx-reload` - Test and reload boundary Nginx
- `./nginx-status` - Check Nginx status

## Examples

```bash
# Start all services
./bin/docker-up

# Start specific service
./bin/docker-up web

# View logs (follow mode)
./bin/docker-logs -f

# View logs for specific service
./bin/docker-logs web

# Execute bash in web container
./bin/docker-exec web bash

# Pull latest images and restart
./bin/docker-pull
./bin/docker-restart
```

## Direct Docker Compose

You can also use docker compose directly with sudo:

```bash
sudo docker compose up -d
sudo docker compose logs -f web
sudo docker compose exec web bash
```

## Boundary Nginx

After making changes to your site's .env or docker-compose.yml that affect
the exposed port or hostname, regenerate the boundary Nginx config and reload:

```bash
# This is typically done by the deployment script, but can be done manually:
sudo /opt/dockerHosting/scripts/configure-nginx-site.sh <site_name> <deploy_dir>
./bin/nginx-reload
```
README_EOF

chown "$SITE_USER:$SITE_USER" "$HELPERS_DIR/README.md"

echo "[INFO] Created helper scripts documentation"

echo ""
echo "[INFO] ════════════════════════════════════════════"
echo "[INFO] Docker Permissions Setup Complete!"
echo "[INFO] ════════════════════════════════════════════"
echo ""
echo "[INFO] User $SITE_USER can now:"
echo "  - Manage Docker Compose in: $DEPLOY_DIR"
echo "  - Reload boundary Nginx"
echo "  - Use helper scripts in: $HELPERS_DIR"
echo ""
echo "[INFO] Helper scripts available:"
echo "  docker-up, docker-down, docker-restart, docker-logs,"
echo "  docker-ps, docker-pull, docker-exec, nginx-reload, nginx-status"
echo ""
echo "[WARN] User is NOT in docker group (no root-equivalent access)"
echo "[INFO] All Docker operations require sudo with restricted permissions"
echo ""
