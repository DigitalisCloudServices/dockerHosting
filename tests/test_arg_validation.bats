#!/usr/bin/env bats
# Argument validation tests for scripts that require mandatory arguments.
# Verifies that scripts exit non-zero and print usage when required args are missing.
# These tests do NOT need root or system dependencies.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"

# ── Traefik scripts ───────────────────────────────────────────────────────────

@test "add-traefik-site: exits 1 with no args" {
    run bash "$SCRIPTS_DIR/add-traefik-site.sh"
    [ "$status" -eq 1 ]
}

@test "add-traefik-site: prints usage with no args" {
    run bash "$SCRIPTS_DIR/add-traefik-site.sh"
    [[ "$output" == *"Usage:"* ]]
}

@test "remove-traefik-site: exits 1 with no args" {
    # Point at an empty tmp dir so the script doesn't error on missing traefik dir
    TRAEFIK_DYNAMIC_DIR="$(mktemp -d)" run bash "$SCRIPTS_DIR/remove-traefik-site.sh"
    [ "$status" -eq 1 ]
    rmdir "${TRAEFIK_DYNAMIC_DIR:-}" 2>/dev/null || true
}

@test "remove-traefik-site: prints usage with no args" {
    TRAEFIK_DYNAMIC_DIR="$(mktemp -d)" run bash "$SCRIPTS_DIR/remove-traefik-site.sh"
    [[ "$output" == *"Usage:"* ]]
    rmdir "${TRAEFIK_DYNAMIC_DIR:-}" 2>/dev/null || true
}

# ── setup-logrotate.sh ────────────────────────────────────────────────────────

@test "setup-logrotate: exits 1 with no args" {
    run bash "$SCRIPTS_DIR/setup-logrotate.sh"
    [ "$status" -eq 1 ]
}

# ── setup-docker-permissions.sh ───────────────────────────────────────────────

@test "setup-docker-permissions: exits 1 with no args" {
    run bash "$SCRIPTS_DIR/setup-docker-permissions.sh"
    [ "$status" -eq 1 ]
}

@test "setup-docker-permissions: exits 1 with only one arg" {
    run bash "$SCRIPTS_DIR/setup-docker-permissions.sh" someuser
    [ "$status" -eq 1 ]
}

# ── setup-users.sh ────────────────────────────────────────────────────────────

@test "setup-users: exits 1 with no args" {
    run bash "$SCRIPTS_DIR/setup-users.sh"
    [ "$status" -eq 1 ]
}

# ── setup-docker-network.sh ───────────────────────────────────────────────────

@test "setup-docker-network: exits 1 with no args" {
    run bash "$SCRIPTS_DIR/setup-docker-network.sh"
    [ "$status" -eq 1 ]
}

# ── setup-ssl.sh ──────────────────────────────────────────────────────────────

@test "setup-ssl: exits 1 with no args" {
    run bash "$SCRIPTS_DIR/setup-ssl.sh"
    [ "$status" -eq 1 ]
}

# ── configure-nginx-site.sh ───────────────────────────────────────────────────

@test "configure-nginx-site: exits 1 with no args" {
    run bash "$SCRIPTS_DIR/configure-nginx-site.sh"
    [ "$status" -eq 1 ]
}
