#!/usr/bin/env bats
# Comprehensive tests for scripts/setup-secret-scan.sh
# Tests gitleaks installation, pre-commit hook setup, configuration, and secret scanning.

load 'helpers/common'

SCRIPT="$REPO_ROOT/scripts/setup-secret-scan.sh"

setup() {
    setup_mocks
    
    # Create a fake git repository
    FAKE_REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$FAKE_REPO/.git/hooks"
    
    # Mock system commands
    create_mock "curl"
    create_mock "tar"
    create_mock "sha256sum"
    create_mock "install"
    create_mock "grep"
    create_mock "sed"
    create_mock "chmod"
    
    # Mock uname to return x86_64 architecture
    create_mock_with_body "uname" 'echo "x86_64"'
    
    # Mock gitleaks command (not installed initially)
    create_mock_with_body "command" 'exit 1'
    
    # Mock gitleaks version output
    create_mock_with_body "gitleaks" 'if [[ "$1" == "version" ]]; then echo "v8.18.0"; else exit 0; fi'
}

teardown() {
    teardown_mocks
    rm -rf "$FAKE_REPO"
}

# ── Argument parsing ──────────────────────────────────────────────────────────

@test "setup-secret-scan: uses current directory by default" {
    cd "$FAKE_REPO"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$FAKE_REPO/.git/hooks/pre-commit" ]
}

@test "setup-secret-scan: accepts custom repository path" {
    run bash "$SCRIPT" "$FAKE_REPO"
    [ "$status" -eq 0 ]
    [ -f "$FAKE_REPO/.git/hooks/pre-commit" ]
}

@test "setup-secret-scan: accepts --force flag" {
    # Mock command to show gitleaks exists
    create_mock_with_body "command" 'exit 0'
    
    CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
    create_call_log_mock "curl" "$CURL_LOG"
    
    run bash "$SCRIPT" "$FAKE_REPO" --force
    [ "$status" -eq 0 ]
    # Should reinstall even though gitleaks exists
    [ -s "$CURL_LOG" ]
}

@test "setup-secret-scan: rejects unknown options" {
    run bash "$SCRIPT" --unknown
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR"* ]]
    [[ "$output" == *"Unknown option"* ]]
}

@test "setup-secret-scan: accepts repo path and --force in any order" {
    CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
    create_call_log_mock "curl" "$CURL_LOG"
    
    run bash "$SCRIPT" --force "$FAKE_REPO"
    [ "$status" -eq 0 ]
    [ -f "$FAKE_REPO/.git/hooks/pre-commit" ]
}

# ── Gitleaks installation ─────────────────────────────────────────────────────

@test "setup-secret-scan: downloads latest gitleaks release" {
    CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
    create_call_log_mock "curl" "$CURL_LOG"
    
    # Mock GitHub API response for version
    create_mock_with_body "grep" 'echo "\"tag_name\": \"v8.18.0\""'
    create_mock_with_body "sed" 'echo "8.18.0"'
    
    run bash "$SCRIPT" "$FAKE_REPO"
    
    [ "$status" -eq 0 ]
    [ -s "$CURL_LOG" ]
    assert_file_contains "$CURL_LOG" "github.com/gitleaks/gitleaks"
}

@test "setup-secret-scan: detects x86_64 architecture" {
    create_mock_with_body "uname" 'echo "x86_64"'
    
    CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
    create_call_log_mock "curl" "$CURL_LOG"
    
    create_mock_with_body "grep" 'echo "\"tag_name\": \"v8.18.0\""'
    create_mock_with_body "sed" 'echo "8.18.0"'
    
    run bash "$SCRIPT" "$FAKE_REPO"
    
    assert_file_contains "$CURL_LOG" "x64"
}

@test "setup-secret-scan: detects aarch64 architecture" {
    create_mock_with_body "uname" 'echo "aarch64"'
    
    CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
    create_call_log_mock "curl" "$CURL_LOG"
    
    create_mock_with_body "grep" 'echo "\"tag_name\": \"v8.18.0\""'
    create_mock_with_body "sed" 'echo "8.18.0"'
    
    run bash "$SCRIPT" "$FAKE_REPO"
    
    assert_file_contains "$CURL_LOG" "arm64"
}

