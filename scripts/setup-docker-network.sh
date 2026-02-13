#!/bin/bash

#############################################
# Setup Isolated Docker Network for Site
#
# Creates a dedicated Docker network for each site
# Enables complete isolation between sites
# Only boundary Nginx can route between sites
#
# Usage: ./setup-docker-network.sh <site_name>
#############################################

set -e

SITE_NAME="$1"

if [ -z "$SITE_NAME" ]; then
    echo "[ERROR] Usage: $0 <site_name>"
    exit 1
fi

NETWORK_NAME="${SITE_NAME}-network"

echo "[INFO] Setting up isolated Docker network for $SITE_NAME..."

# Check if network already exists
if docker network ls | grep -q "$NETWORK_NAME"; then
    echo "[INFO] Network $NETWORK_NAME already exists"
    docker network inspect "$NETWORK_NAME"
    exit 0
fi

# Create isolated bridge network for the site
docker network create \
    --driver bridge \
    --subnet "172.$(shuf -i 16-31 -n 1).$(shuf -i 0-255 -n 1).0/24" \
    --opt "com.docker.network.bridge.name=br-${SITE_NAME}" \
    --opt "com.docker.network.bridge.enable_icc=false" \
    --opt "com.docker.network.bridge.enable_ip_masquerade=true" \
    --opt "com.docker.network.driver.mtu=1500" \
    --label "site=$SITE_NAME" \
    --label "managed-by=dockerHosting" \
    "$NETWORK_NAME"

echo "[INFO] Created isolated Docker network: $NETWORK_NAME"

# Display network information
echo ""
echo "[INFO] Network details:"
docker network inspect "$NETWORK_NAME" | jq '.[0] | {Name, Id, Driver, Subnet: .IPAM.Config[0].Subnet, Options, Labels}'

echo ""
echo "[INFO] ════════════════════════════════════════════"
echo "[INFO] Docker Network Setup Complete!"
echo "[INFO] ════════════════════════════════════════════"
echo ""
echo "[INFO] Network: $NETWORK_NAME"
echo "  Isolation: Complete (no inter-container communication with other sites)"
echo "  Access: Only via host network (boundary Nginx)"
echo ""
echo "[INFO] Docker Compose configuration:"
echo "  Add to your docker-compose.yml:"
echo ""
echo "  networks:"
echo "    default:"
echo "      name: $NETWORK_NAME"
echo "      external: true"
echo ""
echo "[INFO] This ensures all containers use the isolated network"
echo ""
