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

@test "write_configs: traefik.yml binds dashboard to all interfaces (:8080)" {
    write_configs
    assert_file_contains "$TRAEFIK_DIR/traefik.yml" '":8080"'
}

@test "write_configs: traefik.yml has insecure: false" {
    write_configs
    assert_file_contains "$TRAEFIK_DIR/traefik.yml" "insecure: false"
}

@test "write_configs: creates dashboard.yml in dynamic dir" {
    write_configs
    assert_file_exists "$TRAEFIK_DYNAMIC_DIR/dashboard.yml"
}

@test "write_configs: dashboard.yml contains basicAuth middleware" {
    write_configs
    assert_file_contains "$TRAEFIK_DYNAMIC_DIR/dashboard.yml" "basicAuth"
    assert_file_contains "$TRAEFIK_DYNAMIC_DIR/dashboard.yml" "dashboard-auth"
}

@test "write_configs: dashboard.yml router targets api@internal" {
    write_configs
    assert_file_contains "$TRAEFIK_DYNAMIC_DIR/dashboard.yml" "api@internal"
}

@test "write_configs: dashboard.yml uses traefik entrypoint" {
    write_configs
    assert_file_contains "$TRAEFIK_DYNAMIC_DIR/dashboard.yml" "traefik"
}

@test "write_configs: dashboard credentials file is created" {
    write_configs
    assert_file_exists "$TRAEFIK_DIR/dashboard-credentials"
}

@test "write_configs: dashboard credentials file contains username and password fields" {
    write_configs
    assert_file_contains "$TRAEFIK_DIR/dashboard-credentials" "username: admin"
    assert_file_contains "$TRAEFIK_DIR/dashboard-credentials" "password:"
}

@test "write_configs: generated password is at least 32 characters" {
    write_configs
    local password
    password=$(grep "^password:" "$TRAEFIK_DIR/dashboard-credentials" | awk '{print $2}')
    [ "${#password}" -ge 32 ]
}

# ── start_traefik ─────────────────────────────────────────────────────────────

@test "start_traefik: pulls correct image tag" {
    local docker_log="$BATS_TEST_TMPDIR/docker.log"
    create_call_log_mock "docker" "$docker_log"
    start_traefik
    grep -q "pull traefik:v3.6" "$docker_log"
}

@test "start_traefik: uses host network mode" {
    local docker_log="$BATS_TEST_TMPDIR/docker.log"
    create_call_log_mock "docker" "$docker_log"
    start_traefik
    grep -q "\-\-network host" "$docker_log"
}

@test "start_traefik: sets --userns=host to allow --network host with userns-remap enabled" {
    local docker_log="$BATS_TEST_TMPDIR/docker.log"
    create_call_log_mock "docker" "$docker_log"
    start_traefik
    grep -q "\-\-userns=host" "$docker_log"
}

@test "start_traefik: does not use port bindings (host network makes them redundant)" {
    local docker_log="$BATS_TEST_TMPDIR/docker.log"
    create_call_log_mock "docker" "$docker_log"
    start_traefik
    ! grep -q "\-p 80:80" "$docker_log"
}

@test "start_traefik: mounts /etc/traefik as read-only" {
    local docker_log="$BATS_TEST_TMPDIR/docker.log"
    create_call_log_mock "docker" "$docker_log"
    start_traefik
    grep -q "/etc/traefik:/etc/traefik:ro" "$docker_log"
}

@test "start_traefik: sets restart policy to always" {
    local docker_log="$BATS_TEST_TMPDIR/docker.log"
    create_call_log_mock "docker" "$docker_log"
    start_traefik
    grep -q "\-\-restart always" "$docker_log"
}

@test "start_traefik: drops all capabilities" {
    local docker_log="$BATS_TEST_TMPDIR/docker.log"
    create_call_log_mock "docker" "$docker_log"
    start_traefik
    grep -q "\-\-cap-drop ALL" "$docker_log"
}

@test "start_traefik: adds NET_BIND_SERVICE for privileged port binding" {
    local docker_log="$BATS_TEST_TMPDIR/docker.log"
    create_call_log_mock "docker" "$docker_log"
    start_traefik
    grep -q "\-\-cap-add NET_BIND_SERVICE" "$docker_log"
}

