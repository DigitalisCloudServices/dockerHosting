#!/bin/bash
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#############################################
# Container Image Vulnerability Scanner (Trivy) + Signature Verifier (Cosign)
#
# Scans one or more Docker images for known CVEs before deployment.
# Exits non-zero if CRITICAL vulnerabilities are found (configurable).
# Optionally verifies image signatures via Cosign (Sigstore keyless or key-based).
#
# Usage:
#   scan-image.sh <image>[:<tag>] [<image2> ...]
#   scan-image.sh --compose <docker-compose.yml>
#
# Options:
#   --severity LEVEL         Comma-separated list of severities to fail on
#                            Default: CRITICAL
#                            Example: --severity CRITICAL,HIGH
#   --ignore-unfixed         Skip vulnerabilities with no fix available
#   --no-fail                Report findings but always exit 0 (audit mode)
#   --verify-signature       Verify each image has a valid Cosign signature
#   --cosign-key <path>      Path to Cosign public key (PEM). Omit to use
#                            keyless Sigstore OIDC verification instead.
#
# Based on: CIS Docker Benchmark 4.1–4.6, ISO 27001 A.8.8, NIS2 supply chain
#############################################

set -euo pipefail

SEVERITY="CRITICAL"
IGNORE_UNFIXED=false
NO_FAIL=false
COMPOSE_FILE=""
VERIFY_SIGNATURE=false
COSIGN_KEY=""
IMAGES=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --severity)          SEVERITY="$2"; shift 2 ;;
        --ignore-unfixed)    IGNORE_UNFIXED=true; shift ;;
        --no-fail)           NO_FAIL=true; shift ;;
        --compose)           COMPOSE_FILE="$2"; shift 2 ;;
        --verify-signature)  VERIFY_SIGNATURE=true; shift ;;
        --cosign-key)        COSIGN_KEY="$2"; shift 2 ;;
        -*)                  echo "[ERROR] Unknown option: $1"; exit 1 ;;
        *)                   IMAGES+=("$1"); shift ;;
    esac
done

# Install Trivy if not present
install_trivy() {
    if command -v trivy &>/dev/null; then return; fi

    echo "[INFO] Installing Trivy scanner..."

    # Add Trivy apt repository
    apt-get install -y wget apt-transport-https gnupg lsb-release
    wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key \
        | gpg --dearmor | tee /usr/share/keyrings/trivy.gpg > /dev/null
    echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb \
        $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/trivy.list
    apt-get update
    apt-get install -y trivy
    echo "[INFO] Trivy installed: $(trivy --version 2>/dev/null | head -1)"
}

# Install Cosign if not present
install_cosign() {
    if command -v cosign &>/dev/null; then return; fi

    echo "[INFO] Installing Cosign..."
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *)       echo "[ERROR] Unsupported architecture for Cosign: $arch"; exit 1 ;;
    esac

    local version
    version="$(curl -fsSL https://api.github.com/repos/sigstore/cosign/releases/latest \
        | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')"
    local url="https://github.com/sigstore/cosign/releases/download/v${version}/cosign-linux-${arch}"

    curl -fsSL "$url" -o /usr/local/bin/cosign
    chmod +x /usr/local/bin/cosign
    echo "[INFO] Cosign installed: $(cosign version 2>/dev/null | head -1)"
}

# Verify a single image signature with Cosign
verify_image_signature() {
    local image="$1"
    echo "[INFO] Verifying signature for: $image"

    if [[ -n "$COSIGN_KEY" ]]; then
        if [[ ! -f "$COSIGN_KEY" ]]; then
            echo "[ERROR] Cosign key not found: $COSIGN_KEY"
            return 1
        fi
        if cosign verify --key "$COSIGN_KEY" "$image" &>/dev/null; then
            echo "[INFO] ✓ $image — signature verified (key: $COSIGN_KEY)"
            return 0
        else
            echo "[ERROR] ✗ $image — signature verification FAILED"
            return 1
        fi
    else
        # Keyless Sigstore verification — requires OIDC transparency log
        if cosign verify "$image" \
            --certificate-identity-regexp=".*" \
            --certificate-oidc-issuer-regexp=".*" &>/dev/null; then
            echo "[INFO] ✓ $image — keyless signature verified via Sigstore"
            return 0
        else
            echo "[WARN] ✗ $image — no keyless Sigstore signature found"
            echo "[INFO]   This is expected for images not built with Cosign."
            echo "[INFO]   To require signatures, use --cosign-key with a known publisher key."
            return 1
        fi
    fi
}

# Extract image names from a docker-compose file
images_from_compose() {
    local file="$1"
    grep -E '^\s+image:' "$file" | awk '{print $2}' | tr -d '"'"'"
}

install_trivy
[[ "$VERIFY_SIGNATURE" == true ]] && install_cosign

# Collect images from --compose if given
if [[ -n "$COMPOSE_FILE" ]]; then
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo "[ERROR] Compose file not found: $COMPOSE_FILE"
        exit 1
    fi
    while IFS= read -r img; do
        IMAGES+=("$img")
    done < <(images_from_compose "$COMPOSE_FILE")
fi

if [[ ${#IMAGES[@]} -eq 0 ]]; then
    echo "[ERROR] No images specified"
    echo "Usage: $0 <image>[:<tag>] [<image2>...]"
    echo "       $0 --compose docker-compose.yml"
    exit 1
fi

TRIVY_FLAGS=(--exit-code 1 --severity "$SEVERITY" --format table)
[[ "$IGNORE_UNFIXED" == true ]] && TRIVY_FLAGS+=(--ignore-unfixed)

OVERALL_EXIT=0

for image in "${IMAGES[@]}"; do
    echo ""
    echo "[INFO] ─────────────────────────────────────────"
    echo "[INFO] Scanning image: $image"
    echo "[INFO] Severity threshold: $SEVERITY"
    echo "[INFO] ─────────────────────────────────────────"

    # Signature verification (before pulling/scanning)
    if [[ "$VERIFY_SIGNATURE" == true ]]; then
        if ! verify_image_signature "$image"; then
            if [[ "$NO_FAIL" == true ]]; then
                echo "[WARN] Signature check failed (--no-fail mode, continuing)"
            else
                OVERALL_EXIT=1
                continue
            fi
        fi
    fi

    if trivy image "${TRIVY_FLAGS[@]}" "$image"; then
        echo "[INFO] ✓ $image — no $SEVERITY vulnerabilities found"
    else
        SCAN_EXIT=$?
        if [[ "$NO_FAIL" == true ]]; then
            echo "[WARN] ✗ $image — vulnerabilities found (--no-fail mode, continuing)"
        else
            echo "[ERROR] ✗ $image — $SEVERITY vulnerabilities found (deploy blocked)"
            OVERALL_EXIT=$SCAN_EXIT
        fi
    fi
done

echo ""
if [[ "$OVERALL_EXIT" -eq 0 ]]; then
    echo "[INFO] All images passed the vulnerability scan ✓"
else
    echo "[ERROR] One or more images have $SEVERITY vulnerabilities — deployment blocked"
    echo "[INFO]  Options:"
    echo "  - Update the image to a newer tag with the fix applied"
    echo "  - Run with --ignore-unfixed to skip CVEs without available fixes"
    echo "  - Run with --severity HIGH (instead of CRITICAL) to adjust threshold"
    echo "  - Run with --no-fail to audit without blocking deployment"
fi

exit "$OVERALL_EXIT"
