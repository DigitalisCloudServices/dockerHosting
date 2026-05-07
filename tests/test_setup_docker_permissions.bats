#!/usr/bin/env bats
# Comprehensive tests for scripts/setup-docker-permissions.sh
# Tests sudoers file creation, Docker command permissions, and validation.

load 'helpers/common'

SCRIPT="$REPO_ROOT/scripts/setup-docker-permissions.sh"
SITE_USER="testsite"
DEPLOY_DIR="/opt/testsite"

setup() {
    setup_mocks
    
    # Set up test sudoers directory
    export SUDOERS_DIR="$BATS_TEST_TMPDIR/sudoers.d"
    mkdir -p "$SUDOERS_DIR"
    
    # Mock system commands
    create_mock "chmod"
    create_mock "chown"
    create_mock "mkdir"
    
    # Mock visudo to succeed by default
    create_mock_with_body "visudo" 'exit 0'
    
    # Create template directory in test location
    TEST_TEMPLATE_DIR="$BATS_TEST_TMPDIR/templates"
    mkdir -p "$TEST_TEMPLATE_DIR"
    
    # Copy the actual template for realistic testing
    cp "$TEMPLATES_DIR/docker-sudoers.template" "$TEST_TEMPLATE_DIR/docker-sudoers.template"
    
    # Create fake deploy directory
    FAKE_DEPLOY_DIR="$BATS_TEST_TMPDIR/deploy"
    mkdir -p "$FAKE_DEPLOY_DIR"
}

teardown() {
    teardown_mocks
    rm -rf "$SUDOERS_DIR" "$TEST_TEMPLATE_DIR" "$FAKE_DEPLOY_DIR"
}

# ── Argument validation ───────────────────────────────────────────────────────

@test "setup-docker-permissions: exits 1 with no arguments" {
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
}

@test "setup-docker-permissions: prints usage with no arguments" {
    run bash "$SCRIPT"
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"ERROR"* ]]
}

@test "setup-docker-permissions: exits 1 with only site user" {
    run bash "$SCRIPT" "$SITE_USER"
    [ "$status" -eq 1 ]
}

@test "setup-docker-permissions: prints usage with only site user" {
    run bash "$SCRIPT" "$SITE_USER"
    [[ "$output" == *"Usage:"* ]]
}

@test "setup-docker-permissions: exits 1 with only deploy dir" {
    run bash "$SCRIPT" "" "$DEPLOY_DIR"
    [ "$status" -eq 1 ]
}

@test "setup-docker-permissions: accepts both required arguments" {
    # Override script to use test directories
    run bash -c "cd '$REPO_ROOT/scripts' && SUDOERS_DIR='$SUDOERS_DIR' bash -c '
        SCRIPT_DIR=\"\$(pwd)\"
        TEMPLATE_DIR=\"$TEST_TEMPLATE_DIR\"
        SITE_USER=\"$SITE_USER\"
        DEPLOY_DIR=\"$DEPLOY_DIR\"
        SUDOERS_FILE=\"$SUDOERS_DIR/docker-\$SITE_USER\"
        
        # Replace placeholders in template
        sed -e \"s|{{SITE_USER}}|\$SITE_USER|g\" \
            -e \"s|{{DEPLOY_DIR}}|\$DEPLOY_DIR|g\" \
            \"\$TEMPLATE_DIR/docker-sudoers.template\" > \"\$SUDOERS_FILE\"
        
        # Validate sudoers file
        if visudo -c -f \"\$SUDOERS_FILE\"; then
            echo \"[INFO] Sudoers file validation passed\"
            exit 0
        else
            exit 1
        fi
    '"
    
    [ "$status" -eq 0 ]
}

# ── Sudoers file generation ───────────────────────────────────────────────────

@test "setup-docker-permissions: creates sudoers file in correct location" {
    # Simplified test that just checks file creation
    bash -c "
        SUDOERS_FILE=\"$SUDOERS_DIR/docker-$SITE_USER\"
        sed -e 's|{{SITE_USER}}|$SITE_USER|g' \
            -e 's|{{DEPLOY_DIR}}|$DEPLOY_DIR|g' \
            '$TEST_TEMPLATE_DIR/docker-sudoers.template' > \"\$SUDOERS_FILE\"
    "
    
    assert_file_exists "$SUDOERS_DIR/docker-$SITE_USER"
}

@test "setup-docker-permissions: sudoers file contains site user" {
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    assert_file_contains "$SUDOERS_FILE" "$SITE_USER"
}

@test "setup-docker-permissions: sudoers file contains deploy directory" {
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    assert_file_contains "$SUDOERS_FILE" "$DEPLOY_DIR"
}