@test "setup-secret-scan: exits on unsupported architecture" {
    create_mock_with_body "uname" 'echo "armv7l"'
    
    run bash "$SCRIPT" "$FAKE_REPO"
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unsupported architecture"* ]]
}

@test "setup-secret-scan: verifies checksum of downloaded tarball" {
    SHA256_LOG="$BATS_TEST_TMPDIR/sha256sum.log"
    create_call_log_mock "sha256sum" "$SHA256_LOG"
    
    create_mock_with_body "grep" 'echo "\"tag_name\": \"v8.18.0\""'
    create_mock_with_body "sed" 'echo "8.18.0"'
    
    run bash "$SCRIPT" "$FAKE_REPO"
    
    [ "$status" -eq 0 ]
    [ -s "$SHA256_LOG" ]
    assert_file_contains "$SHA256_LOG" "-c"
}

@test "setup-secret-scan: downloads checksums file" {
    CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
    create_call_log_mock "curl" "$CURL_LOG"
    
    create_mock_with_body "grep" 'echo "\"tag_name\": \"v8.18.0\""'
    create_mock_with_body "sed" 'echo "8.18.0"'
    
    run bash "$SCRIPT" "$FAKE_REPO"
    
    assert_file_contains "$CURL_LOG" "checksums.txt"
}

@test "setup-secret-scan: extracts gitleaks binary from tarball" {
    TAR_LOG="$BATS_TEST_TMPDIR/tar.log"
    create_call_log_mock "tar" "$TAR_LOG"
    
    create_mock_with_body "grep" 'echo "\"tag_name\": \"v8.18.0\""'
    create_mock_with_body "sed" 'echo "8.18.0"'
    
    run bash "$SCRIPT" "$FAKE_REPO"
    
    [ -s "$TAR_LOG" ]
    assert_file_contains "$TAR_LOG" "-xzf"
    assert_file_contains "$TAR_LOG" "gitleaks"
}

@test "setup-secret-scan: installs binary to /usr/local/bin" {
    INSTALL_LOG="$BATS_TEST_TMPDIR/install.log"
    create_call_log_mock "install" "$INSTALL_LOG"
    
    create_mock_with_body "grep" 'echo "\"tag_name\": \"v8.18.0\""'
    create_mock_with_body "sed" 'echo "8.18.0"'
    
    run bash "$SCRIPT" "$FAKE_REPO"
    
    assert_file_contains "$INSTALL_LOG" "-m 0755"
    assert_file_contains "$INSTALL_LOG" "/usr/local/bin/gitleaks"
}

@test "setup-secret-scan: exits if version cannot be determined" {
    # Mock grep/sed to return empty string
    create_mock_with_body "grep" 'exit 0'
    create_mock_with_body "sed" 'echo ""'
    
    run bash "$SCRIPT" "$FAKE_REPO"
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not determine latest gitleaks version"* ]]
}

# ── Idempotency ───────────────────────────────────────────────────────────────

@test "setup-secret-scan: skips installation if gitleaks exists" {
    # Mock command to show gitleaks exists
    create_mock_with_body "command" 'exit 0'
    
    CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
    create_call_log_mock "curl" "$CURL_LOG"
    
    run bash "$SCRIPT" "$FAKE_REPO"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"gitleaks already installed"* ]]
    # curl should not be called
    [ ! -s "$CURL_LOG" ]
}

@test "setup-secret-scan: shows gitleaks version when already installed" {
    create_mock_with_body "command" 'exit 0'
    
    run bash "$SCRIPT" "$FAKE_REPO"
    
    [[ "$output" == *"gitleaks already installed"* ]]
    [[ "$output" == *"v8.18.0"* ]]
}

@test "setup-secret-scan: reinstalls with --force even when present" {
    create_mock_with_body "command" 'exit 0'
    
    CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
    create_call_log_mock "curl" "$CURL_LOG"
    
    create_mock_with_body "grep" 'echo "\"tag_name\": \"v8.18.0\""'
    create_mock_with_body "sed" 'echo "8.18.0"'
    
    run bash "$SCRIPT" "$FAKE_REPO" --force
    
    [ "$status" -eq 0 ]
    # curl should be called despite gitleaks existing
    [ -s "$CURL_LOG" ]
}

# ── Pre-commit hook installation ──────────────────────────────────────────────

