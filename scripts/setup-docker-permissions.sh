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

# Helper: traefik-status
cat > "$HELPERS_DIR/traefik-status" <<'SCRIPT_EOF'
#!/bin/bash
echo "[INFO] Traefik container status:"
sudo docker ps --filter "name=^traefik$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo "[INFO] Active routes (requires curl on localhost):"
curl -sf http://127.0.0.1:8080/api/http/routers 2>/dev/null \
    | grep -oP '"name":"\K[^"]+' \
    | sed 's/^/  /' \
    || echo "  (Traefik API not reachable)"
SCRIPT_EOF

# Make all helper scripts executable
chmod +x "$HELPERS_DIR"/docker-*
chmod +x "$HELPERS_DIR"/traefik-*

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
- `./docker-up` - Start all services
- `./docker-down` - Stop all services
- `./docker-restart [service]` - Restart services
- `./docker-logs [service]` - View logs
- `./docker-ps` - List running containers
- `./docker-pull` - Pull latest images
- `./docker-exec <service> [command]` - Execute command in container

### Traefik Operations
- `./traefik-status` - Check Traefik container status and active routes

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

## Traefik Routing

After deploying, add a Traefik route using the domain and port from your .env:

```bash
sudo /opt/dockerHosting/scripts/add-traefik-site.sh <domain> <port>
```

To remove a route:

```bash
sudo /opt/dockerHosting/scripts/remove-traefik-site.sh <domain>
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
echo "  docker-ps, docker-pull, docker-exec, traefik-status"
echo ""
echo "[WARN] User is NOT in docker group (no root-equivalent access)"
echo "[INFO] All Docker operations require sudo with restricted permissions"
echo ""
