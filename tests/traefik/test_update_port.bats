#!/usr/bin/env bats
# Tests for scripts/update-traefik-port.sh
#
# The script exists so we can reconcile a hand-customised Traefik dynamic
# config with a changed KONG_HTTPS_PORT without clobbering the operator's
# multi-host / middleware / TLS edits.

load '../helpers/common'

setup() {
    setup_mocks
    setup_traefik_dirs
}

teardown() {
    teardown_mocks
}

# ── argument validation ───────────────────────────────────────────────────────

@test "update-traefik-port: fails with no arguments" {
    run bash "$SCRIPTS_DIR/update-traefik-port.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "update-traefik-port: fails with only site name" {
    run bash "$SCRIPTS_DIR/update-traefik-port.sh" mysite
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "update-traefik-port: rejects invalid port" {
    run bash "$SCRIPTS_DIR/update-traefik-port.sh" mysite abc
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid port"* ]]
}

@test "update-traefik-port: rejects out-of-range port" {
    run bash "$SCRIPTS_DIR/update-traefik-port.sh" mysite 70000
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid port"* ]]
}

@test "update-traefik-port: fails when config file missing" {
    run bash "$SCRIPTS_DIR/update-traefik-port.sh" nonexistent-site 8443
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
}

# ── happy path ────────────────────────────────────────────────────────────────

@test "update-traefik-port: is a no-op when port already matches" {
    cat > "$TRAEFIK_DYNAMIC_DIR/mysite.yml" << 'EOF'
http:
  services:
    mysite:
      loadBalancer:
        servers:
          - url: "https://127.0.0.1:8443"
EOF
    run bash "$SCRIPTS_DIR/update-traefik-port.sh" mysite 8443
    [ "$status" -eq 0 ]
    [[ "$output" == *"already"* ]]
    # File content unchanged.
    grep -q '127.0.0.1:8443' "$TRAEFIK_DYNAMIC_DIR/mysite.yml"
}

@test "update-traefik-port: patches the upstream port" {
    cat > "$TRAEFIK_DYNAMIC_DIR/mysite.yml" << 'EOF'
http:
  services:
    mysite:
      loadBalancer:
        servers:
          - url: "https://127.0.0.1:8443"
EOF
    run bash "$SCRIPTS_DIR/update-traefik-port.sh" mysite 8444
    [ "$status" -eq 0 ]
    grep -q '127.0.0.1:8444' "$TRAEFIK_DYNAMIC_DIR/mysite.yml"
    ! grep -q '127.0.0.1:8443' "$TRAEFIK_DYNAMIC_DIR/mysite.yml"
}

@test "update-traefik-port: preserves hand-customised multi-host router rules" {
    # This is the exact shape of VelaAir's prod velaair.yml — multi-host router
    # in a single service. Regression test: prior template-based regeneration
    # would have dropped the extra Host() entries.
    cat > "$TRAEFIK_DYNAMIC_DIR/velaair.yml" << 'EOF'
http:
  routers:
    velaair:
      rule: "Host(`velaair.io`) || Host(`www.velaair.io`) || Host(`api.velaair.io`) || Host(`web.velaair.io`) || Host(`tiles.velaair.io`)"
      entryPoints:
        - websecure
      service: velaair
      tls: {}
      middlewares:
        - security-headers@file
  serversTransports:
    velaair-transport:
      insecureSkipVerify: true
  services:
    velaair:
      loadBalancer:
        serversTransport: velaair-transport
        passHostHeader: true
        servers:
          - url: "https://127.0.0.1:8443"
EOF
    run bash "$SCRIPTS_DIR/update-traefik-port.sh" velaair 8444
    [ "$status" -eq 0 ]
    grep -q '127.0.0.1:8444' "$TRAEFIK_DYNAMIC_DIR/velaair.yml"
    ! grep -q '127.0.0.1:8443' "$TRAEFIK_DYNAMIC_DIR/velaair.yml"
    # Customisations survive.
    grep -q 'api.velaair.io' "$TRAEFIK_DYNAMIC_DIR/velaair.yml"
    grep -q 'tiles.velaair.io' "$TRAEFIK_DYNAMIC_DIR/velaair.yml"
    grep -q 'security-headers@file' "$TRAEFIK_DYNAMIC_DIR/velaair.yml"
    grep -q 'passHostHeader: true' "$TRAEFIK_DYNAMIC_DIR/velaair.yml"
}

@test "update-traefik-port: patches multiple upstream URLs" {
    cat > "$TRAEFIK_DYNAMIC_DIR/mysite.yml" << 'EOF'
http:
  services:
    mysite:
      loadBalancer:
        servers:
          - url: "https://127.0.0.1:8443"
          - url: "https://127.0.0.1:8443"
EOF
    run bash "$SCRIPTS_DIR/update-traefik-port.sh" mysite 8444
    [ "$status" -eq 0 ]
    count=$(grep -c '127.0.0.1:8444' "$TRAEFIK_DYNAMIC_DIR/mysite.yml")
    [ "$count" -eq 2 ]
    ! grep -q '127.0.0.1:8443' "$TRAEFIK_DYNAMIC_DIR/mysite.yml"
}

@test "update-traefik-port: fails cleanly when no 127.0.0.1:PORT in file" {
    cat > "$TRAEFIK_DYNAMIC_DIR/mysite.yml" << 'EOF'
# empty stub
http: {}
EOF
    run bash "$SCRIPTS_DIR/update-traefik-port.sh" mysite 8443
    [ "$status" -eq 1 ]
    [[ "$output" == *"No upstream port found"* ]]
}
