#!/usr/bin/env bats
# Comprehensive tests for scripts/configure-nginx-site.sh (deprecated)
# Tests nginx site configuration: argument validation, config generation,
# proxy_pass directives, SSL setup, symlink creation, config testing, and idempotency.

load 'helpers/common'

SCRIPT="$SCRIPTS_DIR/configure-nginx-site.sh"
SITE_NAME="testsite"
DEPLOY_DIR=""

setup() {
    setup_mocks
    
    # Nginx paths with environment variable support
    export NGINX_SITES_AVAILABLE="${NGINX_SITES_AVAILABLE:-$BATS_TEST_TMPDIR/nginx/sites-available}"
    export NGINX_SITES_ENABLED="${NGINX_SITES_ENABLED:-$BATS_TEST_TMPDIR/nginx/sites-enabled}"
    
    mkdir -p "$NGINX_SITES_AVAILABLE" "$NGINX_SITES_ENABLED"
    
    # Create deployment directory with .env file
    DEPLOY_DIR="$BATS_TEST_TMPDIR/deployed/$SITE_NAME"
    mkdir -p "$DEPLOY_DIR"
    
    # Create .env file with required variables
    cat > "$DEPLOY_DIR/.env" << 'EOF'
SITE_HOSTNAME=test.example.com
SITE_PORT=3001
EOF
    
    # Create log files for tracking calls
    NGINX_LOG="$BATS_TEST_TMPDIR/nginx_calls.log"
    SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl_calls.log"
    LN_LOG="$BATS_TEST_TMPDIR/ln_calls.log"
    SED_LOG="$BATS_TEST_TMPDIR/sed_calls.log"
    SSL_SCRIPT_LOG="$BATS_TEST_TMPDIR/setup_ssl_calls.log"
    
    # Mock nginx to succeed on config test
    create_mock_with_body "nginx" "$(cat <<'MOCK_NGINX'
echo "$*" >> "$NGINX_LOG"
if [[ "$1" == "-t" ]]; then
    echo "nginx: the configuration file /etc/nginx/nginx.conf syntax is ok"
    echo "nginx: configuration file /etc/nginx/nginx.conf test is successful"
    exit 0
fi
exit 0
MOCK_NGINX
    )"
    
    # Mock systemctl for nginx reload
    create_call_log_mock "systemctl" "$SYSTEMCTL_LOG"
    
    # Mock ln to use test directories
    create_mock_with_body "ln" "$(cat <<'MOCK_LN'
echo "$*" >> "$LN_LOG"
# Redirect /etc/nginx paths to test directories
args=("$@")
for i in "${!args[@]}"; do
    args[$i]="${args[$i]//\/etc\/nginx\/sites-available/$NGINX_SITES_AVAILABLE}"
    args[$i]="${args[$i]//\/etc\/nginx\/sites-enabled/$NGINX_SITES_ENABLED}"
done
command ln "${args[@]}"
MOCK_LN
    )"
    
    # Mock sed to use test directories
    create_mock_with_body "sed" "$(cat <<'MOCK_SED'
