#!/usr/bin/env bats
# Tests for scripts/install-traefik.sh
# Uses source guard to test individual functions without running main()

load '../helpers/common'

setup() {
    setup_mocks
    setup_traefik_dirs
    setup_nginx_dirs

    # Mock system commands used by install-traefik.sh
    create_mock "docker"
    create_mock "systemctl"
    create_mock "apt-get"
    create_mock "dpkg"   # default: nginx not installed (exit 0, no "^ii" output)
    create_mock "curl"
    create_mock "ln"
    create_mock "find"

    # Export overrides so they're visible when the script is sourced
    export TRAEFIK_DIR TRAEFIK_DYNAMIC_DIR TRAEFIK_CERTS_DIR
    export NGINX_SITES_DIR DOCKERHOSTING_SSL_DIR DEPLOYED_APPS_DIR
    export TEMPLATE_DIR
    export SCRIPT_DIR="$SCRIPTS_DIR"

    # Source the script — BASH_SOURCE guard prevents main() from running
    # shellcheck disable=SC1090
    source "$SCRIPTS_DIR/install-traefik.sh"
}

teardown() {
    teardown_mocks
}

# ── _nginx_is_present ─────────────────────────────────────────────────────────

@test "_nginx_is_present: returns false when dpkg shows nginx not installed" {
    create_mock_with_body "dpkg" 'exit 1'
    create_mock_with_body "systemctl" 'exit 1'
    run _nginx_is_present
    [ "$status" -ne 0 ]
}

@test "_nginx_is_present: returns true when dpkg shows nginx installed" {
    create_mock_with_body "dpkg" \
        'echo "ii  nginx   1.24.0-1  all  small web server"; exit 0'
    run _nginx_is_present
    [ "$status" -eq 0 ]
}

@test "_nginx_is_present: returns true when systemctl reports nginx active" {
    create_mock_with_body "dpkg" 'exit 1'
    create_mock_with_body "systemctl" 'exit 0'
    run _nginx_is_present
    [ "$status" -eq 0 ]
}

# ── _derive_site_name (via add-traefik-site.sh) ───────────────────────────────
# This is tested fully in test_add_site.bats; just a smoke test here

@test "_migrate_one_site: skips conf with no server_name" {
    create_mock "bash"  # prevent add-traefik-site.sh from actually running
    local conf="$BATS_TEST_TMPDIR/no-server-name.conf"
    cat > "$conf" <<'EOF'
server {
    listen 80;
    proxy_pass http://127.0.0.1:3001;
}
EOF
    MIGRATION_WARNINGS=()
    run _migrate_one_site "$conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no server_name found"* ]]
}

@test "_migrate_one_site: skips default server block (server_name _)" {
    create_mock "bash"
    local conf="$BATS_TEST_TMPDIR/default.conf"
    cat > "$conf" <<'EOF'
server {
    server_name _;
    listen 80 default_server;
    proxy_pass http://127.0.0.1:3001;
}
EOF
    MIGRATION_WARNINGS=()
    run _migrate_one_site "$conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no server_name found"* || "$output" == *"Skipping"* ]]
}

@test "_migrate_one_site: adds warning when no proxy_pass port" {
    create_mock "bash"
    local conf="$BATS_TEST_TMPDIR/no-port.conf"
    cat > "$conf" <<'EOF'
server {
    server_name example.com;
    # no proxy_pass
}
EOF
    MIGRATION_WARNINGS=()
    _migrate_one_site "$conf"
    [ "${#MIGRATION_WARNINGS[@]}" -gt 0 ]
    [[ "${MIGRATION_WARNINGS[0]}" == *"no proxy_pass port"* ]]
}

@test "_migrate_one_site: adds warning for custom location blocks" {
    create_mock "bash"
    local conf="$BATS_TEST_TMPDIR/custom-loc.conf"
    cat > "$conf" <<'EOF'
server {
    server_name example.com;
    proxy_pass http://127.0.0.1:3001;
    location /api {
        proxy_pass http://127.0.0.1:3002;
    }
}
EOF
    MIGRATION_WARNINGS=()
    _migrate_one_site "$conf"
    [[ "${MIGRATION_WARNINGS[*]}" == *"custom location blocks"* ]]
}

@test "_migrate_one_site: adds warning for limit_req" {
    create_mock "bash"
    local conf="$BATS_TEST_TMPDIR/limit-req.conf"
    cat > "$conf" <<'EOF'
server {
    server_name example.com;
    proxy_pass http://127.0.0.1:3001;
    limit_req zone=general burst=10;
}
EOF
    MIGRATION_WARNINGS=()
    _migrate_one_site "$conf"
    [[ "${MIGRATION_WARNINGS[*]}" == *"limit_req"* ]]
}

@test "_migrate_one_site: links SSL certs when they exist" {
    create_mock "bash"
    local cert_dir="$DOCKERHOSTING_SSL_DIR/example-com"
    mkdir -p "$cert_dir"
    touch "$cert_dir/fullchain.pem"

    # Override ln mock to record calls
    local ln_log="$BATS_TEST_TMPDIR/ln.log"
    create_call_log_mock "ln" "$ln_log"

    local conf="$BATS_TEST_TMPDIR/valid.conf"
    cat > "$conf" <<'EOF'
server {
    server_name example.com;
    proxy_pass http://127.0.0.1:3001;
}
EOF
    MIGRATION_WARNINGS=()
    _migrate_one_site "$conf"
    [ -f "$ln_log" ]
    grep -q "example-com" "$ln_log"
}