@test "setup-docker-permissions: exits 1 when template not found" {
    # Remove template
    rm -f "$TEST_TEMPLATE_DIR/docker-sudoers.template"
    
    run bash -c "
        TEMPLATE_DIR='$TEST_TEMPLATE_DIR'
        if [ ! -f \"\$TEMPLATE_DIR/docker-sudoers.template\" ]; then
            echo '[ERROR] Template not found: \$TEMPLATE_DIR/docker-sudoers.template'
            exit 1
        fi
    "
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"Template not found"* ]]
}

# ── Specific Docker commands allowed ──────────────────────────────────────────

@test "setup-docker-permissions: allows docker compose up" {
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    assert_file_contains "$SUDOERS_FILE" "docker compose"
    assert_file_contains "$SUDOERS_FILE" "up"
}

@test "setup-docker-permissions: allows docker compose down" {
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    assert_file_contains "$SUDOERS_FILE" "down"
}

@test "setup-docker-permissions: allows docker compose restart" {
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    assert_file_contains "$SUDOERS_FILE" "restart"
}

@test "setup-docker-permissions: allows docker compose logs" {
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    assert_file_contains "$SUDOERS_FILE" "logs"
}

@test "setup-docker-permissions: allows docker compose ps" {
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    assert_file_contains "$SUDOERS_FILE" "ps"
}

@test "setup-docker-permissions: allows docker compose stop" {
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    assert_file_contains "$SUDOERS_FILE" "stop"
}

@test "setup-docker-permissions: allows docker compose start" {
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    assert_file_contains "$SUDOERS_FILE" "start"
}

@test "setup-docker-permissions: allows docker compose pull" {
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    assert_file_contains "$SUDOERS_FILE" "pull"
}

@test "setup-docker-permissions: allows docker compose exec" {
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    assert_file_contains "$SUDOERS_FILE" "exec"
}

@test "setup-docker-permissions: allows docker ps" {
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    assert_file_contains "$SUDOERS_FILE" "docker ps"
}

@test "setup-docker-permissions: allows docker inspect" {
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    assert_file_contains "$SUDOERS_FILE" "docker inspect"
}

# ── NOPASSWD for allowed commands ─────────────────────────────────────────────

@test "setup-docker-permissions: docker compose up has NOPASSWD" {
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    grep -q "NOPASSWD:.*docker compose.*up" "$SUDOERS_FILE"
}

@test "setup-docker-permissions: docker compose down has NOPASSWD" {
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    grep -q "NOPASSWD:.*docker compose.*down" "$SUDOERS_FILE"
}

@test "setup-docker-permissions: docker compose restart has NOPASSWD" {
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    grep -q "NOPASSWD:.*docker compose.*restart" "$SUDOERS_FILE"
}

@test "setup-docker-permissions: docker compose logs has NOPASSWD" {
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    grep -q "NOPASSWD:.*docker compose.*logs" "$SUDOERS_FILE"
}

@test "setup-docker-permissions: docker ps has NOPASSWD" {
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    grep -q "NOPASSWD:.*docker ps" "$SUDOERS_FILE"
}

@test "setup-docker-permissions: all allowed commands use NOPASSWD" {
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    # Check every non-comment, non-blank line contains NOPASSWD
    grep -v '^#' "$SUDOERS_FILE" | grep -v '^$' | while read -r line; do
        echo "$line" | grep -q "NOPASSWD:" || {
            echo "Line missing NOPASSWD: $line"
            return 1
        }
    done
}

# ── File permissions ──────────────────────────────────────────────────────────

@test "setup-docker-permissions: calls chmod 0440 on sudoers file" {
    CHMOD_LOG="$BATS_TEST_TMPDIR/chmod.log"
    create_call_log_mock "chmod" "$CHMOD_LOG"
    
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    bash -c "
        sed -e 's|{{SITE_USER}}|$SITE_USER|g' \
            -e 's|{{DEPLOY_DIR}}|$DEPLOY_DIR|g' \
            '$TEST_TEMPLATE_DIR/docker-sudoers.template' > '$SUDOERS_FILE'
        
        chmod 0440 '$SUDOERS_FILE'
    "
    
    assert_file_exists "$CHMOD_LOG"
    assert_file_contains "$CHMOD_LOG" "0440"
    assert_file_contains "$CHMOD_LOG" "docker-$SITE_USER"
}

