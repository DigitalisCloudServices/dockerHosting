#!/usr/bin/env bash
# infra/bootstrap/lib/gcs.sh
#
# GCS authentication helper sourced by update.sh.
# No imperative code — defines functions only.
#
# Requires: python3 (stdlib), openssl. No Google Cloud SDK needed.

# ── _gcs_https_url ────────────────────────────────────────────────────────────
# Convert gs://bucket/path → https://storage.googleapis.com/bucket/path
_gcs_https_url() { printf 'https://storage.googleapis.com/%s' "${1#gs://}"; }

# ── _gcs_access_token ────────────────────────────────────────────────────────
# Exchange a service account JSON key for a short-lived OAuth2 Bearer token.
_gcs_access_token() {
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
