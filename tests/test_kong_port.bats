#!/usr/bin/env bats
# Tests for find_next_kong_port and same-site sticky-port behaviour.
#
# Regression: on prod rebuild we observed KONG_HTTPS_PORT oscillating between
# 8443 and 8444 across successive redeploys of the same site because
# find_next_kong_port scanned /opt/apps/*/.env indiscriminately and treated
# the site's own port as "in use by someone else". The Traefik dynamic config
# — only rewritten when the operator opts in — was then left pointing at the
# stale port, producing site-wide 502s.

load 'helpers/common'

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DEPLOY_SITE="$REPO_ROOT/deploy-site.sh"

setup() {
    setup_mocks
    APPS_DIR="$BATS_TEST_TMPDIR/apps"
    mkdir -p "$APPS_DIR"
    export APPS_DIR
    # Mock `ss` so port detection doesn't consult the real host.
    create_mock_with_body "ss" 'exit 0'  # empty output → no listeners
}

teardown() {
    teardown_mocks
}

# ── baseline behaviour ────────────────────────────────────────────────────────

@test "find_next_kong_port: returns 8443 when no other site has claimed it" {
    run bash -c "source '$DEPLOY_SITE'; find_next_kong_port 8443"
    [ "$status" -eq 0 ]
    [ "$output" = "8443" ]
}

@test "find_next_kong_port: skips ports already claimed by other sites" {
    mkdir -p "$APPS_DIR/other-site"
    echo "KONG_HTTPS_PORT=8443" > "$APPS_DIR/other-site/.env"
    run bash -c "source '$DEPLOY_SITE'; find_next_kong_port 8443"
    [ "$status" -eq 0 ]
    [ "$output" = "8444" ]
}

@test "find_next_kong_port: skips ports occupied by a live listener" {
    # Mock `ss` to report something listening on :8443.
    create_mock_with_body "ss" 'echo "LISTEN 0 128 0.0.0.0:8443 0.0.0.0:*"'
    run bash -c "source '$DEPLOY_SITE'; find_next_kong_port 8443"
    [ "$status" -eq 0 ]
    [ "$output" = "8444" ]
}

# ── the bug — same-site redeploy must be idempotent ──────────────────────────

@test "find_next_kong_port: does NOT count the caller's own .env against itself" {
    # Simulate a redeploy of "velaair": its .env already records the port
    # it was previously assigned. find_next_kong_port must let the caller
    # exclude that file so the port stays sticky.
    mkdir -p "$APPS_DIR/velaair"
    echo "KONG_HTTPS_PORT=8443" > "$APPS_DIR/velaair/.env"
    run bash -c "source '$DEPLOY_SITE'; find_next_kong_port 8443 '$APPS_DIR/velaair/.env'"
    [ "$status" -eq 0 ]
    [ "$output" = "8443" ]
}

@test "find_next_kong_port: still avoids other sites even when self-excluded" {
    mkdir -p "$APPS_DIR/velaair" "$APPS_DIR/othersite"
    echo "KONG_HTTPS_PORT=8443" > "$APPS_DIR/velaair/.env"
    echo "KONG_HTTPS_PORT=8444" > "$APPS_DIR/othersite/.env"
    run bash -c "source '$DEPLOY_SITE'; find_next_kong_port 8443 '$APPS_DIR/velaair/.env'"
    [ "$status" -eq 0 ]
    # 8443 is free (self-excluded), 8444 is used by othersite → picks 8443.
    [ "$output" = "8443" ]
}

@test "find_next_kong_port: exclude-file argument is optional (back-compat)" {
    mkdir -p "$APPS_DIR/othersite"
    echo "KONG_HTTPS_PORT=8443" > "$APPS_DIR/othersite/.env"
    run bash -c "source '$DEPLOY_SITE'; find_next_kong_port 8443"
    [ "$status" -eq 0 ]
    [ "$output" = "8444" ]
}
