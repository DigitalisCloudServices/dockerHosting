#!/usr/bin/env bash
# infra/artifact-crypto/decrypt.sh
#
# Verify and unpack a deployment artifact.
#
# Usage:
#   decrypt.sh --bundle <path/to/{type}-{hash}.tar.gz[.enc]> \
#              --out-tar <file.tar.gz>
#   decrypt.sh --bundle <path> --out <dir>
#   decrypt.sh --bundle <path> --dry-run
#
# When SKIP_ENCRYPTION=true the bundle is a plain tar.gz produced by
# encrypt.sh in skip-encryption mode. The script copies it to --out-tar
# (or extracts to --out) with no crypto operations.
#
# Required env vars (full crypto only):
#   ARTIFACT_AES_KEY              Base64-encoded AES-256 key
#   ARTIFACT_SIGNING_PUBLIC_KEY   PEM RSA-4096 public key
#
# Exit codes:
#   0  success
#   1  verification failure
#   2  usage / argument error
#   3  decryption failure

set -euo pipefail

BUNDLE_PATH=""
OUTPUT_DIR=""
OUT_TAR=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle)  BUNDLE_PATH="$2"; shift 2 ;;
        --out)     OUTPUT_DIR="$2";  shift 2 ;;
        --out-tar) OUT_TAR="$2";     shift 2 ;;
        --dry-run) DRY_RUN=true;     shift   ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ -z "${BUNDLE_PATH}" ]] && { echo "ERROR: --bundle is required" >&2; exit 2; }
[[ "${DRY_RUN}" != "true" && -z "${OUTPUT_DIR}" && -z "${OUT_TAR}" ]] && \
    { echo "ERROR: --out or --out-tar required unless --dry-run" >&2; exit 2; }
[[ -n "${OUTPUT_DIR}" && -n "${OUT_TAR}" ]] && \
    { echo "ERROR: --out and --out-tar are mutually exclusive" >&2; exit 2; }
[[ ! -f "${BUNDLE_PATH}" ]] && \
    { echo "ERROR: bundle not found: ${BUNDLE_PATH}" >&2; exit 2; }

SKIP_ENCRYPTION="${SKIP_ENCRYPTION:-true}"

# ── Skip-encryption mode ─────────────────────────────────────────────────────
# The bundle is the content tar directly — copy or extract without crypto.

if [[ "${SKIP_ENCRYPTION}" == "true" ]]; then
    echo "==> Staging ${BUNDLE_PATH} (skip-encryption mode)"

    GIT_HASH="$(tar xzf "${BUNDLE_PATH}" -O manifest.json 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('git_hash','unknown'))" \
        2>/dev/null || echo 'unknown')"

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "==> Dry-run: bundle ok, git_hash=${GIT_HASH}"
        exit 0
    fi

    if [[ -n "${OUT_TAR}" ]]; then
        cp "${BUNDLE_PATH}" "${OUT_TAR}"
        echo "==> Done: staged to ${OUT_TAR} (git_hash=${GIT_HASH})"
    else
        mkdir -p "${OUTPUT_DIR}"
        tar xzf "${BUNDLE_PATH}" --no-same-owner -C "${OUTPUT_DIR}"
        echo "==> Done: extracted git_hash=${GIT_HASH} to ${OUTPUT_DIR}"
    fi
    exit 0
fi

# ── Full-crypto mode ──────────────────────────────────────────────────────────

if [[ -z "${ARTIFACT_AES_KEY:-}" ]]; then
    [[ -f /run/secrets/artifact_aes_key ]] \
        && ARTIFACT_AES_KEY="$(cat /run/secrets/artifact_aes_key)" \
        || { [[ "${DRY_RUN}" == "true" ]] && ARTIFACT_AES_KEY="" \
             || { echo "ERROR: ARTIFACT_AES_KEY required" >&2; exit 2; }; }
fi

if [[ -z "${ARTIFACT_SIGNING_PUBLIC_KEY:-}" ]]; then
    [[ -f /run/secrets/artifact_signing_public_key ]] \
        && ARTIFACT_SIGNING_PUBLIC_KEY="$(cat /run/secrets/artifact_signing_public_key)" \
        || { echo "ERROR: ARTIFACT_SIGNING_PUBLIC_KEY required" >&2; exit 2; }
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

EXTRACT_DIR="${WORK_DIR}/bundle"
mkdir -p "${EXTRACT_DIR}"

echo "==> Verifying ${BUNDLE_PATH}"
tar xzf "${BUNDLE_PATH}" -C "${EXTRACT_DIR}"

MANIFEST="${EXTRACT_DIR}/manifest.json"
PAYLOAD_ENC="${EXTRACT_DIR}/payload.enc"
SIG_FILE="${EXTRACT_DIR}/signature.sig"