@test "setup-secret-scan: creates pre-commit hook" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    [ "$status" -eq 0 ]
    [ -f "$FAKE_REPO/.git/hooks/pre-commit" ]
}

@test "setup-secret-scan: hook contains gitleaks protect command" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    assert_file_contains "$FAKE_REPO/.git/hooks/pre-commit" "gitleaks protect --staged --redact -q"
}

@test "setup-secret-scan: hook exits on gitleaks failure" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    assert_file_contains "$FAKE_REPO/.git/hooks/pre-commit" 'EXIT_CODE=$?'
    assert_file_contains "$FAKE_REPO/.git/hooks/pre-commit" 'exit $EXIT_CODE'
}

@test "setup-secret-scan: hook provides helpful error message" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    assert_file_contains "$FAKE_REPO/.git/hooks/pre-commit" "gitleaks detected secrets"
    assert_file_contains "$FAKE_REPO/.git/hooks/pre-commit" "Commit blocked"
}

@test "setup-secret-scan: hook mentions bypass option" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    assert_file_contains "$FAKE_REPO/.git/hooks/pre-commit" "git commit --no-verify"
}

@test "setup-secret-scan: hook is executable" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    CHMOD_LOG="$BATS_TEST_TMPDIR/chmod.log"
    create_call_log_mock "chmod" "$CHMOD_LOG"
    
    run bash "$SCRIPT" "$FAKE_REPO"
    
    assert_file_contains "$CHMOD_LOG" "+x"
    assert_file_contains "$CHMOD_LOG" "pre-commit"
}

@test "setup-secret-scan: preserves existing pre-commit hook" {
    # Create an existing hook
    cat > "$FAKE_REPO/.git/hooks/pre-commit" << 'EOF'
#!/bin/bash
# existing hook
echo "Running tests..."
npm test
EOF
    
    run bash "$SCRIPT" "$FAKE_REPO"
    
    [ "$status" -eq 0 ]
    assert_file_contains "$FAKE_REPO/.git/hooks/pre-commit" "gitleaks"
    assert_file_contains "$FAKE_REPO/.git/hooks/pre-commit" "npm test"
    assert_file_contains "$FAKE_REPO/.git/hooks/pre-commit" "Running tests"
}

@test "setup-secret-scan: prepends gitleaks to existing hook" {
    cat > "$FAKE_REPO/.git/hooks/pre-commit" << 'EOF'
#!/bin/bash
echo "existing"
EOF
    
    run bash "$SCRIPT" "$FAKE_REPO"
    
    # Gitleaks check should come before existing content
    hook_content="$(cat "$FAKE_REPO/.git/hooks/pre-commit")"
    gitleaks_pos="$(echo "$hook_content" | grep -n "gitleaks" | cut -d: -f1 | head -1)"
    existing_pos="$(echo "$hook_content" | grep -n "existing" | cut -d: -f1)"
    
    [ "$gitleaks_pos" -lt "$existing_pos" ]
}

@test "setup-secret-scan: does not duplicate gitleaks if already present" {
    # Create a hook that already has gitleaks
    cat > "$FAKE_REPO/.git/hooks/pre-commit" << 'EOF'
#!/bin/bash
gitleaks protect --staged
EOF
    
    run bash "$SCRIPT" "$FAKE_REPO"
    
    # Count occurrences of gitleaks (should still be just one)
    count="$(grep -c "gitleaks" "$FAKE_REPO/.git/hooks/pre-commit")"
    [ "$count" -eq 1 ]
}

# ── Configuration file creation ───────────────────────────────────────────────

@test "setup-secret-scan: creates .gitleaks.toml config" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    [ "$status" -eq 0 ]
    [ -f "$FAKE_REPO/.gitleaks.toml" ]
}

@test "setup-secret-scan: config contains title" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    assert_file_contains "$FAKE_REPO/.gitleaks.toml" 'title = "dockerHosting secret scan"'
}

@test "setup-secret-scan: config extends default ruleset" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    assert_file_contains "$FAKE_REPO/.gitleaks.toml" "[extend]"
    assert_file_contains "$FAKE_REPO/.gitleaks.toml" "useDefault = true"
}

