#!/usr/bin/env bats
# Tests for scripts/add-traefik-site.sh

load '../helpers/common'

setup() {
    setup_mocks
    setup_traefik_dirs
    # Default: mock docker as traefik running (ps returns "traefik")
    create_mock_with_body "docker" 'echo "traefik"'
}

teardown() {
    teardown_mocks
}

# ── argument validation ───────────────────────────────────────────────────────

@test "add-traefik-site: fails with no arguments" {
    run bash "$SCRIPTS_DIR/add-traefik-site.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "add-traefik-site: fails with domain but no port" {
    run bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "add-traefik-site: rejects port 0" {
    run bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 0
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid port"* ]]
}

@test "add-traefik-site: rejects port 65536" {
    run bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 65536
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid port"* ]]
}

@test "add-traefik-site: rejects non-numeric port" {
    run bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com abc
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid port"* ]]
}

@test "add-traefik-site: fails when dynamic dir does not exist" {
    export TRAEFIK_DYNAMIC_DIR="/nonexistent/path/$$"
    run bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 3001
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
}

@test "add-traefik-site: accepts port 1 (minimum valid)" {
    run bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 1
    [ "$status" -eq 0 ]
}

@test "add-traefik-site: accepts port 65535 (maximum valid)" {
    run bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 65535
    [ "$status" -eq 0 ]
}

# ── config file creation ──────────────────────────────────────────────────────

@test "add-traefik-site: creates config file for valid inputs" {
    run bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 3001
    [ "$status" -eq 0 ]
    assert_file_exists "$TRAEFIK_DYNAMIC_DIR/example-com.yml"
}

@test "add-traefik-site: no template placeholders remain in generated config" {
    bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 3001
    refute_file_contains "$TRAEFIK_DYNAMIC_DIR/example-com.yml" "{{SITE_NAME}}"
    refute_file_contains "$TRAEFIK_DYNAMIC_DIR/example-com.yml" "{{DOMAIN}}"
    refute_file_contains "$TRAEFIK_DYNAMIC_DIR/example-com.yml" "{{PORT}}"
}

@test "add-traefik-site: config contains correct Host rule" {
    bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 3001
    assert_file_contains "$TRAEFIK_DYNAMIC_DIR/example-com.yml" 'Host(`example.com`)'
}

@test "add-traefik-site: config routes to correct localhost port" {
    bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 3001
    assert_file_contains "$TRAEFIK_DYNAMIC_DIR/example-com.yml" "127.0.0.1:3001"
}

@test "add-traefik-site: backend URL uses https scheme" {
    bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 3001
    assert_file_contains "$TRAEFIK_DYNAMIC_DIR/example-com.yml" "https://127.0.0.1:3001"
}

@test "add-traefik-site: config targets websecure entrypoint" {
    bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 3001
    assert_file_contains "$TRAEFIK_DYNAMIC_DIR/example-com.yml" "websecure"
}

@test "add-traefik-site: config applies security-headers middleware" {
    bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 3001
    assert_file_contains "$TRAEFIK_DYNAMIC_DIR/example-com.yml" "security-headers@file"
}

# ── site name derivation ──────────────────────────────────────────────────────

@test "add-traefik-site: derives site name from simple domain (dots to dashes)" {
    bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 3001
    assert_file_exists "$TRAEFIK_DYNAMIC_DIR/example-com.yml"
}

@test "add-traefik-site: derives site name from multi-part domain" {
    bash "$SCRIPTS_DIR/add-traefik-site.sh" my.site.example.com 3001
    assert_file_exists "$TRAEFIK_DYNAMIC_DIR/my-site-example-com.yml"
}

@test "add-traefik-site: uses explicit site name when provided" {
    bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 3001 mysite
    assert_file_exists "$TRAEFIK_DYNAMIC_DIR/mysite.yml"
}

@test "add-traefik-site: explicit site name used in Host rule" {
    bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 3001 mysite
    assert_file_contains "$TRAEFIK_DYNAMIC_DIR/mysite.yml" 'Host(`example.com`)'
}

# ── insecureSkipVerify ────────────────────────────────────────────────────────

@test "add-traefik-site: config sets insecureSkipVerify for self-signed backend certs" {
    bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 3001
    assert_file_contains "$TRAEFIK_DYNAMIC_DIR/example-com.yml" "insecureSkipVerify: true"
}

@test "add-traefik-site: serversTransport references site-scoped transport name" {
    bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 3001
    assert_file_contains "$TRAEFIK_DYNAMIC_DIR/example-com.yml" "example-com-transport"
}

# ── SSL cert behaviour ────────────────────────────────────────────────────────

@test "add-traefik-site: uses self-signed cert (no certFile) when no certs present" {
    bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 3001
    refute_file_contains "$TRAEFIK_DYNAMIC_DIR/example-com.yml" "certFile:"
}

@test "add-traefik-site: uses file cert when both fullchain and privkey present" {
    mkdir -p "$TRAEFIK_CERTS_DIR/example-com"
    touch "$TRAEFIK_CERTS_DIR/example-com/fullchain.pem"
    touch "$TRAEFIK_CERTS_DIR/example-com/privkey.pem"
    bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 3001
    assert_file_contains "$TRAEFIK_DYNAMIC_DIR/example-com.yml" "certFile:"
}

@test "add-traefik-site: cert config references correct cert paths" {
    mkdir -p "$TRAEFIK_CERTS_DIR/example-com"
    touch "$TRAEFIK_CERTS_DIR/example-com/fullchain.pem"
    touch "$TRAEFIK_CERTS_DIR/example-com/privkey.pem"
    bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 3001
    assert_file_contains "$TRAEFIK_DYNAMIC_DIR/example-com.yml" "${TRAEFIK_CERTS_DIR}/example-com/fullchain.pem"
    assert_file_contains "$TRAEFIK_DYNAMIC_DIR/example-com.yml" "${TRAEFIK_CERTS_DIR}/example-com/privkey.pem"
}

@test "add-traefik-site: does NOT use file cert when only fullchain is present" {
    mkdir -p "$TRAEFIK_CERTS_DIR/example-com"
    touch "$TRAEFIK_CERTS_DIR/example-com/fullchain.pem"
    bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 3001
    refute_file_contains "$TRAEFIK_DYNAMIC_DIR/example-com.yml" "certFile:"
}

@test "add-traefik-site: does NOT use file cert when only privkey is present" {
    mkdir -p "$TRAEFIK_CERTS_DIR/example-com"
    touch "$TRAEFIK_CERTS_DIR/example-com/privkey.pem"
    bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 3001
    refute_file_contains "$TRAEFIK_DYNAMIC_DIR/example-com.yml" "certFile:"
}

# ── traefik running check ─────────────────────────────────────────────────────

@test "add-traefik-site: succeeds and warns when Traefik container not running" {
    create_mock_with_body "docker" 'exit 0'  # ps returns empty output
    run bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 3001
    [ "$status" -eq 0 ]
    [[ "$output" == *"not running"* ]]
}

@test "add-traefik-site: no warning when Traefik container is running" {
    create_mock_with_body "docker" 'echo "traefik"'
    run bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 3001
    [ "$status" -eq 0 ]
    [[ "$output" != *"not running"* ]]
}

# ── output messages ───────────────────────────────────────────────────────────

@test "add-traefik-site: output confirms domain and port" {
    run bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 3001
    [[ "$output" == *"example.com"* ]]
    [[ "$output" == *"3001"* ]]
}

@test "add-traefik-site: output includes verify curl command" {
    run bash "$SCRIPTS_DIR/add-traefik-site.sh" example.com 3001
    [[ "$output" == *"curl"* ]]
}
