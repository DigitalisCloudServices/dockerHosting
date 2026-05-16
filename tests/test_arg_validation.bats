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

@test "deploy-site: parse_args accepts repeated --env-set into EXTRA_ENV_SETS" {
    run bash -c "source '$DEPLOY_SITE'; parse_args --site-name mysite --mode development --env-set FOO=bar --env-set BAZ=qux; echo \"len=\${#EXTRA_ENV_SETS[@]} first=\${EXTRA_ENV_SETS[0]} second=\${EXTRA_ENV_SETS[1]}\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"len=2"* ]]
    [[ "$output" == *"first=FOO=bar"* ]]
    [[ "$output" == *"second=BAZ=qux"* ]]
}

@test "deploy-site: parse_args rejects --env-set without '=' in value" {
    run bash -c "source '$DEPLOY_SITE'; parse_args --site-name mysite --mode development --env-set FOO"
    [ "$status" -eq 1 ]
    [[ "$output" == *"env-set"* ]]
}

@test "deploy-site: parse_args rejects --env-set with no following arg" {
    run bash -c "source '$DEPLOY_SITE'; parse_args --site-name mysite --mode development --env-set"
    [ "$status" -eq 1 ]
    [[ "$output" == *"env-set"* ]]
}

@test "deploy-site: parse_args accepts --env-file path" {
    run bash -c "source '$DEPLOY_SITE'; parse_args --site-name mysite --mode development --env-file /tmp/some-env-file; echo \"file=\$EXTRA_ENV_FILE\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"file=/tmp/some-env-file"* ]]
}

@test "deploy-site: parse_args rejects --env-file with no following arg" {
    run bash -c "source '$DEPLOY_SITE'; parse_args --site-name mysite --mode development --env-file"
    [ "$status" -eq 1 ]
    [[ "$output" == *"env-file"* ]]
}

# ── deploy-site.sh _apply_env_file ───────────────────────────────────────────
# Exercise the merge helper in isolation against a tmp .env target.

@test "deploy-site: _apply_env_file merges KEY=VALUE lines, ignores comments/blanks, strips quotes" {
    tmpdir="$(mktemp -d)"
    src="$tmpdir/overrides.env"
    target="$tmpdir/.env"
    cat > "$src" <<'EOF'
# top comment
FOO=bar
BAZ="quoted value"

  PADDED_KEY=untouched-value
EOF
    : > "$target"
    run bash -c "source '$DEPLOY_SITE'; _apply_env_file '$src' '$target'; cat '$target'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FOO=bar"* ]]
    [[ "$output" == *"BAZ=quoted value"* ]]
    [[ "$output" == *"PADDED_KEY=untouched-value"* ]]
    [[ "$output" != *"top comment"* ]]
    rm -rf "$tmpdir"
}

@test "deploy-site: _apply_env_file overwrites existing keys in target" {
    # _env_set uses GNU sed -i; skip on BSD sed hosts (e.g. macOS dev machines).
    # Target deployment hosts (Debian) have GNU sed and exercise this path in production.
    [[ "$(uname)" == "Linux" ]] || skip "GNU sed required (preexisting _env_set behaviour)"
    tmpdir="$(mktemp -d)"
    src="$tmpdir/overrides.env"
    target="$tmpdir/.env"
    echo "FOO=original" > "$target"
    echo "FOO=replaced" > "$src"
    run bash -c "source '$DEPLOY_SITE'; _apply_env_file '$src' '$target'; cat '$target'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FOO=replaced"* ]]
    [[ "$output" != *"FOO=original"* ]]
    rm -rf "$tmpdir"
}

@test "deploy-site: _apply_env_file errors if file is missing" {
    run bash -c "source '$DEPLOY_SITE'; _apply_env_file /nonexistent/path /tmp/.env-irrelevant"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
}
