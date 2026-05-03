#!/bin/bash
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#############################################
# Install Google Cloud CLI (gsutil)
# Required for GCS artifact downloads by
# deploy-site.sh and site update.sh scripts.
#############################################

set -e

FORCE=false
for arg in "$@"; do [[ "$arg" == "--force" ]] && FORCE=true; done

if [[ "$FORCE" == false ]] && command -v gsutil &>/dev/null; then
    echo "[INFO] Google Cloud CLI (gsutil) is already installed — skipping (use --force to reinstall)"
    gsutil version
    exit 0
fi

echo "[INFO] Installing Google Cloud CLI..."

# Prerequisites
apt-get install -y apt-transport-https ca-certificates gnupg curl

# Add Google Cloud signing key
install -m 0755 -d /usr/share/keyrings
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
chmod a+r /usr/share/keyrings/cloud.google.gpg

# Add the repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/cloud.google.gpg] \
https://packages.cloud.google.com/apt cloud-sdk main" \
    | tee /etc/apt/sources.list.d/google-cloud-sdk.list > /dev/null

# Install (CLI only — no SDK extras needed)
apt-get update
apt-get install -y google-cloud-cli

echo "[INFO] Google Cloud CLI installed"
gsutil version