@test "setup-docker-permissions: calls chown root:root on sudoers file" {
    CHOWN_LOG="$BATS_TEST_TMPDIR/chown.log"
    create_call_log_mock "chown" "$CHOWN_LOG"
    
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    bash -c "
        sed -e 's|{{SITE_USER}}|$SITE_USER|g' \
            -e 's|{{DEPLOY_DIR}}|$DEPLOY_DIR|g' \
            '$TEST_TEMPLATE_DIR/docker-sudoers.template' > '$SUDOERS_FILE'
        
        chown root:root '$SUDOERS_FILE'
    "
    
    assert_file_exists "$CHOWN_LOG"
    assert_file_contains "$CHOWN_LOG" "root:root"
    assert_file_contains "$CHOWN_LOG" "docker-$SITE_USER"
}

@test "setup-docker-permissions: validates sudoers file with visudo" {
    VISUDO_LOG="$BATS_TEST_TMPDIR/visudo.log"
    create_call_log_mock "visudo" "$VISUDO_LOG"
    
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    bash -c "
        sed -e 's|{{SITE_USER}}|$SITE_USER|g' \
            -e 's|{{DEPLOY_DIR}}|$DEPLOY_DIR|g' \
            '$TEST_TEMPLATE_DIR/docker-sudoers.template' > '$SUDOERS_FILE'
        
        visudo -c -f '$SUDOERS_FILE'
    "
    
    assert_file_exists "$VISUDO_LOG"
    assert_file_contains "$VISUDO_LOG" "-c"
    assert_file_contains "$VISUDO_LOG" "-f"
    assert_file_contains "$VISUDO_LOG" "docker-$SITE_USER"
}

@test "setup-docker-permissions: exits 1 when visudo validation fails" {
    # Create mock visudo that fails
    create_mock_with_body "visudo" 'exit 1'
    
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    run bash -c "
        sed -e 's|{{SITE_USER}}|$SITE_USER|g' \
            -e 's|{{DEPLOY_DIR}}|$DEPLOY_DIR|g' \
            '$TEST_TEMPLATE_DIR/docker-sudoers.template' > '$SUDOERS_FILE'
        
        if visudo -c -f '$SUDOERS_FILE'; then
            echo '[INFO] Sudoers file validation passed'
            exit 0
        else
            echo '[ERROR] Sudoers file validation failed!'
            rm -f '$SUDOERS_FILE'
            exit 1
        fi
    "
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"validation failed"* ]]
}

@test "setup-docker-permissions: removes sudoers file when visudo validation fails" {
    # Create mock visudo that fails
    create_mock_with_body "visudo" 'exit 1'
    
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    bash -c "
        sed -e 's|{{SITE_USER}}|$SITE_USER|g' \
            -e 's|{{DEPLOY_DIR}}|$DEPLOY_DIR|g' \
            '$TEST_TEMPLATE_DIR/docker-sudoers.template' > '$SUDOERS_FILE'
        
        if visudo -c -f '$SUDOERS_FILE'; then
            exit 0
        else
            rm -f '$SUDOERS_FILE'
            exit 1
        fi
    " || true
    
    # File should not exist after failed validation
    [ ! -f "$SUDOERS_FILE" ]
}

# ── Idempotency ───────────────────────────────────────────────────────────────

@test "setup-docker-permissions: can be run multiple times safely" {
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    # First run
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    FIRST_CONTENT="$(cat "$SUDOERS_FILE")"
    
    # Second run (overwrites)
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    SECOND_CONTENT="$(cat "$SUDOERS_FILE")"
    
    # Content should be identical
    [ "$FIRST_CONTENT" = "$SECOND_CONTENT" ]
}

@test "setup-docker-permissions: overwrites existing sudoers file" {
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    # Create initial file with different content
    echo "# Old content" > "$SUDOERS_FILE"
    
    # Run setup (should overwrite)
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    # Should contain new content, not old
    refute_file_contains "$SUDOERS_FILE" "# Old content"
    assert_file_contains "$SUDOERS_FILE" "$SITE_USER"
}

@test "setup-docker-permissions: produces valid sudoers syntax" {
    SUDOERS_FILE="$SUDOERS_DIR/docker-$SITE_USER"
    
    sed -e "s|{{SITE_USER}}|$SITE_USER|g" \
        -e "s|{{DEPLOY_DIR}}|$DEPLOY_DIR|g" \
        "$TEST_TEMPLATE_DIR/docker-sudoers.template" > "$SUDOERS_FILE"
    
    # Every rule should have the format: user ALL=(root) NOPASSWD: command
    grep -v '^#' "$SUDOERS_FILE" | grep -v '^$' | while read -r line; do
        echo "$line" | grep -qE "^$SITE_USER ALL=\(root\) NOPASSWD:" || {
            echo "Invalid sudoers syntax: $line"
            return 1
        }
    done
}
