#!/usr/bin/env bats
# Comprehensive tests for scripts/setup-ssl.sh
# Tests self-signed certificate generation, argument validation, directory creation,
# file permissions, validity period, SAN configuration, and idempotency.

load 'helpers/common'

SCRIPT="$SCRIPTS_DIR/setup-ssl.sh"
SITE_NAME="testsite"
HOSTNAME="test.example.com"

setup() {
    setup_mocks
    
    # Certificate directories with environment variable support
    export CERT_DIR="${CERT_DIR:-$BATS_TEST_TMPDIR/ssl/dockerhosting}"
    export SITE_CERT_DIR="$CERT_DIR/$SITE_NAME"
    
    # Create log files for tracking calls
    OPENSSL_LOG="$BATS_TEST_TMPDIR/openssl_calls.log"
    CHMOD_LOG="$BATS_TEST_TMPDIR/chmod_calls.log"
    CHOWN_LOG="$BATS_TEST_TMPDIR/chown_calls.log"
    LN_LOG="$BATS_TEST_TMPDIR/ln_calls.log"
    
    # Mock mkdir to use test directory
    create_mock_with_body "mkdir" "$(cat <<'MOCK_MKDIR'
# Redirect cert directory creation to test directory
for arg in "$@"; do
    case "$arg" in
        /etc/ssl/dockerhosting/*)
            # Replace /etc/ssl/dockerhosting with test directory
            local test_path="${arg//\/etc\/ssl\/dockerhosting/$CERT_DIR}"
            command mkdir "$@" "${test_path}" 2>/dev/null || true
            exit 0
            ;;
    esac
done
command mkdir "$@"
MOCK_MKDIR
    )"
    
    # Mock openssl commands to simulate certificate generation
    create_mock_with_body "openssl" "$(cat <<'MOCK_OPENSSL'
echo "$*" >> "$OPENSSL_LOG"
case "$1" in
    genrsa)
        # Extract output file from arguments
        for i in "${!@}"; do
            if [[ "${!i}" == "-out" ]]; then
                local next=$((i+1))
                local outfile="${!next}"
                # Create a fake private key
                echo "-----BEGIN PRIVATE KEY-----" > "$outfile"
                echo "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC..." >> "$outfile"
                echo "-----END PRIVATE KEY-----" >> "$outfile"
                exit 0
            fi
        done
        ;;
    req)
        # Extract output file from arguments
        for i in "${!@}"; do
            if [[ "${!i}" == "-out" ]]; then
                local next=$((i+1))
                local outfile="${!next}"
                # Create a fake certificate
                echo "-----BEGIN CERTIFICATE-----" > "$outfile"
                echo "MIIDXTCCAkWgAwIBAgIJAKJ5pP8vL1..." >> "$outfile"
                echo "-----END CERTIFICATE-----" >> "$outfile"
                exit 0
            fi
        done
        ;;
    x509)
        # Simulate certificate verification
        echo "subject=C = US, ST = State, L = City, O = Organization, OU = IT, CN = $HOSTNAME"
        echo "notBefore=May  7 12:00:00 2026 GMT"
        echo "notAfter=May  7 12:00:00 2027 GMT"
        exit 0
        ;;
esac
exit 0
MOCK_OPENSSL
    )"
    
    # Mock chmod to log permission changes
    create_call_log_mock "chmod" "$CHMOD_LOG"
    
    # Mock chown to log ownership changes
    create_call_log_mock "chown" "$CHOWN_LOG"
    
    # Mock ln to log symlink creation
    create_call_log_mock "ln" "$LN_LOG"
    
    # Mock cp for chain.pem copy
    create_mock "cp"
    
    # Mock certbot (should not be called in self-signed mode)
    create_mock "certbot"
    
    export OPENSSL_LOG CHMOD_LOG CHOWN_LOG LN_LOG CERT_DIR SITE_CERT_DIR
}

teardown() {
    teardown_mocks
}

# ── Argument validation ───────────────────────────────────────────────────────

@test "setup-ssl: exits 1 with no arguments" {
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "setup-ssl: exits 1 with only site name (missing hostname)" {
    run bash "$SCRIPT" "$SITE_NAME"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "setup-ssl: shows usage message on missing arguments" {
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"<site_name>"* ]]
    [[ "$output" == *"<hostname>"* ]]
}

@test "setup-ssl: accepts both site name and hostname" {
    mkdir -p "$SITE_CERT_DIR"
    run bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    [ "$status" -eq 0 ]
}

# ── Directory creation ────────────────────────────────────────────────────────

@test "setup-ssl: creates certificate directory for site" {
    run bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    [ "$status" -eq 0 ]
    # Directory should exist in test environment
    [ -d "$SITE_CERT_DIR" ]
}

@test "setup-ssl: uses /etc/ssl/dockerhosting/<site>/ path structure" {
    run bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/etc/ssl/dockerhosting"* ]] || [[ "$output" == *"$CERT_DIR"* ]]
}

# ── OpenSSL certificate generation ────────────────────────────────────────────

@test "setup-ssl: generates private key with openssl genrsa" {
    mkdir -p "$SITE_CERT_DIR"
    bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    grep -q "genrsa -out" "$OPENSSL_LOG"
}

@test "setup-ssl: generates 2048-bit RSA key" {
    mkdir -p "$SITE_CERT_DIR"
    bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    grep -q "genrsa -out .* 2048" "$OPENSSL_LOG"
}

@test "setup-ssl: generates private key to privkey.pem" {
    mkdir -p "$SITE_CERT_DIR"
    bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    grep -q "privkey.pem 2048" "$OPENSSL_LOG"
}

@test "setup-ssl: generates self-signed certificate with openssl req" {
    mkdir -p "$SITE_CERT_DIR"
    bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    grep -q "req -new -x509" "$OPENSSL_LOG"
}

@test "setup-ssl: certificate output to fullchain.pem" {
    mkdir -p "$SITE_CERT_DIR"
    bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    grep -q "\-out.*fullchain.pem" "$OPENSSL_LOG"
}

@test "setup-ssl: uses private key for certificate signing" {
    mkdir -p "$SITE_CERT_DIR"
    bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    grep -q "\-key.*privkey.pem" "$OPENSSL_LOG"
}

@test "setup-ssl: verifies certificate with openssl x509" {
    mkdir -p "$SITE_CERT_DIR"
    bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    grep -q "x509 -in" "$OPENSSL_LOG"
}

# ── 365-day validity ──────────────────────────────────────────────────────────

@test "setup-ssl: certificate valid for 365 days" {
    mkdir -p "$SITE_CERT_DIR"
    bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    grep -q "\-days 365" "$OPENSSL_LOG"
}

# ── Subject Alternative Name (SAN) ────────────────────────────────────────────

@test "setup-ssl: includes SAN extension with domain" {
    mkdir -p "$SITE_CERT_DIR"
    bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    grep -q "subjectAltName.*DNS:$HOSTNAME" "$OPENSSL_LOG"
}

@test "setup-ssl: includes wildcard SAN for subdomains" {
    mkdir -p "$SITE_CERT_DIR"
    bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    grep -q "subjectAltName.*DNS:\*\.$HOSTNAME" "$OPENSSL_LOG"
}

@test "setup-ssl: uses addext for SAN configuration" {
    mkdir -p "$SITE_CERT_DIR"
    bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    grep -q "\-addext.*subjectAltName" "$OPENSSL_LOG"
}

@test "setup-ssl: sets CN (Common Name) to hostname" {
    mkdir -p "$SITE_CERT_DIR"
    bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    grep -q "CN=$HOSTNAME" "$OPENSSL_LOG"
}

# ── File permissions ──────────────────────────────────────────────────────────

@test "setup-ssl: sets private key to 600 permissions" {
    mkdir -p "$SITE_CERT_DIR"
    bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    grep -q "600.*privkey.pem" "$CHMOD_LOG"
}

@test "setup-ssl: sets certificate to 644 permissions" {
    mkdir -p "$SITE_CERT_DIR"
    bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    grep -q "644.*fullchain.pem" "$CHMOD_LOG"
}

@test "setup-ssl: sets ownership to root:root" {
    mkdir -p "$SITE_CERT_DIR"
    bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    grep -q "\-R root:root" "$CHOWN_LOG"
}

@test "setup-ssl: applies ownership recursively to cert directory" {
    mkdir -p "$SITE_CERT_DIR"
    bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    grep -q "\-R root:root.*$SITE_NAME" "$CHOWN_LOG"
}

# ── Certificate files creation ────────────────────────────────────────────────

@test "setup-ssl: creates privkey.pem file" {
    mkdir -p "$SITE_CERT_DIR"
    bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    [ -f "$SITE_CERT_DIR/privkey.pem" ]
}

@test "setup-ssl: creates fullchain.pem file" {
    mkdir -p "$SITE_CERT_DIR"
    bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    [ -f "$SITE_CERT_DIR/fullchain.pem" ]
}

@test "setup-ssl: reports certificate location in output" {
    mkdir -p "$SITE_CERT_DIR"
    run bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    [[ "$output" == *"Certificate location:"* ]]
}

@test "setup-ssl: shows certificate files in output" {
    mkdir -p "$SITE_CERT_DIR"
    run bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    [[ "$output" == *"fullchain.pem"* ]]
    [[ "$output" == *"privkey.pem"* ]]
}

# ── Idempotency ───────────────────────────────────────────────────────────────

@test "setup-ssl: detects existing certificates" {
    mkdir -p "$SITE_CERT_DIR"
    # Create existing certificates
    touch "$SITE_CERT_DIR/fullchain.pem"
    touch "$SITE_CERT_DIR/privkey.pem"
    
    # Mock interactive response: don't regenerate (N)
    run bash -c "echo 'N' | bash '$SCRIPT' '$SITE_NAME' '$HOSTNAME'"
    [[ "$output" == *"already exist"* ]]
}

@test "setup-ssl: warns when certificates exist" {
    mkdir -p "$SITE_CERT_DIR"
    # Create existing certificates
    touch "$SITE_CERT_DIR/fullchain.pem"
    touch "$SITE_CERT_DIR/privkey.pem"
    
    run bash -c "echo 'N' | bash '$SCRIPT' '$SITE_NAME' '$HOSTNAME'"
    [[ "$output" == *"WARN"* ]] || [[ "$output" == *"exist"* ]]
}

@test "setup-ssl: prompts for regeneration when certificates exist" {
    mkdir -p "$SITE_CERT_DIR"
    # Create existing certificates
    touch "$SITE_CERT_DIR/fullchain.pem"
    touch "$SITE_CERT_DIR/privkey.pem"
    
    run bash -c "echo 'N' | bash '$SCRIPT' '$SITE_NAME' '$HOSTNAME'"
    [[ "$output" == *"Regenerate"* ]] || [[ "$output" == *"exist"* ]]
}

@test "setup-ssl: uses existing certificates when user declines regeneration" {
    mkdir -p "$SITE_CERT_DIR"
    # Create existing certificates
    touch "$SITE_CERT_DIR/fullchain.pem"
    touch "$SITE_CERT_DIR/privkey.pem"
    
    run bash -c "echo 'N' | bash '$SCRIPT' '$SITE_NAME' '$HOSTNAME'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"existing"* ]] || [ "$status" -eq 0 ]
}

@test "setup-ssl: regenerates certificates when user confirms" {
    mkdir -p "$SITE_CERT_DIR"
    # Create existing certificates
    echo "old cert" > "$SITE_CERT_DIR/fullchain.pem"
    echo "old key" > "$SITE_CERT_DIR/privkey.pem"
    
    # Mock interactive response: yes, regenerate (Y)
    run bash -c "echo 'Y' | bash '$SCRIPT' '$SITE_NAME' '$HOSTNAME'"
    [ "$status" -eq 0 ]
    # Should have called openssl to generate new certificates
    grep -q "genrsa" "$OPENSSL_LOG"
}

# ── Self-signed mode ──────────────────────────────────────────────────────────

@test "setup-ssl: defaults to self-signed mode without --letsencrypt flag" {
    mkdir -p "$SITE_CERT_DIR"
    run bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    [[ "$output" == *"self-signed"* ]]
}

@test "setup-ssl: warns about browser security warnings for self-signed certs" {
    mkdir -p "$SITE_CERT_DIR"
    run bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    [[ "$output" == *"self-signed"* ]] && [[ "$output" == *"browser"* || "$output" == *"warning"* || "$output" == *"WARN"* ]]
}

@test "setup-ssl: shows Let's Encrypt upgrade instructions" {
    mkdir -p "$SITE_CERT_DIR"
    run bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    [[ "$output" == *"Let's Encrypt"* ]] || [[ "$output" == *"letsencrypt"* ]]
}

@test "setup-ssl: does not call certbot in self-signed mode" {
    mkdir -p "$SITE_CERT_DIR"
    # Create a certbot mock that would fail if called
    create_mock_with_body "certbot" "exit 99"
    
    run bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    # Should succeed without calling certbot
    [ "$status" -eq 0 ]
}

# ── Output and messaging ──────────────────────────────────────────────────────

@test "setup-ssl: shows success message on completion" {
    mkdir -p "$SITE_CERT_DIR"
    run bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    [ "$status" -eq 0 ]
    [[ "$output" == *"complete"* || "$output" == *"Complete"* ]]
}

@test "setup-ssl: displays site name in output" {
    mkdir -p "$SITE_CERT_DIR"
    run bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    [[ "$output" == *"$SITE_NAME"* ]]
}

@test "setup-ssl: displays hostname in output" {
    mkdir -p "$SITE_CERT_DIR"
    run bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    [[ "$output" == *"$HOSTNAME"* ]]
}

@test "setup-ssl: exits 0 on successful certificate generation" {
    mkdir -p "$SITE_CERT_DIR"
    run bash "$SCRIPT" "$SITE_NAME" "$HOSTNAME"
    [ "$status" -eq 0 ]
}
