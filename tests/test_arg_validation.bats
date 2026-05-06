#!/usr/bin/env bats
# Argument validation tests for scripts that require mandatory arguments.
# Verifies that scripts exit non-zero and print usage when required args are missing.
# These tests do NOT need root or system dependencies.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
DEPLOY_SITE="$REPO_ROOT/deploy-site.sh"

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

@test "setup-logrotate: prints Usage with no args" {
    run bash "$SCRIPTS_DIR/setup-logrotate.sh"
    [[ "$output" == *"Usage:"* ]]
}

# ── setup-docker-permissions.sh ───────────────────────────────────────────────

@test "setup-docker-permissions: exits 1 with no args" {
    run bash "$SCRIPTS_DIR/setup-docker-permissions.sh"
    [ "$status" -eq 1 ]
}

@test "setup-docker-permissions: prints Usage with no args" {
    run bash "$SCRIPTS_DIR/setup-docker-permissions.sh"
    [[ "$output" == *"Usage:"* ]]
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

@test "setup-users: prints Usage with no args" {
    run bash "$SCRIPTS_DIR/setup-users.sh"
    [[ "$output" == *"Usage:"* ]]
}

# ── setup-docker-network.sh ───────────────────────────────────────────────────

@test "setup-docker-network: exits 1 with no args" {
    run bash "$SCRIPTS_DIR/setup-docker-network.sh"
    [ "$status" -eq 1 ]
}

@test "setup-docker-network: prints Usage with no args" {
    run bash "$SCRIPTS_DIR/setup-docker-network.sh"
    [[ "$output" == *"Usage:"* ]]
}

# ── setup-ssl.sh ──────────────────────────────────────────────────────────────

@test "setup-ssl: exits 1 with no args" {
    run bash "$SCRIPTS_DIR/setup-ssl.sh"
    [ "$status" -eq 1 ]
}

@test "setup-ssl: prints Usage with no args" {
    run bash "$SCRIPTS_DIR/setup-ssl.sh"
    [[ "$output" == *"Usage:"* ]]
}

# ── configure-nginx-site.sh ───────────────────────────────────────────────────

@test "configure-nginx-site: exits 1 with no args" {
    run bash "$SCRIPTS_DIR/configure-nginx-site.sh"
    [ "$status" -eq 1 ]
}

@test "configure-nginx-site: prints Usage with no args" {
    run bash "$SCRIPTS_DIR/configure-nginx-site.sh"
    [[ "$output" == *"Usage:"* ]]
}

# ── deploy-site.sh parse_args ─────────────────────────────────────────────────
# Source the script (source guard prevents main() from running) to test
# parse_args() in isolation without requiring root access.

@test "deploy-site: parse_args exits 1 on unrecognised argument" {
    run bash -c "source '$DEPLOY_SITE'; parse_args --unknown-flag"
    [ "$status" -eq 1 ]
}

@test "deploy-site: parse_args exits 1 when --mode value is invalid" {
    run bash -c "source '$DEPLOY_SITE'; parse_args --site-name mysite --mode bogus --non-interactive"
    [ "$status" -eq 1 ]
    [[ "$output" == *"mode"* ]]
}

@test "deploy-site: parse_args exits 1 when non-interactive production mode lacks --gcs-key-file" {
    run bash -c "source '$DEPLOY_SITE'; parse_args --site-name mysite --non-interactive"
    [ "$status" -eq 1 ]
    [[ "$output" == *"gcs-key-file"* ]]
}

@test "deploy-site: parse_args exits 0 in development mode with --site-name only" {
    run bash -c "source '$DEPLOY_SITE'; parse_args --site-name mysite --mode development"
    [ "$status" -eq 0 ]
}
