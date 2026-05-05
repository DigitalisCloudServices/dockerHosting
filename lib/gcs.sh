#!/usr/bin/env bash
# lib/gcs.sh
#
# GCS authentication helper sourced by update-site.sh and deploy-site.sh.
# No imperative code — defines functions only.
#
# Requires: python3 (stdlib), openssl. No Google Cloud SDK needed.

# ── _gcs_https_url ────────────────────────────────────────────────────────────
# Convert gs://bucket/path → https://storage.googleapis.com/bucket/path
_gcs_https_url() { printf 'https://storage.googleapis.com/%s' "${1#gs://}"; }

# ── _gcs_access_token_uncached ────────────────────────────────────────────────
# Exchange a service account JSON key for a short-lived OAuth2 Bearer token.
_gcs_access_token_uncached() {
    local sa_file="$1"
    python3 - "$sa_file" <<'PYEOF'
import sys, json, time, base64, subprocess, urllib.request, urllib.parse, tempfile, os

sa = json.load(open(sys.argv[1]))
email   = sa['client_email']
key_pem = sa['private_key']

now = int(time.time())

def b64url(data):
    if isinstance(data, str):
        data = data.encode()
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()

header  = b64url(json.dumps({"alg":"RS256","typ":"JWT"}, separators=(',',':')))
payload = b64url(json.dumps({
    "iss":   email,
    "scope": "https://www.googleapis.com/auth/devstorage.read_only",
    "aud":   "https://oauth2.googleapis.com/token",
    "iat":   now,
    "exp":   now + 3600,
}, separators=(',',':')))

signing_input = f"{header}.{payload}".encode()

with tempfile.NamedTemporaryFile(mode='w', suffix='.pem', delete=False) as kf:
    os.chmod(kf.fileno(), 0o600)
    kf.write(key_pem)
    key_path = kf.name
try:
    sig_bytes = subprocess.check_output(
        ['openssl', 'dgst', '-sha256', '-sign', key_path],
        input=signing_input, stderr=subprocess.DEVNULL
    )
finally:
    os.unlink(key_path)

jwt = f"{header}.{payload}.{b64url(sig_bytes)}"

data = urllib.parse.urlencode({
    "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
    "assertion":  jwt,
}).encode()
resp = urllib.request.urlopen("https://oauth2.googleapis.com/token", data=data)
print(json.loads(resp.read())['access_token'], end='')
PYEOF
}

# ── _gcs_access_token ────────────────────────────────────────────────────────
# Cached wrapper around _gcs_access_token_uncached.
# Tokens are valid for 3600s; cache TTL is 3300s (5-minute safety margin).
# Cache key = first 16 hex chars of MD5(sa_file path) — one file per SA account.
# Cache lives in /tmp and is process-shared: deploy-site.sh and the update-site.sh
# subprocess it spawns both hit the same file when using the same SA key path.
_gcs_access_token() {
    local sa_file="$1"
    local cache_key cache_file age now

    cache_key="$(printf '%s' "${sa_file}" | md5sum | cut -c1-16)"
    cache_file="/tmp/.gcs_token_${cache_key}"

    if [[ -f "${cache_file}" ]]; then
        now="$(date +%s)"
        age=$(( now - $(stat -c %Y "${cache_file}" 2>/dev/null || echo 0) ))
        if [[ "${age}" -lt 3300 ]]; then
            cat "${cache_file}"
            return 0
        fi
    fi

    local token
    token="$(_gcs_access_token_uncached "${sa_file}")"

    printf '%s' "${token}" > "${cache_file}"
    chmod 600 "${cache_file}"
    printf '%s' "${token}"
}
