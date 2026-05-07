#!/usr/bin/env bats
# Comprehensive tests for scripts/setup-users.sh
# Tests user creation, directory ownership, permissions, and error handling.

load 'helpers/common'

SCRIPT="$REPO_ROOT/scripts/setup-users.sh"
SITE_NAME="testsite"
DEPLOY_DIR="/opt/testsite"

setup() {
    setup_mocks
    
    # Mock system commands
    create_mock "useradd"
    create_mock "chown"
    create_mock "chmod"
    create_mock "mkdir"
    create_mock "find"
    
    # Mock id to return user not found initially
    create_mock_with_body "id" 'exit 1'
    
    # Create fake deploy directory for tests
    FAKE_DEPLOY_DIR="$BATS_TEST_TMPDIR/deploy"
    mkdir -p "$FAKE_DEPLOY_DIR"
    
    # Create test files with different extensions
    touch "$FAKE_DEPLOY_DIR/script.sh"
    touch "$FAKE_DEPLOY_DIR/.env"
    touch "$FAKE_DEPLOY_DIR/.env.production"
    touch "$FAKE_DEPLOY_DIR/config.yml"
    mkdir -p "$FAKE_DEPLOY_DIR/subdir"
    touch "$FAKE_DEPLOY_DIR/subdir/file.txt"
    
    # Mock helper scripts to prevent them from running
    create_mock "setup-docker-permissions.sh"
    create_mock "setup-docker-network.sh"
}

teardown() {
    teardown_mocks
    rm -rf "$FAKE_DEPLOY_DIR"
}

# ── Argument validation ───────────────────────────────────────────────────────

@test "setup-users: exits 1 with no arguments" {
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
}

@test "setup-users: prints usage with no arguments" {
    run bash "$SCRIPT"
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"ERROR"* ]]
}

@test "setup-users: exits 1 with only site name" {
    run bash "$SCRIPT" "$SITE_NAME"
    [ "$status" -eq 1 ]
}

@test "setup-users: prints usage with only site name" {
    run bash "$SCRIPT" "$SITE_NAME"
    [[ "$output" == *"Usage:"* ]]
}

@test "setup-users: exits 1 with only deploy dir" {
    run bash "$SCRIPT" "" "$DEPLOY_DIR"
    [ "$status" -eq 1 ]
}

@test "setup-users: accepts both required arguments" {
    CALL_LOG="$BATS_TEST_TMPDIR/useradd.log"
    create_call_log_mock "useradd" "$CALL_LOG"
    
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    [ "$status" -eq 0 ]
}

# ── User creation ─────────────────────────────────────────────────────────────

@test "setup-users: creates system user with nologin shell" {
    CALL_LOG="$BATS_TEST_TMPDIR/useradd.log"
    create_call_log_mock "useradd" "$CALL_LOG"
    
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    
    assert_file_exists "$CALL_LOG"
    assert_file_contains "$CALL_LOG" "-r"
    assert_file_contains "$CALL_LOG" "-M"
    assert_file_contains "$CALL_LOG" "/usr/sbin/nologin"
    assert_file_contains "$CALL_LOG" "$SITE_NAME"
}

@test "setup-users: sets home directory reference to deploy dir" {
    CALL_LOG="$BATS_TEST_TMPDIR/useradd.log"
    create_call_log_mock "useradd" "$CALL_LOG"
    
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    
    assert_file_contains "$CALL_LOG" "-d $DEPLOY_DIR"
}

@test "setup-users: confirms user creation in output" {
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    
    [[ "$output" == *"Created system user: $SITE_NAME"* ]]
    [[ "$output" == *"nologin"* ]]
}

@test "setup-users: mentions controlled Docker access" {
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    
    [[ "$output" == *"controlled Docker access via sudo"* ]]
}

# ── Idempotency ───────────────────────────────────────────────────────────────

@test "setup-users: detects existing user and skips creation" {
    # Mock id to return success (user exists)
    create_mock_with_body "id" 'exit 0'
    
    CALL_LOG="$BATS_TEST_TMPDIR/useradd.log"
    create_call_log_mock "useradd" "$CALL_LOG"
    
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    
    # useradd should NOT be called
    [ ! -s "$CALL_LOG" ]
    [[ "$output" == *"User $SITE_NAME already exists"* ]]
}

@test "setup-users: continues with permissions even if user exists" {
    create_mock_with_body "id" 'exit 0'
    
    CHOWN_LOG="$BATS_TEST_TMPDIR/chown.log"
    create_call_log_mock "chown" "$CHOWN_LOG"
    
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    
    [ "$status" -eq 0 ]
    # chown should still be called
    [ -s "$CHOWN_LOG" ]
}

# ── Directory creation and ownership ──────────────────────────────────────────

@test "setup-users: creates log directory for site" {
    MKDIR_LOG="$BATS_TEST_TMPDIR/mkdir.log"
    create_call_log_mock "mkdir" "$MKDIR_LOG"
    
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    
    assert_file_contains "$MKDIR_LOG" "-p /var/log/$SITE_NAME"
}

