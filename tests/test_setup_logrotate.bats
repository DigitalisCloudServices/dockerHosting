#!/usr/bin/env bats
# Comprehensive tests for scripts/setup-logrotate.sh
# Tests log rotation configuration, file generation, rotation settings, and idempotency.

load 'helpers/common'

SCRIPT="$REPO_ROOT/scripts/setup-logrotate.sh"
SITE_NAME="testsite"
DEPLOY_DIR="/opt/testsite"

setup() {
    setup_mocks

    # Set up test environment paths
    export LOGROTATE_DIR="$BATS_TEST_TMPDIR/logrotate.d"
    mkdir -p "$LOGROTATE_DIR"

    # Mock system commands
    create_mock "chmod"
    create_mock "logrotate"

    # Track command invocations
    CHMOD_LOG="$BATS_TEST_TMPDIR/chmod.log"
    LOGROTATE_LOG="$BATS_TEST_TMPDIR/logrotate.log"

    # Create wrapper script to override paths for testing
    export SCRIPT_WRAPPER="$BATS_TEST_TMPDIR/setup-logrotate-wrapper.sh"
    cat > "$SCRIPT_WRAPPER" <<EOF
#!/bin/bash
# Override /etc/logrotate.d with test directory
export LOGROTATE_CONFIG="$LOGROTATE_DIR/\$1"
$(cat "$SCRIPT" | sed 's|LOGROTATE_CONFIG="/etc/logrotate.d/$SITE_NAME"|LOGROTATE_CONFIG="$LOGROTATE_DIR/$SITE_NAME"|g')
EOF
    chmod +x "$SCRIPT_WRAPPER"
}

teardown() {
    teardown_mocks
    rm -rf "$LOGROTATE_DIR"
}

# ── Argument validation ───────────────────────────────────────────────────────

@test "setup-logrotate: exits 1 with no arguments" {
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
}

@test "setup-logrotate: prints usage with no arguments" {
    run bash "$SCRIPT"
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"ERROR"* ]]
}

@test "setup-logrotate: prints usage mentioning site_name and deploy_dir" {
    run bash "$SCRIPT"
    [[ "$output" == *"site_name"* ]]
    [[ "$output" == *"deploy_dir"* ]]
}

@test "setup-logrotate: exits 1 with only site name" {
    run bash "$SCRIPT" "$SITE_NAME"
    [ "$status" -eq 1 ]
}

@test "setup-logrotate: accepts both required arguments" {
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Setting up log rotation"* ]]
}

# ── logrotate.d file generation ───────────────────────────────────────────────

@test "setup-logrotate: creates logrotate config file with correct name" {
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    CONFIG_FILE="$LOGROTATE_DIR/$SITE_NAME"
    [ -f "$CONFIG_FILE" ]
}

@test "setup-logrotate: uses template when available" {
    # Template exists in real repo
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Using logrotate.conf.template"* ]]
}

@test "setup-logrotate: replaces SITE_NAME placeholder in template" {
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    CONFIG_FILE="$LOGROTATE_DIR/$SITE_NAME"
    assert_file_exists "$CONFIG_FILE"
    assert_file_contains "$CONFIG_FILE" "$SITE_NAME"
    refute_file_contains "$CONFIG_FILE" "{{SITE_NAME}}"
}

@test "setup-logrotate: replaces DEPLOY_DIR placeholder in template" {
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    CONFIG_FILE="$LOGROTATE_DIR/$SITE_NAME"
    assert_file_exists "$CONFIG_FILE"
    assert_file_contains "$CONFIG_FILE" "$DEPLOY_DIR"
    refute_file_contains "$CONFIG_FILE" "{{DEPLOY_DIR}}"
}

@test "setup-logrotate: creates default config when template missing" {
    # Remove template temporarily by using wrapper without template dir
    TEMP_WRAPPER="$BATS_TEST_TMPDIR/no-template-wrapper.sh"
    cat > "$TEMP_WRAPPER" <<EOF
#!/bin/bash
export LOGROTATE_CONFIG="$LOGROTATE_DIR/\$1"
$(cat "$SCRIPT" | sed 's|TEMPLATE_DIR=.*|TEMPLATE_DIR="/nonexistent"|g' | sed 's|LOGROTATE_CONFIG="/etc/logrotate.d/$SITE_NAME"|LOGROTATE_CONFIG="$LOGROTATE_DIR/$SITE_NAME"|g')
EOF
    chmod +x "$TEMP_WRAPPER"

    run bash "$TEMP_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Creating default logrotate configuration"* ]]

    CONFIG_FILE="$LOGROTATE_DIR/$SITE_NAME"
    assert_file_exists "$CONFIG_FILE"
}

