#!/usr/bin/env bats
# Tests for scripts/remove-traefik-site.sh

load '../helpers/common'

setup() {
    setup_mocks
    setup_traefik_dirs
    # Pre-create a test site config
    cat > "$TRAEFIK_DYNAMIC_DIR/example-com.yml" <<'EOF'
http:
  routers:
    example-com:
      rule: "Host(`example.com`)"
      entryPoints: [websecure]
      service: example-com
      tls: {}
  services:
    example-com:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:3001"
EOF
}

teardown() {
    teardown_mocks
}

# ── argument validation ───────────────────────────────────────────────────────

@test "remove-traefik-site: fails with no arguments" {
    run bash "$SCRIPTS_DIR/remove-traefik-site.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "remove-traefik-site: no-arg output lists existing sites" {
    run bash "$SCRIPTS_DIR/remove-traefik-site.sh"
    [[ "$output" == *"example-com"* ]]
}

@test "remove-traefik-site: fails when config file not found" {
    run bash "$SCRIPTS_DIR/remove-traefik-site.sh" nonexistent.com
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
}

@test "remove-traefik-site: error output lists existing sites" {
    run bash "$SCRIPTS_DIR/remove-traefik-site.sh" nonexistent.com
    [[ "$output" == *"example-com"* ]]
}

# ── config file removal ───────────────────────────────────────────────────────

@test "remove-traefik-site: removes config file when given domain" {
    bash "$SCRIPTS_DIR/remove-traefik-site.sh" example.com
    [ ! -f "$TRAEFIK_DYNAMIC_DIR/example-com.yml" ]
}

@test "remove-traefik-site: removes config file when given site name (no dots)" {
    bash "$SCRIPTS_DIR/remove-traefik-site.sh" example-com
    [ ! -f "$TRAEFIK_DYNAMIC_DIR/example-com.yml" ]
}

@test "remove-traefik-site: exits 0 on successful removal" {
    run bash "$SCRIPTS_DIR/remove-traefik-site.sh" example.com
    [ "$status" -eq 0 ]
}

@test "remove-traefik-site: output confirms removal" {
    run bash "$SCRIPTS_DIR/remove-traefik-site.sh" example.com
    [[ "$output" == *"Removed"* ]]
}

@test "remove-traefik-site: handles multi-part domain" {
    cat > "$TRAEFIK_DYNAMIC_DIR/my-sub-example-com.yml" <<'EOF'
http: {}
EOF
    bash "$SCRIPTS_DIR/remove-traefik-site.sh" my.sub.example.com
    [ ! -f "$TRAEFIK_DYNAMIC_DIR/my-sub-example-com.yml" ]
}

@test "remove-traefik-site: does not remove other site configs" {
    cat > "$TRAEFIK_DYNAMIC_DIR/other-site.yml" <<'EOF'
http: {}
EOF
    bash "$SCRIPTS_DIR/remove-traefik-site.sh" example.com
    assert_file_exists "$TRAEFIK_DYNAMIC_DIR/other-site.yml"
}

# ── site listing ──────────────────────────────────────────────────────────────

@test "remove-traefik-site: site listing excludes middleware.yml" {
    cat > "$TRAEFIK_DYNAMIC_DIR/middleware.yml" <<'EOF'
http:
  middlewares: {}
EOF
    run bash "$SCRIPTS_DIR/remove-traefik-site.sh"
    # "middleware" should not appear as a listed site name
    [[ "$output" != *"  middleware"* ]]
}

@test "remove-traefik-site: site listing shows (none) when dynamic dir is empty" {
    rm -f "$TRAEFIK_DYNAMIC_DIR"/*.yml
    run bash "$SCRIPTS_DIR/remove-traefik-site.sh"
    [[ "$output" == *"(none)"* ]]
}