@test "setup-secret-scan: config includes allowlist for template placeholders" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    assert_file_contains "$FAKE_REPO/.gitleaks.toml" "[[rules.allowlist]]"
    assert_file_contains "$FAKE_REPO/.gitleaks.toml" "Template placeholder"
    assert_file_contains "$FAKE_REPO/.gitleaks.toml" "YOUR_.*_HERE"
    assert_file_contains "$FAKE_REPO/.gitleaks.toml" "REPLACE_ME"
}

@test "setup-secret-scan: config includes regex for template variables" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    assert_file_contains "$FAKE_REPO/.gitleaks.toml" '\{\{[A-Z_]+\}\}'
}

@test "setup-secret-scan: does not overwrite existing config" {
    # Create existing config
    echo "existing config" > "$FAKE_REPO/.gitleaks.toml"
    
    run bash "$SCRIPT" "$FAKE_REPO"
    
    [ "$status" -eq 0 ]
    assert_file_contains "$FAKE_REPO/.gitleaks.toml" "existing config"
    refute_file_contains "$FAKE_REPO/.gitleaks.toml" "dockerHosting secret scan"
}

@test "setup-secret-scan: mentions committing config file" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    [[ "$output" == *"Commit this file to your repository"* ]]
}

# ── Git repository handling ───────────────────────────────────────────────────

@test "setup-secret-scan: detects non-git directory" {
    mkdir -p "$BATS_TEST_TMPDIR/not-a-repo"
    
    run bash "$SCRIPT" "$BATS_TEST_TMPDIR/not-a-repo"
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"Not a git repository"* ]]
}

@test "setup-secret-scan: warns when run in non-git directory" {
    mkdir -p "$BATS_TEST_TMPDIR/not-a-repo"
    
    # Remove the exit on non-git repo for this test by mocking the check
    # Actually, the script exits, so we expect failure
    run bash "$SCRIPT" "$BATS_TEST_TMPDIR/not-a-repo"
    
    [ "$status" -eq 1 ]
}

@test "setup-secret-scan: creates hooks directory if missing" {
    # Remove hooks directory
    rm -rf "$FAKE_REPO/.git/hooks"
    
    run bash "$SCRIPT" "$FAKE_REPO"
    
    [ "$status" -eq 0 ]
    [ -d "$FAKE_REPO/.git/hooks" ]
    [ -f "$FAKE_REPO/.git/hooks/pre-commit" ]
}

# ── Hook execution simulation ─────────────────────────────────────────────────

@test "setup-secret-scan: hook blocks commit when gitleaks finds secrets" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    # Create a mock gitleaks that exits 1 (found secrets)
    create_mock_with_body "gitleaks" 'exit 1'
    
    # Execute the hook
    run bash "$FAKE_REPO/.git/hooks/pre-commit"
    
    [ "$status" -eq 1 ]
}

@test "setup-secret-scan: hook allows commit when no secrets found" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    # Create a mock gitleaks that exits 0 (no secrets)
    create_mock_with_body "gitleaks" 'exit 0'
    
    # Execute the hook
    run bash "$FAKE_REPO/.git/hooks/pre-commit"
    
    [ "$status" -eq 0 ]
}

@test "setup-secret-scan: hook passes correct flags to gitleaks" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    GITLEAKS_LOG="$BATS_TEST_TMPDIR/gitleaks.log"
    create_call_log_mock "gitleaks" "$GITLEAKS_LOG"
    
    # Execute the hook
    bash "$FAKE_REPO/.git/hooks/pre-commit"
    
    assert_file_contains "$GITLEAKS_LOG" "protect"
    assert_file_contains "$GITLEAKS_LOG" "--staged"
    assert_file_contains "$GITLEAKS_LOG" "--redact"
    assert_file_contains "$GITLEAKS_LOG" "-q"
}

@test "setup-secret-scan: hook shows error message on secret detection" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    # Mock gitleaks to fail
    create_mock_with_body "gitleaks" 'exit 1'
    
    run bash "$FAKE_REPO/.git/hooks/pre-commit"
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"gitleaks detected secrets"* ]]
    [[ "$output" == *"Commit blocked"* ]]
}

# ── Output and reporting ──────────────────────────────────────────────────────

@test "setup-secret-scan: confirms hook installation in output" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    [[ "$output" == *"Pre-commit hook installed"* ]]
    [[ "$output" == *".git/hooks/pre-commit"* ]]
}