@test "setup-logrotate: default config contains site name" {
    TEMP_WRAPPER="$BATS_TEST_TMPDIR/no-template-wrapper.sh"
    cat > "$TEMP_WRAPPER" <<EOF
#!/bin/bash
export LOGROTATE_CONFIG="$LOGROTATE_DIR/\$1"
$(cat "$SCRIPT" | sed 's|TEMPLATE_DIR=.*|TEMPLATE_DIR="/nonexistent"|g' | sed 's|LOGROTATE_CONFIG="/etc/logrotate.d/$SITE_NAME"|LOGROTATE_CONFIG="$LOGROTATE_DIR/$SITE_NAME"|g')
EOF
    chmod +x "$TEMP_WRAPPER"

    run bash "$TEMP_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    CONFIG_FILE="$LOGROTATE_DIR/$SITE_NAME"
    assert_file_contains "$CONFIG_FILE" "# Log rotation for $SITE_NAME"
    assert_file_contains "$CONFIG_FILE" "$DEPLOY_DIR/logs/*.log"
}

# ── Rotation settings ─────────────────────────────────────────────────────────

@test "setup-logrotate: config includes daily rotation" {
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    CONFIG_FILE="$LOGROTATE_DIR/$SITE_NAME"
    assert_file_contains "$CONFIG_FILE" "daily"
}

@test "setup-logrotate: config includes rotate 14 setting" {
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    CONFIG_FILE="$LOGROTATE_DIR/$SITE_NAME"
    assert_file_contains "$CONFIG_FILE" "rotate 14"
}

@test "setup-logrotate: config includes compress setting" {
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    CONFIG_FILE="$LOGROTATE_DIR/$SITE_NAME"
    assert_file_contains "$CONFIG_FILE" "compress"
}

@test "setup-logrotate: config includes delaycompress setting" {
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    CONFIG_FILE="$LOGROTATE_DIR/$SITE_NAME"
    assert_file_contains "$CONFIG_FILE" "delaycompress"
}

@test "setup-logrotate: config includes missingok setting" {
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    CONFIG_FILE="$LOGROTATE_DIR/$SITE_NAME"
    assert_file_contains "$CONFIG_FILE" "missingok"
}

@test "setup-logrotate: config includes notifempty setting" {
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    CONFIG_FILE="$LOGROTATE_DIR/$SITE_NAME"
    assert_file_contains "$CONFIG_FILE" "notifempty"
}

@test "setup-logrotate: config includes create directive with permissions" {
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    CONFIG_FILE="$LOGROTATE_DIR/$SITE_NAME"
    assert_file_contains "$CONFIG_FILE" "create 0640"
}

@test "setup-logrotate: config includes sharedscripts directive" {
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    CONFIG_FILE="$LOGROTATE_DIR/$SITE_NAME"
    assert_file_contains "$CONFIG_FILE" "sharedscripts"
}

# ── postrotate script ─────────────────────────────────────────────────────────

@test "setup-logrotate: config includes postrotate block" {
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    CONFIG_FILE="$LOGROTATE_DIR/$SITE_NAME"
    assert_file_contains "$CONFIG_FILE" "postrotate"
    assert_file_contains "$CONFIG_FILE" "endscript"
}

@test "setup-logrotate: postrotate includes docker compose reload for nginx" {
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    CONFIG_FILE="$LOGROTATE_DIR/$SITE_NAME"
    assert_file_contains "$CONFIG_FILE" "docker compose"
    assert_file_contains "$CONFIG_FILE" "nginx -s reload"
}

@test "setup-logrotate: postrotate uses deploy dir path" {
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    CONFIG_FILE="$LOGROTATE_DIR/$SITE_NAME"
    assert_file_contains "$CONFIG_FILE" "$DEPLOY_DIR/docker-compose"
}

@test "setup-logrotate: config includes multiple log file blocks" {
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    CONFIG_FILE="$LOGROTATE_DIR/$SITE_NAME"
    # Check for site logs block
    assert_file_contains "$CONFIG_FILE" "$DEPLOY_DIR/logs/*.log"
    # Check for nginx logs block
    assert_file_contains "$CONFIG_FILE" "$DEPLOY_DIR/nginx/logs/*.log"
    # Check for system logs block
    assert_file_contains "$CONFIG_FILE" "/var/log/$SITE_NAME/*.log"
}