@test "setup-users: sets ownership of log directory" {
    CHOWN_LOG="$BATS_TEST_TMPDIR/chown.log"
    create_call_log_mock "chown" "$CHOWN_LOG"
    
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    
    assert_file_contains "$CHOWN_LOG" "-R $SITE_NAME:$SITE_NAME /var/log/$SITE_NAME"
}

@test "setup-users: sets ownership of deploy directory" {
    CHOWN_LOG="$BATS_TEST_TMPDIR/chown.log"
    create_call_log_mock "chown" "$CHOWN_LOG"
    
    run bash "$SCRIPT" "$SITE_NAME" "$FAKE_DEPLOY_DIR"
    
    assert_file_contains "$CHOWN_LOG" "-R $SITE_NAME:$SITE_NAME $FAKE_DEPLOY_DIR"
}

@test "setup-users: confirms ownership changes in output" {
    run bash "$SCRIPT" "$SITE_NAME" "$FAKE_DEPLOY_DIR"
    
    [[ "$output" == *"Set ownership of $FAKE_DEPLOY_DIR to $SITE_NAME:$SITE_NAME"* ]]
}

# ── Directory permissions ─────────────────────────────────────────────────────

@test "setup-users: sets 755 permissions on directories" {
    FIND_LOG="$BATS_TEST_TMPDIR/find.log"
    create_call_log_mock "find" "$FIND_LOG"
    
    run bash "$SCRIPT" "$SITE_NAME" "$FAKE_DEPLOY_DIR"
    
    assert_file_contains "$FIND_LOG" "-type d"
    assert_file_contains "$FIND_LOG" "chmod 755"
}

@test "setup-users: sets 644 permissions on regular files" {
    FIND_LOG="$BATS_TEST_TMPDIR/find.log"
    create_call_log_mock "find" "$FIND_LOG"
    
    run bash "$SCRIPT" "$SITE_NAME" "$FAKE_DEPLOY_DIR"
    
    assert_file_contains "$FIND_LOG" "-type f"
    assert_file_contains "$FIND_LOG" "chmod 644"
}

@test "setup-users: sets 755 permissions on shell scripts" {
    FIND_LOG="$BATS_TEST_TMPDIR/find.log"
    create_call_log_mock "find" "$FIND_LOG"
    
    run bash "$SCRIPT" "$SITE_NAME" "$FAKE_DEPLOY_DIR"
    
    assert_file_contains "$FIND_LOG" '*.sh'
    assert_file_contains "$FIND_LOG" "chmod 755"
}

@test "setup-users: sets 600 permissions on .env files" {
    FIND_LOG="$BATS_TEST_TMPDIR/find.log"
    create_call_log_mock "find" "$FIND_LOG"
    
    run bash "$SCRIPT" "$SITE_NAME" "$FAKE_DEPLOY_DIR"
    
    assert_file_contains "$FIND_LOG" '.env*'
    assert_file_contains "$FIND_LOG" "chmod 600"
}

@test "setup-users: confirms permission changes in output" {
    run bash "$SCRIPT" "$SITE_NAME" "$FAKE_DEPLOY_DIR"
    
    [[ "$output" == *"Set permissions for $FAKE_DEPLOY_DIR"* ]]
}

@test "setup-users: skips permission setting if deploy dir does not exist" {
    NONEXISTENT_DIR="/nonexistent/path"
    
    FIND_LOG="$BATS_TEST_TMPDIR/find.log"
    create_call_log_mock "find" "$FIND_LOG"
    
    run bash "$SCRIPT" "$SITE_NAME" "$NONEXISTENT_DIR"
    
    # find should not be called for the deploy dir
    if [ -f "$FIND_LOG" ]; then
        refute_file_contains "$FIND_LOG" "$NONEXISTENT_DIR"
    fi
}

# ── SSH directory creation ────────────────────────────────────────────────────

@test "setup-users: creates .ssh directory in deploy dir" {
    MKDIR_LOG="$BATS_TEST_TMPDIR/mkdir.log"
    create_call_log_mock "mkdir" "$MKDIR_LOG"
    
    run bash "$SCRIPT" "$SITE_NAME" "$FAKE_DEPLOY_DIR"
    
    assert_file_contains "$MKDIR_LOG" "-p $FAKE_DEPLOY_DIR/.ssh"
}

@test "setup-users: sets ownership of .ssh directory" {
    CHOWN_LOG="$BATS_TEST_TMPDIR/chown.log"
    create_call_log_mock "chown" "$CHOWN_LOG"
    
    run bash "$SCRIPT" "$SITE_NAME" "$FAKE_DEPLOY_DIR"
    
    assert_file_contains "$CHOWN_LOG" "$SITE_NAME:$SITE_NAME $FAKE_DEPLOY_DIR/.ssh"
}