echo "$*" >> "$SED_LOG"
# Redirect /etc/nginx paths to test directories
args=()
for arg in "$@"; do
    case "$arg" in
        /etc/nginx/sites-available/*)
            arg="${arg//\/etc\/nginx\/sites-available/$NGINX_SITES_AVAILABLE}"
            ;;
    esac
    args+=("$arg")
done
command sed "${args[@]}"
MOCK_SED
    )"
    
    # Mock setup-ssl.sh script
    MOCK_SSL_SCRIPT="$MOCK_BIN/setup-ssl.sh"
    cat > "$MOCK_SSL_SCRIPT" << 'MOCK_SSL'
#!/bin/bash
echo "$*" >> "$SSL_SCRIPT_LOG"
exit 0
MOCK_SSL
    chmod +x "$MOCK_SSL_SCRIPT"
    
    # Override script's setup-ssl.sh path discovery
    export MOCK_BIN
    
    export NGINX_LOG SYSTEMCTL_LOG LN_LOG SED_LOG SSL_SCRIPT_LOG
    export NGINX_SITES_AVAILABLE NGINX_SITES_ENABLED
}

teardown() {
    teardown_mocks
}

# ── Argument validation ───────────────────────────────────────────────────────

@test "configure-nginx-site: exits 1 with no arguments" {
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"<site_name>"* ]]
    [[ "$output" == *"<deploy_dir>"* ]]
}

@test "configure-nginx-site: exits 1 with only site name (missing deploy_dir)" {
    run bash "$SCRIPT" "$SITE_NAME"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "configure-nginx-site: accepts both site name and deploy directory" {
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]
}

@test "configure-nginx-site: exits 1 when .env file missing" {
    rm "$DEPLOY_DIR/.env"
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *".env file not found"* ]]
}

@test "configure-nginx-site: exits 1 when SITE_HOSTNAME not defined in .env" {
    cat > "$DEPLOY_DIR/.env" << 'EOF'
SITE_PORT=3001
EOF
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"SITE_HOSTNAME not defined"* ]]
}

@test "configure-nginx-site: exits 1 when SITE_PORT not defined in .env" {
    cat > "$DEPLOY_DIR/.env" << 'EOF'
SITE_HOSTNAME=test.example.com
EOF
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"SITE_PORT not defined"* ]]
}

@test "configure-nginx-site: exits 1 when template not found" {
    # Temporarily rename the template to simulate missing template
    TEMPLATE_FILE="$TEMPLATES_DIR/nginx-boundary-site.conf.template"
    if [ -f "$TEMPLATE_FILE" ]; then
        mv "$TEMPLATE_FILE" "$TEMPLATE_FILE.backup"
    fi
    
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    status_code=$status
    
    # Restore template
    if [ -f "$TEMPLATE_FILE.backup" ]; then
        mv "$TEMPLATE_FILE.backup" "$TEMPLATE_FILE"
    fi
    
    [ "$status_code" -eq 1 ]
    [[ "$output" == *"Template not found"* ]]
}

# ── sites-available config generation ─────────────────────────────────────────

@test "configure-nginx-site: creates nginx config in sites-available" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    [ -f "$NGINX_SITES_AVAILABLE/$SITE_NAME" ]
}

@test "configure-nginx-site: substitutes SITE_NAME in template" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    grep -q "$SITE_NAME" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
}

@test "configure-nginx-site: substitutes SITE_HOSTNAME in template" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    grep -q "test.example.com" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
}

@test "configure-nginx-site: substitutes SITE_PORT in template" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    grep -q "3001" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
}

@test "configure-nginx-site: removes template placeholders" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    ! grep -q "{{SITE_NAME}}" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
    ! grep -q "{{SITE_HOSTNAME}}" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
    ! grep -q "{{SITE_PORT}}" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
}

@test "configure-nginx-site: config contains server_name directive" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    grep -q "server_name test.example.com" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
}

@test "configure-nginx-site: config contains SSL listen directives" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    grep -q "listen 443 ssl" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
}

@test "configure-nginx-site: config contains HTTP listen directives" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    grep -q "listen 80" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
}

# ── proxy_pass directive ──────────────────────────────────────────────────────

@test "configure-nginx-site: config contains proxy_pass to localhost" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    grep -q "proxy_pass http://localhost:" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
}

@test "configure-nginx-site: proxy_pass uses correct SITE_PORT" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    grep -q "proxy_pass http://localhost:3001" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
}

@test "configure-nginx-site: proxy_pass respects .env port changes" {
    cat > "$DEPLOY_DIR/.env" << 'EOF'
SITE_HOSTNAME=test.example.com
SITE_PORT=8080
EOF
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    grep -q "proxy_pass http://localhost:8080" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
}

@test "configure-nginx-site: config sets proxy headers" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    grep -q "proxy_set_header Host" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
    grep -q "proxy_set_header X-Real-IP" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
    grep -q "proxy_set_header X-Forwarded-For" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
    grep -q "proxy_set_header X-Forwarded-Proto" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
}

@test "configure-nginx-site: config supports WebSocket upgrade" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    grep -q "proxy_set_header Upgrade" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
    grep -q 'proxy_set_header Connection "upgrade"' "$NGINX_SITES_AVAILABLE/$SITE_NAME"
}

# ── SSL configuration ─────────────────────────────────────────────────────────

@test "configure-nginx-site: config references SSL certificate path" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    grep -q "ssl_certificate /etc/ssl/dockerhosting/$SITE_NAME/fullchain.pem" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
}

@test "configure-nginx-site: config references SSL certificate key path" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    grep -q "ssl_certificate_key /etc/ssl/dockerhosting/$SITE_NAME/privkey.pem" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
}

@test "configure-nginx-site: config enables TLS 1.2 and 1.3" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    grep -q "ssl_protocols TLSv1.2 TLSv1.3" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
}

@test "configure-nginx-site: config includes security headers" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    grep -q "Strict-Transport-Security" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
    grep -q "X-Frame-Options" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
    grep -q "X-Content-Type-Options" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
}

@test "configure-nginx-site: config redirects HTTP to HTTPS" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    grep -q "return 301 https://" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
}

@test "configure-nginx-site: calls setup-ssl.sh with site name and hostname" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    [ -f "$SSL_SCRIPT_LOG" ]
    grep -q "$SITE_NAME test.example.com" "$SSL_SCRIPT_LOG"
}

@test "configure-nginx-site: continues if setup-ssl.sh not found" {
    # Remove the mock setup-ssl.sh
    rm "$MOCK_BIN/setup-ssl.sh"
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"setup-ssl.sh not found"* ]]
}

# ── sites-enabled symlink ─────────────────────────────────────────────────────

@test "configure-nginx-site: creates symlink in sites-enabled" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    [ -L "$NGINX_SITES_ENABLED/$SITE_NAME" ]
}

@test "configure-nginx-site: symlink points to sites-available config" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    target=$(readlink "$NGINX_SITES_ENABLED/$SITE_NAME")
    [[ "$target" == *"sites-available/$SITE_NAME" ]]
}

@test "configure-nginx-site: uses ln -sf for forced symlink creation" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    grep -q "\-sf" "$LN_LOG"
}

@test "configure-nginx-site: symlink creation is idempotent" {
    # Create symlink first time
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    first_run_success=$?
    
    # Create symlink second time (should succeed with -sf)
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    second_run_success=$?
    
    [ "$first_run_success" -eq 0 ]
    [ "$second_run_success" -eq 0 ]
    [ -L "$NGINX_SITES_ENABLED/$SITE_NAME" ]
}

# ── nginx -t config test ──────────────────────────────────────────────────────

@test "configure-nginx-site: runs nginx -t to test configuration" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    grep -q "\-t" "$NGINX_LOG"
}

@test "configure-nginx-site: proceeds when nginx -t succeeds" {
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"configuration test passed"* ]]
}

@test "configure-nginx-site: exits 1 when nginx -t fails" {
    # Mock nginx to fail config test
    create_mock_with_body "nginx" "$(cat <<'MOCK_NGINX_FAIL'
echo "$*" >> "$NGINX_LOG"
if [[ "$1" == "-t" ]]; then
    echo "nginx: [emerg] unexpected end of file, expecting \"}\" in /etc/nginx/sites-enabled/testsite:42"
    echo "nginx: configuration file /etc/nginx/nginx.conf test failed"
    exit 1
fi
exit 0
MOCK_NGINX_FAIL
    )"
    
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"configuration test failed"* ]]
}

@test "configure-nginx-site: removes symlink when nginx -t fails" {
    # Mock nginx to fail config test
    create_mock_with_body "nginx" "$(cat <<'MOCK_NGINX_FAIL'
echo "$*" >> "$NGINX_LOG"
if [[ "$1" == "-t" ]]; then
    exit 1
fi
exit 0
MOCK_NGINX_FAIL
    )"
    
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR" 2>/dev/null || true
    
    # Symlink should be removed after failed test
    [ ! -L "$NGINX_SITES_ENABLED/$SITE_NAME" ]
}

@test "configure-nginx-site: config file remains in sites-available after test failure" {
    # Mock nginx to fail config test
    create_mock_with_body "nginx" "$(cat <<'MOCK_NGINX_FAIL'
echo "$*" >> "$NGINX_LOG"
if [[ "$1" == "-t" ]]; then
    exit 1
fi
exit 0
MOCK_NGINX_FAIL
    )"
    
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR" 2>/dev/null || true
    
    # Config file should still exist for debugging
    [ -f "$NGINX_SITES_AVAILABLE/$SITE_NAME" ]
}

# ── nginx reload ──────────────────────────────────────────────────────────────

@test "configure-nginx-site: reloads nginx with systemctl" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    grep -q "reload nginx" "$SYSTEMCTL_LOG"
}

@test "configure-nginx-site: reloads nginx only after successful config test" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    
    # Both nginx -t and systemctl reload should have been called
    grep -q "\-t" "$NGINX_LOG"
    grep -q "reload nginx" "$SYSTEMCTL_LOG"
}

@test "configure-nginx-site: does not reload nginx when config test fails" {
    # Mock nginx to fail config test
    create_mock_with_body "nginx" "$(cat <<'MOCK_NGINX_FAIL'
echo "$*" >> "$NGINX_LOG"
if [[ "$1" == "-t" ]]; then
    exit 1
fi
exit 0
MOCK_NGINX_FAIL
    )"
    
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR" 2>/dev/null || true
    
    # systemctl reload should not have been called
    ! grep -q "reload" "$SYSTEMCTL_LOG" || [ ! -f "$SYSTEMCTL_LOG" ]
}

# ── Idempotency ───────────────────────────────────────────────────────────────

@test "configure-nginx-site: running twice with same config succeeds" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    first_run=$?
    
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    second_run=$?
    
    [ "$first_run" -eq 0 ]
    [ "$second_run" -eq 0 ]
}

@test "configure-nginx-site: second run overwrites config file" {
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    first_content=$(cat "$NGINX_SITES_AVAILABLE/$SITE_NAME")
    
    # Modify .env
    cat > "$DEPLOY_DIR/.env" << 'EOF'
SITE_HOSTNAME=updated.example.com
SITE_PORT=4001
EOF
    
    bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    second_content=$(cat "$NGINX_SITES_AVAILABLE/$SITE_NAME")
    
    # Content should be different
    [ "$first_content" != "$second_content" ]
    
    # New values should be in the config
    grep -q "updated.example.com" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
    grep -q "4001" "$NGINX_SITES_AVAILABLE/$SITE_NAME"
}

@test "configure-nginx-site: logs configuration summary" {
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Site Name: $SITE_NAME"* ]]
    [[ "$output" == *"Hostname: test.example.com"* ]]
    [[ "$output" == *"Backend Port: 3001"* ]]
}

@test "configure-nginx-site: displays completion message" {
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Boundary Nginx Configuration Complete"* ]]
}

@test "configure-nginx-site: shows test commands in output" {
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"curl"* ]]
    [[ "$output" == *"test.example.com"* ]]
}

@test "configure-nginx-site: warns about Let's Encrypt upgrade" {
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Let's Encrypt"* ]] || [[ "$output" == *"letsencrypt"* ]]
}
