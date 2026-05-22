#!/bin/bash
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#############################################
# Setup Isolated Docker Network for Site
#
# Creates a dedicated Docker network for each site
# Enables complete isolation between sites
# Only boundary Traefik can route between sites
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
# Linux interface names are limited to 15 chars (IFNAMSIZ=16 incl. null).
# Use a deterministic MD5-based suffix so sites with similar names don't collide.
# br- (3) + 12 hex chars = 15 chars exactly.
BRIDGE_HASH="$(echo -n "${SITE_NAME}" | md5sum | cut -c1-12)"
BRIDGE_NAME="br-${BRIDGE_HASH}"

REGISTRY_DIR="/opt/setup/networking"
REGISTRY_FILE="${REGISTRY_DIR}/${SITE_NAME}"

echo "[INFO] Setting up isolated Docker network for $SITE_NAME..."

# Check if network already exists
if docker network ls | grep -q "$NETWORK_NAME"; then
    echo "[INFO] Network $NETWORK_NAME already exists"
    docker network inspect "$NETWORK_NAME"
    exit 0
fi

# Find a free /24 subnet using Python's ipaddress module for proper overlap detection.
# Uses 192.168.100.0/24 – 192.168.254.0/24 (outside Docker's default 172.17-31 pool and
# well above the common home/office LAN ranges 192.168.0-10.x).
# Start offset is deterministic from site name so the same site always tries the same
# subnet first, reducing churn on re-deploys.
SELECTED_SUBNET="$(
    python3 - "$SITE_NAME" << 'PYEOF'
import sys, subprocess, json, hashlib
from ipaddress import ip_network

site_name = sys.argv[1]

# Collect all subnets currently in use by any Docker network
result = subprocess.run(['docker', 'network', 'ls', '-q'], capture_output=True, text=True)
net_ids = result.stdout.strip().split()
existing = []
for nid in net_ids:
    r = subprocess.run(['docker', 'network', 'inspect', nid], capture_output=True, text=True)
    try:
        for net in json.loads(r.stdout):
            for cfg in net.get('IPAM', {}).get('Config', []):
                s = cfg.get('Subnet')
                if s:
                    try:
                        existing.append(ip_network(s, strict=False))
                    except ValueError:
                        pass
    except (json.JSONDecodeError, KeyError, TypeError):
        pass

# Deterministic start index: 0–154, based on site name hash
start = int(hashlib.md5(site_name.encode()).hexdigest()[:2], 16) % 155  # 0..154

for i in range(155):
    third_octet = (start + i) % 155 + 100  # 100..254
    candidate = ip_network(f'192.168.{third_octet}.0/24')
    if not any(candidate.overlaps(e) for e in existing):
        print(f'192.168.{third_octet}.0/24')
        sys.exit(0)

print('[ERROR] No free subnet found in 192.168.100-254.0/24 — all 155 candidates overlap existing networks', file=sys.stderr)
sys.exit(1)
PYEOF
)"

if [ -z "$SELECTED_SUBNET" ]; then
    echo "[ERROR] Failed to select a free subnet"
    exit 1
fi

echo "[INFO] Selected subnet: $SELECTED_SUBNET (verified free via ipaddress overlap check)"

# Create isolated bridge network for the site
docker network create \
    --driver bridge \
    --subnet "$SELECTED_SUBNET" \
    --opt "com.docker.network.bridge.name=${BRIDGE_NAME}" \
    --opt "com.docker.network.bridge.enable_icc=false" \
    --opt "com.docker.network.bridge.enable_ip_masquerade=true" \
    --opt "com.docker.network.driver.mtu=1500" \
    --label "site=$SITE_NAME" \
    --label "managed-by=dockerHosting" \
    "$NETWORK_NAME"

echo "[INFO] Created isolated Docker network: $NETWORK_NAME"

# Record the bridge mapping so the hash is always reversible
mkdir -p "${REGISTRY_DIR}"
cat > "${REGISTRY_FILE}" << EOF
site_name=${SITE_NAME}
network_name=${NETWORK_NAME}
bridge_name=${BRIDGE_NAME}
subnet=${SELECTED_SUBNET}
bridge_hash=${BRIDGE_HASH}
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 644 "${REGISTRY_FILE}"
echo "[INFO] Network registry: ${REGISTRY_FILE}"

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
echo "  Access: Only via host network (boundary Traefik)"
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