@test "setup-secret-scan: confirms config creation in output" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    [[ "$output" == *"Created .gitleaks.toml"* ]]
}

@test "setup-secret-scan: shows final status message" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    [[ "$output" == *"Secret scanning pre-commit hook active"* ]]
}

@test "setup-secret-scan: suggests test command" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    [[ "$output" == *"gitleaks protect --staged"* ]]
}

@test "setup-secret-scan: mentions NIS2 compliance" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    hook_content="$(cat "$FAKE_REPO/.git/hooks/pre-commit")"
    [[ "$hook_content" == *"NIS2"* ]] || [[ "$hook_content" == *"ISO 27001"* ]]
}

# ── Integration scenarios ─────────────────────────────────────────────────────

@test "setup-secret-scan: full workflow with new repository" {
    # Simulate complete setup
    create_mock_with_body "grep" 'echo "\"tag_name\": \"v8.18.0\""'
    create_mock_with_body "sed" 'echo "8.18.0"'
    
    run bash "$SCRIPT" "$FAKE_REPO"
    
    [ "$status" -eq 0 ]
    [ -f "$FAKE_REPO/.git/hooks/pre-commit" ]
    [ -f "$FAKE_REPO/.gitleaks.toml" ]
    [[ "$output" == *"Installing gitleaks"* ]]
    [[ "$output" == *"Pre-commit hook installed"* ]]
    [[ "$output" == *"Secret scanning pre-commit hook active"* ]]
}

@test "setup-secret-scan: idempotent re-run does not reinstall" {
    # First run
    create_mock_with_body "grep" 'echo "\"tag_name\": \"v8.18.0\""'
    create_mock_with_body "sed" 'echo "8.18.0"'
    bash "$SCRIPT" "$FAKE_REPO"
    
    # Mock gitleaks as installed
    create_mock_with_body "command" 'exit 0'
    
    CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
    create_call_log_mock "curl" "$CURL_LOG"
    
    # Second run
    run bash "$SCRIPT" "$FAKE_REPO"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
    [[ "$output" == *"already exists"* ]]
    [ ! -s "$CURL_LOG" ]
}

@test "setup-secret-scan: handles multiple repositories" {
    REPO1="$BATS_TEST_TMPDIR/repo1"
    REPO2="$BATS_TEST_TMPDIR/repo2"
    mkdir -p "$REPO1/.git" "$REPO2/.git"
    
    create_mock_with_body "command" 'exit 0'
    
    bash "$SCRIPT" "$REPO1"
    bash "$SCRIPT" "$REPO2"
    
    [ -f "$REPO1/.git/hooks/pre-commit" ]
    [ -f "$REPO2/.git/hooks/pre-commit" ]
    [ -f "$REPO1/.gitleaks.toml" ]
    [ -f "$REPO2/.gitleaks.toml" ]
}

# ── Edge cases ────────────────────────────────────────────────────────────────

@test "setup-secret-scan: handles paths with spaces" {
    SPACE_REPO="$BATS_TEST_TMPDIR/repo with spaces"
    mkdir -p "$SPACE_REPO/.git/hooks"
    
    run bash "$SCRIPT" "$SPACE_REPO"
    
    [ "$status" -eq 0 ]
    [ -f "$SPACE_REPO/.git/hooks/pre-commit" ]
}

@test "setup-secret-scan: creates hook with proper shebang" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    hook_first_line="$(head -1 "$FAKE_REPO/.git/hooks/pre-commit")"
    [[ "$hook_first_line" == "#!/bin/bash" ]]
}

@test "setup-secret-scan: hook is valid bash syntax" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    # Check syntax
    run bash -n "$FAKE_REPO/.git/hooks/pre-commit"
    [ "$status" -eq 0 ]
}

@test "setup-secret-scan: config is valid TOML syntax" {
    run bash "$SCRIPT" "$FAKE_REPO"
    
    # Basic TOML validation - check for balanced brackets
    config="$(cat "$FAKE_REPO/.gitleaks.toml")"
    open_brackets="$(echo "$config" | grep -o '\[' | wc -l)"
    close_brackets="$(echo "$config" | grep -o '\]' | wc -l)"
    [ "$open_brackets" -eq "$close_brackets" ]
}