@test "start_traefik: sets no-new-privileges security option" {
    local docker_log="$BATS_TEST_TMPDIR/docker.log"
    create_call_log_mock "docker" "$docker_log"
    start_traefik
    grep -q "\-\-security-opt no-new-privileges:true" "$docker_log"
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

# ── render_traefik_config: Cloudflare trustedIPs injection ───────────────────

@test "render_traefik_config: marker is fully replaced, no placeholder left" {
    local out
    out="$(render_traefik_config)"
    [[ "$out" != *"__CLOUDFLARE_TRUSTED_IPS__"* ]]
}

@test "render_traefik_config: web entryPoint gets forwardedHeaders.trustedIPs with Cloudflare CIDRs" {
    local out web_block
    out="$(render_traefik_config)"
    web_block="$(echo "$out" | awk '/^  web:/{f=1} /^  websecure:/{f=0} f')"
    [[ "$web_block" == *"forwardedHeaders:"* ]]
    [[ "$web_block" == *"trustedIPs:"* ]]
    [[ "$web_block" == *"- 173.245.48.0/20"* ]]
    [[ "$web_block" == *"- 2400:cb00::/32"* ]]
}

@test "render_traefik_config: websecure entryPoint gets forwardedHeaders.trustedIPs with Cloudflare CIDRs" {
    local out ws_block
    out="$(render_traefik_config)"
    ws_block="$(echo "$out" | awk '/^  websecure:/{f=1} /^  traefik:/{f=0} f')"
    [[ "$ws_block" == *"forwardedHeaders:"* ]]
    [[ "$ws_block" == *"trustedIPs:"* ]]
    [[ "$ws_block" == *"- 141.101.64.0/18"* ]]
}

@test "render_traefik_config: trustedIPs block appears exactly twice (once per entryPoint)" {
    local out count
    out="$(render_traefik_config)"
    count="$(echo "$out" | grep -c "trustedIPs:")"
    [ "$count" -eq 2 ]
}

@test "render_traefik_config: traefik entryPoint (dashboard) is untouched" {
    local out
    out="$(render_traefik_config)"
    [[ "$out" == *'address: ":8080"'* ]]
}

@test "render_traefik_config: comment and blank lines in cloudflare-ips.txt are not emitted as entries" {
    local custom="$BATS_TEST_TMPDIR/custom-ips.txt"
    cat > "$custom" <<'EOF'
# a header comment

10.0.0.0/8


# another comment
192.168.0.0/16
EOF
    CLOUDFLARE_IPS_FILE="$custom"
    local out
    out="$(render_traefik_config)"
    [[ "$out" == *"- 10.0.0.0/8"* ]]
    [[ "$out" == *"- 192.168.0.0/16"* ]]
    [[ "$out" != *"a header comment"* ]]
    [[ "$out" != *"another comment"* ]]
    local count
    count="$(echo "$out" | grep -c "trustedIPs:")"
    [ "$count" -eq 2 ]
    local ip_lines
    ip_lines="$(echo "$out" | grep -c -- '- 10.0.0.0/8')"
    [ "$ip_lines" -eq 2 ]
}

@test "write_configs: written traefik.yml has trustedIPs for both entrypoints" {
    write_configs
    local content
    content="$(cat "$TRAEFIK_DIR/traefik.yml")"
    [[ "$content" != *"__CLOUDFLARE_TRUSTED_IPS__"* ]]
    local count
    count="$(echo "$content" | grep -c "trustedIPs:")"
    [ "$count" -eq 2 ]
}

# ── config_drifted ────────────────────────────────────────────────────────────

@test "config_drifted: true when deployed traefik.yml is missing" {
    rm -f "$TRAEFIK_DIR/traefik.yml"
    run config_drifted
    [ "$status" -eq 0 ]
}

@test "config_drifted: true when deployed traefik.yml differs from current template render" {
    echo "stale config from a previous version" > "$TRAEFIK_DIR/traefik.yml"
    run config_drifted
    [ "$status" -eq 0 ]
}

@test "config_drifted: false when deployed traefik.yml matches current template render" {
    render_traefik_config > "$TRAEFIK_DIR/traefik.yml"
    run config_drifted
    [ "$status" -eq 1 ]
}

# ── main(): deploy-drift reinstall ────────────────────────────────────────────
# Full-process invocation (main() only runs when the script is executed, not
# sourced) with the EUID root check patched out, matching the pattern used by
# tests/test_install_observability.bats.

_patch_and_run_main() {
    local patched="$BATS_TEST_TMPDIR/install-traefik-patched.sh"
    sed -e 's/if \[\[ "$EUID" -ne 0 \]\]/if false/' \
        "$SCRIPTS_DIR/install-traefik.sh" > "$patched"
    chmod +x "$patched"
    run bash "$patched"
}

_mock_docker_running_v36() {
    local log="$1"
    cat > "$MOCK_BIN/docker" <<MOCK_BODY
#!/bin/bash
echo "\$*" >> "$log"
case "\$*" in
    *"--format {{.Config.Image}}"*) echo "traefik:v3.6" ;;
    *"--format {{.State.Running}}"*) echo "true" ;;