for f in "${MANIFEST}" "${PAYLOAD_ENC}" "${SIG_FILE}"; do
    [[ -f "$f" ]] || { echo "ERROR: bundle missing: $(basename "$f")" >&2; exit 1; }
done

FORMAT_VERSION="$(python3 -c "
import json, sys
d = json.load(open('${MANIFEST}'))
print(d.get('encryption', {}).get('format_version', 1) if d.get('encryption') else 1)
")"

echo "  Verifying RSA-SHA256 signature..."
PUBLIC_KEY_FILE="${WORK_DIR}/signing_pub.key"
printf '%s' "${ARTIFACT_SIGNING_PUBLIC_KEY}" > "${PUBLIC_KEY_FILE}"

openssl dgst -sha256 -verify "${PUBLIC_KEY_FILE}" \
    -signature "${SIG_FILE}" "${PAYLOAD_ENC}" > /dev/null 2>&1 \
    || { echo "FATAL: RSA signature verification FAILED" >&2; exit 1; }
echo "  Signature OK."

echo "  Verifying SHA256 payload checksum..."
EXPECTED_CHECKSUM="$(python3 -c "import json,sys; d=json.load(open('${MANIFEST}')); print(d['payload_checksum'])")"
ACTUAL_CHECKSUM="$(sha256sum "${PAYLOAD_ENC}" | awk '{print $1}')"
[[ "${ACTUAL_CHECKSUM}" == "${EXPECTED_CHECKSUM}" ]] \
    || { echo "FATAL: checksum mismatch — expected ${EXPECTED_CHECKSUM}, got ${ACTUAL_CHECKSUM}" >&2; exit 1; }
echo "  Checksum OK."

if [[ "${DRY_RUN}" == "true" ]]; then
    GIT_HASH="$(python3 -c "import json,sys; d=json.load(open('${MANIFEST}')); print(d['git_hash'])")"
    echo "==> Dry-run: verified git_hash=${GIT_HASH}"
    exit 0
fi

DECRYPTED_TAR="${WORK_DIR}/payload.tar.gz"

if [[ "${FORMAT_VERSION}" == "1" ]]; then
    echo "  Decrypting (v1: AES-256-CBC)..."
    AES_KEY_FILE="${WORK_DIR}/aes.key"
    echo "${ARTIFACT_AES_KEY}" | base64 -d > "${AES_KEY_FILE}"
    chmod 600 "${AES_KEY_FILE}"
    openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 \
        -pass "file:${AES_KEY_FILE}" -in "${PAYLOAD_ENC}" -out "${DECRYPTED_TAR}" \
        || { echo "FATAL: AES-256-CBC decryption failed" >&2; exit 3; }

elif [[ "${FORMAT_VERSION}" == "2" ]]; then
    echo "  Decrypting (v2: AES-256-GCM)..."
    ARTIFACT_AES_KEY="${ARTIFACT_AES_KEY}" \
    python3 - "${PAYLOAD_ENC}" "${DECRYPTED_TAR}" <<'PYEOF' \
        || { echo "FATAL: AES-256-GCM decryption failed" >&2; exit 3; }
import sys, os, base64, hashlib
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.exceptions import InvalidTag

master_key = base64.b64decode(os.environ['ARTIFACT_AES_KEY'])
with open(sys.argv[1], 'rb') as f:
    data = f.read()

if len(data) < 44:
    sys.exit("FATAL: v2 payload too short")

salt, nonce, ct = data[:32], data[32:44], data[44:]
aes_key = hashlib.pbkdf2_hmac('sha256', master_key, salt, 600000, dklen=32)

try:
    plaintext = AESGCM(aes_key).decrypt(nonce, ct, None)
except InvalidTag:
    sys.exit("FATAL: AES-256-GCM authentication tag mismatch")

with open(sys.argv[2], 'wb') as f:
    f.write(plaintext)
PYEOF
else
    echo "FATAL: unsupported format_version '${FORMAT_VERSION}'" >&2; exit 3
fi

GIT_HASH="$(python3 -c "import json,sys; d=json.load(open('${MANIFEST}')); print(d['git_hash'])")"

if [[ -n "${OUT_TAR}" ]]; then
    cp "${DECRYPTED_TAR}" "${OUT_TAR}"
    echo "==> Done: decrypted tar → ${OUT_TAR} (git_hash=${GIT_HASH})"
else
    mkdir -p "${OUTPUT_DIR}"
    tar xzf "${DECRYPTED_TAR}" -C "${OUTPUT_DIR}"
    echo "==> Done: extracted git_hash=${GIT_HASH} to ${OUTPUT_DIR}"
fi