# ── File permissions ──────────────────────────────────────────────────────────

@test "setup-logrotate: sets 644 permissions on config file" {
    create_call_log_mock "chmod" "$CHMOD_LOG"

    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    # Verify chmod was called with 644
    grep -q "644" "$CHMOD_LOG"
}

@test "setup-logrotate: chmod is called on the config file path" {
    create_call_log_mock "chmod" "$CHMOD_LOG"

    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    # Verify chmod was called with the correct file path
    grep -q "$LOGROTATE_DIR/$SITE_NAME" "$CHMOD_LOG"
}

@test "setup-logrotate: reports config file location" {
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Logrotate configuration created:"* ]]
}

# ── Configuration testing ─────────────────────────────────────────────────────

@test "setup-logrotate: runs logrotate debug test on config" {
    create_call_log_mock "logrotate" "$LOGROTATE_LOG"

    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    # Verify logrotate -d was called
    grep -q "\-d" "$LOGROTATE_LOG"
}

@test "setup-logrotate: reports when config test passes" {
    create_mock_with_body "logrotate" 'exit 0'

    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"test passed"* ]]
}

@test "setup-logrotate: warns when config test finds issues" {
    create_mock_with_body "logrotate" 'echo "error: some problem"; exit 0'

    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN"* ]] || [[ "$output" == *"issues"* ]]
}

# ── Idempotency ───────────────────────────────────────────────────────────────

@test "setup-logrotate: overwrites existing config file" {
    # Create initial config
    CONFIG_FILE="$LOGROTATE_DIR/$SITE_NAME"
    echo "# old config" > "$CONFIG_FILE"

    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    # Verify new config exists and old content is gone
    assert_file_exists "$CONFIG_FILE"
    refute_file_contains "$CONFIG_FILE" "# old config"
}

@test "setup-logrotate: can run multiple times successfully" {
    # First run
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    CONFIG_FILE="$LOGROTATE_DIR/$SITE_NAME"
    assert_file_exists "$CONFIG_FILE"

    # Second run
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    # Config should still exist and be valid
    assert_file_exists "$CONFIG_FILE"
    assert_file_contains "$CONFIG_FILE" "daily"
    assert_file_contains "$CONFIG_FILE" "rotate 14"
}

@test "setup-logrotate: second run produces same config content" {
    # First run
    bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    CONFIG_FILE="$LOGROTATE_DIR/$SITE_NAME"
    FIRST_CONTENT=$(cat "$CONFIG_FILE")

    # Second run
    bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    SECOND_CONTENT=$(cat "$CONFIG_FILE")

    # Content should be identical
    [ "$FIRST_CONTENT" = "$SECOND_CONTENT" ]
}

# ── Success messages ──────────────────────────────────────────────────────────

@test "setup-logrotate: prints success message" {
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"setup complete"* ]]
}

@test "setup-logrotate: includes site name in output" {
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$SITE_NAME"* ]]
}

# ── Edge cases ────────────────────────────────────────────────────────────────

@test "setup-logrotate: handles site name with hyphens" {
    HYPHENATED_SITE="my-test-site"
    run bash "$SCRIPT_WRAPPER" "$HYPHENATED_SITE" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    CONFIG_FILE="$LOGROTATE_DIR/$HYPHENATED_SITE"
    assert_file_exists "$CONFIG_FILE"
    assert_file_contains "$CONFIG_FILE" "$HYPHENATED_SITE"
}

@test "setup-logrotate: handles deploy dir with spaces in path" {
    SPACED_DIR="/opt/my site"
    run bash "$SCRIPT_WRAPPER" "$SITE_NAME" "$SPACED_DIR"
    [ "$status" -eq 0 ]

    CONFIG_FILE="$LOGROTATE_DIR/$SITE_NAME"
    assert_file_exists "$CONFIG_FILE"
    assert_file_contains "$CONFIG_FILE" "$SPACED_DIR"
}

@test "setup-logrotate: handles long site names" {
    LONG_SITE="verylongsitename$(printf 'a%.0s' {1..50})"
    run bash "$SCRIPT_WRAPPER" "$LONG_SITE" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]

    CONFIG_FILE="$LOGROTATE_DIR/$LONG_SITE"
    assert_file_exists "$CONFIG_FILE"
}