esac
exit 0
MOCK_BODY
    chmod +x "$MOCK_BIN/docker"
}

@test "main: no drift — already-running Traefik is left alone (no container restart)" {
    local docker_log="$BATS_TEST_TMPDIR/docker-main.log"
    _mock_docker_running_v36 "$docker_log"
    render_traefik_config > "$TRAEFIK_DIR/traefik.yml"

    _patch_and_run_main
    [ "$status" -eq 0 ]
    [[ "$output" == *"already running"* ]]
    ! grep -q "rm -f traefik" "$docker_log"
}

@test "main: config drift on a running Traefik triggers a non-interactive reinstall" {
    local docker_log="$BATS_TEST_TMPDIR/docker-main.log"
    _mock_docker_running_v36 "$docker_log"
    create_mock_with_body "ufw" 'echo "Status: active"; exit 0'

    echo "entryPoints:
  web:
    address: \":80\"" > "$TRAEFIK_DIR/traefik.yml"

    mkdir -p "$TRAEFIK_DYNAMIC_DIR"
    printf 'username: admin\npassword: preexistingpassword1234567890\n' \
        > "$TRAEFIK_DIR/dashboard-credentials"
    echo "preexisting-dashboard-config" > "$TRAEFIK_DYNAMIC_DIR/dashboard.yml"

    _patch_and_run_main
    [ "$status" -eq 0 ]
    [[ "$output" == *"drift"* ]]
    [[ "$output" != *"UFW is active"* ]]
    grep -q "rm -f traefik" "$docker_log"
    assert_file_contains "$TRAEFIK_DIR/traefik.yml" "trustedIPs:"
}

@test "main: drift reinstall does not prompt (no ufw warning reaches output)" {
    local docker_log="$BATS_TEST_TMPDIR/docker-main.log"
    _mock_docker_running_v36 "$docker_log"
    create_mock_with_body "ufw" 'echo "Status: active"; exit 0'
    echo "stale" > "$TRAEFIK_DIR/traefik.yml"

    _patch_and_run_main
    [ "$status" -eq 0 ]
    [[ "$output" != *"Options:"* ]] || [[ "$output" != *"UFW is active"* ]]
}

@test "main: drift reinstall preserves existing dashboard credentials (no rotation)" {
    local docker_log="$BATS_TEST_TMPDIR/docker-main.log"
    _mock_docker_running_v36 "$docker_log"
    echo "stale" > "$TRAEFIK_DIR/traefik.yml"

    mkdir -p "$TRAEFIK_DYNAMIC_DIR"
    printf 'username: admin\npassword: preexistingpassword1234567890\n' \
        > "$TRAEFIK_DIR/dashboard-credentials"
    echo "preexisting-dashboard-config" > "$TRAEFIK_DYNAMIC_DIR/dashboard.yml"

    _patch_and_run_main
    [ "$status" -eq 0 ]
    assert_file_contains "$TRAEFIK_DIR/dashboard-credentials" "preexistingpassword1234567890"
    assert_file_contains "$TRAEFIK_DYNAMIC_DIR/dashboard.yml" "preexisting-dashboard-config"
}