@test "setup-users: sets 700 permissions on .ssh directory" {
    CHMOD_LOG="$BATS_TEST_TMPDIR/chmod.log"
    create_call_log_mock "chmod" "$CHMOD_LOG"
    
    run bash "$SCRIPT" "$SITE_NAME" "$FAKE_DEPLOY_DIR"
    
    assert_file_contains "$CHMOD_LOG" "700 $FAKE_DEPLOY_DIR/.ssh"
}

@test "setup-users: skips .ssh creation if it already exists" {
    mkdir -p "$FAKE_DEPLOY_DIR/.ssh"
    
    MKDIR_LOG="$BATS_TEST_TMPDIR/mkdir.log"
    create_call_log_mock "mkdir" "$MKDIR_LOG"
    
    run bash "$SCRIPT" "$SITE_NAME" "$FAKE_DEPLOY_DIR"
    
    # mkdir should not be called for .ssh (but might be called for log dir)
    if grep -q "\.ssh" "$MKDIR_LOG" 2>/dev/null; then
        echo ".ssh directory should not be recreated"
        return 1
    fi
}

# ── Helper script invocation ──────────────────────────────────────────────────

@test "setup-users: calls setup-docker-permissions.sh when present" {
    DOCKER_PERM_LOG="$BATS_TEST_TMPDIR/docker-perm.log"
    create_call_log_mock "setup-docker-permissions.sh" "$DOCKER_PERM_LOG"
    
    # Create mock script in same directory
    cp "$MOCK_BIN/setup-docker-permissions.sh" "$REPO_ROOT/scripts/setup-docker-permissions.sh"
    
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    
    assert_file_contains "$DOCKER_PERM_LOG" "$SITE_NAME $DEPLOY_DIR"
    
    rm -f "$REPO_ROOT/scripts/setup-docker-permissions.sh"
}

@test "setup-users: calls setup-docker-network.sh when present" {
    DOCKER_NET_LOG="$BATS_TEST_TMPDIR/docker-net.log"
    create_call_log_mock "setup-docker-network.sh" "$DOCKER_NET_LOG"
    
    # Create mock script in same directory
    cp "$MOCK_BIN/setup-docker-network.sh" "$REPO_ROOT/scripts/setup-docker-network.sh"
    
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    
    assert_file_contains "$DOCKER_NET_LOG" "$SITE_NAME"
    
    rm -f "$REPO_ROOT/scripts/setup-docker-network.sh"
}

@test "setup-users: warns if setup-docker-permissions.sh is missing" {
    # Ensure the script doesn't exist
    rm -f "$REPO_ROOT/scripts/setup-docker-permissions.sh"
    
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    
    [[ "$output" == *"WARN"* ]]
    [[ "$output" == *"setup-docker-permissions.sh not found"* ]]
}

@test "setup-users: warns if setup-docker-network.sh is missing" {
    # Ensure the script doesn't exist
    rm -f "$REPO_ROOT/scripts/setup-docker-network.sh"
    
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    
    [[ "$output" == *"WARN"* ]]
    [[ "$output" == *"setup-docker-network.sh not found"* ]]
}

# ── Error handling ────────────────────────────────────────────────────────────

@test "setup-users: exits non-zero if useradd fails" {
    # Mock useradd to fail
    create_mock_with_body "useradd" 'exit 9'
    
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    
    [ "$status" -ne 0 ]
}

@test "setup-users: exits non-zero if mkdir fails" {
    # Mock mkdir to fail
    create_mock_with_body "mkdir" 'exit 1'
    
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    
    [ "$status" -ne 0 ]
}

@test "setup-users: exits non-zero if chown fails" {
    # Mock chown to fail
    create_mock_with_body "chown" 'exit 1'
    
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    
    [ "$status" -ne 0 ]
}

@test "setup-users: handles special characters in site name safely" {
    SAFE_SITE="test-site_123"
    
    CALL_LOG="$BATS_TEST_TMPDIR/useradd.log"
    create_call_log_mock "useradd" "$CALL_LOG"
    
    run bash "$SCRIPT" "$SAFE_SITE" "$DEPLOY_DIR"
    
    [ "$status" -eq 0 ]
    assert_file_contains "$CALL_LOG" "$SAFE_SITE"
}

# ── Completion message ────────────────────────────────────────────────────────

@test "setup-users: prints completion message on success" {
    run bash "$SCRIPT" "$SITE_NAME" "$DEPLOY_DIR"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"User and permissions setup complete for $SITE_NAME"* ]]
}

@test "setup-users: prints info messages for all major steps" {
    run bash "$SCRIPT" "$SITE_NAME" "$FAKE_DEPLOY_DIR"
    
    [[ "$output" == *"Setting up user and permissions"* ]]
    [[ "$output" == *"Created log directory"* ]]
    [[ "$output" == *"Set ownership"* ]]
    [[ "$output" == *"Set permissions"* ]]
    [[ "$output" == *"Created SSH directory"* ]]
}