@test "_migrate_one_site: calls add-traefik-site.sh with domain and port" {
    local bash_log="$BATS_TEST_TMPDIR/bash.log"
    create_call_log_mock "bash" "$bash_log"

    local conf="$BATS_TEST_TMPDIR/valid.conf"
    cat > "$conf" <<'EOF'
server {
    server_name example.com;
    proxy_pass http://127.0.0.1:3001;
}
EOF
    MIGRATION_WARNINGS=()
    _migrate_one_site "$conf"
    grep -q "add-traefik-site.sh" "$bash_log"
    grep -q "example.com" "$bash_log"
    grep -q "3001" "$bash_log"
}

# ── _handle_certbot_cron ──────────────────────────────────────────────────────

@test "_handle_certbot_cron: adds no warning when certbot cron absent" {
    MIGRATION_WARNINGS=()
    _handle_certbot_cron
    [ "${#MIGRATION_WARNINGS[@]}" -eq 0 ]
}

# ── write_configs ─────────────────────────────────────────────────────────────

@test "write_configs: copies traefik.yml into TRAEFIK_DIR" {
    write_configs
    assert_file_exists "$TRAEFIK_DIR/traefik.yml"
}

@test "write_configs: copies middleware.yml into TRAEFIK_DYNAMIC_DIR" {
    write_configs
    assert_file_exists "$TRAEFIK_DYNAMIC_DIR/middleware.yml"
}

@test "write_configs: traefik.yml contains file provider config" {
    write_configs
    assert_file_contains "$TRAEFIK_DIR/traefik.yml" "directory:"
    assert_file_contains "$TRAEFIK_DIR/traefik.yml" "watch: true"
}

@test "write_configs: middleware.yml defines security-headers" {
    write_configs
    assert_file_contains "$TRAEFIK_DYNAMIC_DIR/middleware.yml" "security-headers"
    assert_file_contains "$TRAEFIK_DYNAMIC_DIR/middleware.yml" "stsSeconds"
}

@test "write_configs: middleware.yml defines rate-limit" {
    write_configs
    assert_file_contains "$TRAEFIK_DYNAMIC_DIR/middleware.yml" "rate-limit"
    assert_file_contains "$TRAEFIK_DYNAMIC_DIR/middleware.yml" "rateLimit"
}

@test "write_configs: traefik.yml has HTTP→HTTPS redirect" {
    write_configs
    assert_file_contains "$TRAEFIK_DIR/traefik.yml" "redirections"
    assert_file_contains "$TRAEFIK_DIR/traefik.yml" "websecure"
}

# ── start_traefik ─────────────────────────────────────────────────────────────

@test "start_traefik: pulls correct image tag" {
    local docker_log="$BATS_TEST_TMPDIR/docker.log"
    create_call_log_mock "docker" "$docker_log"
    start_traefik
    grep -q "pull traefik:v3.6" "$docker_log"
}

@test "start_traefik: starts container with port 80 binding" {
    local docker_log="$BATS_TEST_TMPDIR/docker.log"
    create_call_log_mock "docker" "$docker_log"
    start_traefik
    grep -q "\-p 80:80" "$docker_log"
}

@test "start_traefik: starts container with port 443 binding" {
    local docker_log="$BATS_TEST_TMPDIR/docker.log"
    create_call_log_mock "docker" "$docker_log"
    start_traefik
    grep -q "\-p 443:443" "$docker_log"
}

@test "start_traefik: restricts dashboard to localhost" {
    local docker_log="$BATS_TEST_TMPDIR/docker.log"
    create_call_log_mock "docker" "$docker_log"
    start_traefik
    grep -q "127.0.0.1:8080:8080" "$docker_log"
}

@test "start_traefik: mounts /etc/traefik as read-only" {
    local docker_log="$BATS_TEST_TMPDIR/docker.log"
    create_call_log_mock "docker" "$docker_log"
    start_traefik
    grep -q "/etc/traefik:/etc/traefik:ro" "$docker_log"
}

@test "start_traefik: sets restart policy to unless-stopped" {
    local docker_log="$BATS_TEST_TMPDIR/docker.log"
    create_call_log_mock "docker" "$docker_log"
    start_traefik
    grep -q "unless-stopped" "$docker_log"
}

# ── check_nginx_migration prompt flags ───────────────────────────────────────

@test "check_nginx_migration: exits 0 with MIGRATE_NGINX=no when nginx detected" {
    create_mock_with_body "dpkg" \
        'echo "ii  nginx   1.24.0-1  all  desc"; exit 0'
    MIGRATE_NGINX="no"
    run check_nginx_migration
    [ "$status" -eq 0 ]
}

@test "check_nginx_migration: exits 1 with MIGRATE_NGINX=abort when nginx detected" {
    create_mock_with_body "dpkg" \
        'echo "ii  nginx   1.24.0-1  all  desc"; exit 0'
    MIGRATE_NGINX="abort"
    run check_nginx_migration
    [ "$status" -eq 1 ]
}

@test "check_nginx_migration: exits 1 with invalid choice when nginx detected" {
    create_mock_with_body "dpkg" \
        'echo "ii  nginx   1.24.0-1  all  desc"; exit 0'
    MIGRATE_NGINX="bogus"
    run check_nginx_migration
    [ "$status" -eq 1 ]
}

@test "check_nginx_migration: skips entirely when nginx not present" {
    create_mock_with_body "dpkg" 'exit 1'
    create_mock_with_body "systemctl" 'exit 1'
    MIGRATE_NGINX=""
    run check_nginx_migration
    [ "$status" -eq 0 ]
}
