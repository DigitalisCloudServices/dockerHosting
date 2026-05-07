#!/usr/bin/env bats
# Comprehensive tests for scripts/setup-ssh-mfa.sh
# Tests SSH TOTP multi-factor authentication setup via libpam-google-authenticator

load 'helpers/common'

SCRIPT="$REPO_ROOT/scripts/setup-ssh-mfa.sh"

setup() {
    setup_mocks
    
    # Override file paths for isolation
    export PAM_SSH_FILE="$BATS_TEST_TMPDIR/pam.d/sshd"
    export SSHD_DROP_IN="$BATS_TEST_TMPDIR/ssh/sshd_config.d/98-mfa.conf"
    export PAM_BACKUP="${PAM_SSH_FILE}.pre-mfa.backup"
    
    mkdir -p "$(dirname "$PAM_SSH_FILE")"
    mkdir -p "$(dirname "$SSHD_DROP_IN")"
    
    # Create minimal PAM sshd configuration
    cat > "$PAM_SSH_FILE" <<'EOF'
# PAM configuration for SSH daemon
@include common-auth
@include common-account
@include common-session
EOF
    
    # Mock system commands
    create_mock "systemctl"
    create_mock "usermod"
    
    # Mock dpkg to report package not installed by default
    create_mock_with_body "dpkg" 'exit 1'
    
    # Mock apt-get
    create_mock "apt-get"
    
    # Mock google-authenticator
    create_mock_with_body "google-authenticator" 'echo "MOCK QR CODE"; echo "MOCK BACKUP CODES"; exit 0'
    
    # Mock sshd test to succeed
    create_mock_with_body "sshd" '[[ "$1" == "-t" ]] && exit 0 || exit 1'
    
    # Patch the script to use our overridden paths
    PATCHED_SCRIPT="$BATS_TEST_TMPDIR/setup-ssh-mfa-patched.sh"
    sed \
        -e "s|PAM_SSH_FILE=/etc/pam.d/sshd|PAM_SSH_FILE=$PAM_SSH_FILE|g" \
        -e "s|SSHD_DROP_IN=/etc/ssh/sshd_config.d/98-mfa.conf|SSHD_DROP_IN=$SSHD_DROP_IN|g" \
        "$SCRIPT" > "$PATCHED_SCRIPT"
    chmod +x "$PATCHED_SCRIPT"
}

teardown() {
    teardown_mocks
}

# ── User confirmation flow ────────────────────────────────────────────────────

@test "setup-ssh-mfa: prompts user for confirmation" {
    run bash "$PATCHED_SCRIPT" <<< "no"
    
    [[ "$output" == *"SSH MFA SETUP"* ]]
    [[ "$output" == *"IMPORTANT"* ]]
    [[ "$output" == *"google-authenticator"* ]]
    [[ "$output" == *"Continue?"* ]]
}

@test "setup-ssh-mfa: aborts when user responds with anything other than 'yes'" {
    run bash "$PATCHED_SCRIPT" <<< "no"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"aborted"* ]]
    [[ "$output" == *"no changes made"* ]]
    [ ! -f "$SSHD_DROP_IN" ]
}

@test "setup-ssh-mfa: aborts on empty confirmation" {
    run bash "$PATCHED_SCRIPT" <<< ""
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"aborted"* ]]
    [ ! -f "$SSHD_DROP_IN" ]
}

@test "setup-ssh-mfa: proceeds when user confirms with 'yes'" {
    APT_LOG="$BATS_TEST_TMPDIR/apt.log"
    create_call_log_mock "apt-get" "$APT_LOG"
    
    run bash "$PATCHED_SCRIPT" <<< "yes"
    
    [ "$status" -eq 0 ]
    [ -s "$APT_LOG" ]
}

@test "setup-ssh-mfa: warns about user lockout risk" {
    run bash "$PATCHED_SCRIPT" <<< "no"
    
    [[ "$output" == *"WILL BE LOCKED OUT"* ]]
    [[ "$output" == *"Users who have NOT done this"* ]]
}

@test "setup-ssh-mfa: recommends testing on test account first" {
    run bash "$PATCHED_SCRIPT" <<< "no"
    
    [[ "$output" == *"Recommended: set up on a test account first"* ]]
}

# ── Package installation ──────────────────────────────────────────────────────

@test "setup-ssh-mfa: checks if libpam-google-authenticator is installed" {
    DPKG_LOG="$BATS_TEST_TMPDIR/dpkg.log"
    create_call_log_mock "dpkg" "$DPKG_LOG"
    
    bash "$PATCHED_SCRIPT" <<< "yes"
    
    assert_file_exists "$DPKG_LOG"
    assert_file_contains "$DPKG_LOG" "-l libpam-google-authenticator"
}

@test "setup-ssh-mfa: installs libpam-google-authenticator when not present" {
    APT_LOG="$BATS_TEST_TMPDIR/apt.log"
    create_call_log_mock "apt-get" "$APT_LOG"
    
    # Mock dpkg to return not installed
    create_mock_with_body "dpkg" 'exit 1'
    
    run bash "$PATCHED_SCRIPT" <<< "yes"
    
    assert_file_exists "$APT_LOG"
    assert_file_contains "$APT_LOG" "install -y libpam-google-authenticator"
    [[ "$output" == *"Installing libpam-google-authenticator"* ]]
}

@test "setup-ssh-mfa: skips installation if package already installed" {
    APT_LOG="$BATS_TEST_TMPDIR/apt.log"
    create_call_log_mock "apt-get" "$APT_LOG"
    
    # Mock dpkg to return installed
    create_mock_with_body "dpkg" 'exit 0'
    
    run bash "$PATCHED_SCRIPT" <<< "yes"
    
    # apt-get should not be called
    [ ! -s "$APT_LOG" ]
}

# ── PAM configuration ─────────────────────────────────────────────────────────

@test "setup-ssh-mfa: creates backup of PAM sshd config" {
    bash "$PATCHED_SCRIPT" <<< "yes"
    
    assert_file_exists "$PAM_BACKUP"
    assert_file_contains "$PAM_BACKUP" "@include common-auth"
}

@test "setup-ssh-mfa: does not overwrite existing PAM backup" {
    # Create existing backup with custom content
    echo "EXISTING BACKUP CONTENT" > "$PAM_BACKUP"
    
    bash "$PATCHED_SCRIPT" <<< "yes"
    
    # Backup should still have original content
    assert_file_contains "$PAM_BACKUP" "EXISTING BACKUP CONTENT"
    refute_file_contains "$PAM_BACKUP" "@include common-auth"
}

@test "setup-ssh-mfa: adds pam_google_authenticator to PAM sshd config" {
    bash "$PATCHED_SCRIPT" <<< "yes"
    
    assert_file_contains "$PAM_SSH_FILE" "pam_google_authenticator"
}

@test "setup-ssh-mfa: inserts PAM line after @include common-auth" {
    bash "$PATCHED_SCRIPT" <<< "yes"
    
    # Check that the google-authenticator line appears after common-auth
    grep -A1 "@include common-auth" "$PAM_SSH_FILE" | grep -q "pam_google_authenticator"
}

@test "setup-ssh-mfa: uses 'auth required' for PAM module" {
    bash "$PATCHED_SCRIPT" <<< "yes"
    
    assert_file_contains "$PAM_SSH_FILE" "auth required pam_google_authenticator.so"
}

@test "setup-ssh-mfa: includes nullok option during rollout" {
    bash "$PATCHED_SCRIPT" <<< "yes"
    
    assert_file_contains "$PAM_SSH_FILE" "pam_google_authenticator.so nullok"
}

@test "setup-ssh-mfa: does not duplicate PAM line if already present" {
    # Manually add the line first
    sed -i '/^@include common-auth/a auth required pam_google_authenticator.so nullok' "$PAM_SSH_FILE"
    
    bash "$PATCHED_SCRIPT" <<< "yes"
    
    # Count occurrences of pam_google_authenticator
    count=$(grep -c "pam_google_authenticator" "$PAM_SSH_FILE")
    [ "$count" -eq 1 ]
}

@test "setup-ssh-mfa: confirms PAM configuration in output" {
    run bash "$PATCHED_SCRIPT" <<< "yes"
    
    [[ "$output" == *"Added pam_google_authenticator"* ]] || 
    [[ "$output" == *"already present"* ]]
}

# ── SSHD configuration ────────────────────────────────────────────────────────

@test "setup-ssh-mfa: creates sshd drop-in configuration" {
    bash "$PATCHED_SCRIPT" <<< "yes"
    
    assert_file_exists "$SSHD_DROP_IN"
}

@test "setup-ssh-mfa: enables KbdInteractiveAuthentication" {
    bash "$PATCHED_SCRIPT" <<< "yes"
    
    assert_file_contains "$SSHD_DROP_IN" "KbdInteractiveAuthentication yes"
}

@test "setup-ssh-mfa: sets AuthenticationMethods to publickey,keyboard-interactive" {
    bash "$PATCHED_SCRIPT" <<< "yes"
    
    assert_file_contains "$SSHD_DROP_IN" "AuthenticationMethods publickey,keyboard-interactive"
}

@test "setup-ssh-mfa: includes configuration comment in drop-in" {
    bash "$PATCHED_SCRIPT" <<< "yes"
    
    assert_file_contains "$SSHD_DROP_IN" "SSH MFA Configuration"
    assert_file_contains "$SSHD_DROP_IN" "dockerHosting security hardening"
}

@test "setup-ssh-mfa: explains two-factor requirement in drop-in" {
    bash "$PATCHED_SCRIPT" <<< "yes"
    
    assert_file_contains "$SSHD_DROP_IN" "two-factor"
}

@test "setup-ssh-mfa: confirms drop-in creation in output" {
    run bash "$PATCHED_SCRIPT" <<< "yes"
    
    [[ "$output" == *"Created"*"98-mfa.conf"* ]]
}

# ── SSH configuration validation ──────────────────────────────────────────────

@test "setup-ssh-mfa: validates SSH configuration with sshd -t" {
    SSHD_LOG="$BATS_TEST_TMPDIR/sshd.log"
    create_call_log_mock "sshd" "$SSHD_LOG"
    create_mock_with_body "sshd" 'echo "$*" >> '"$SSHD_LOG"'; exit 0'
    
    bash "$PATCHED_SCRIPT" <<< "yes"
    
    assert_file_contains "$SSHD_LOG" "-t"
}

@test "setup-ssh-mfa: confirms configuration test passed" {
    run bash "$PATCHED_SCRIPT" <<< "yes"
    
    [[ "$output" == *"SSH configuration test passed"* ]]
}

@test "setup-ssh-mfa: reloads sshd after successful configuration" {
    SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    create_call_log_mock "systemctl" "$SYSTEMCTL_LOG"
    
    bash "$PATCHED_SCRIPT" <<< "yes"
    
    assert_file_contains "$SYSTEMCTL_LOG" "reload sshd"
}

@test "setup-ssh-mfa: confirms sshd reload in output" {
    run bash "$PATCHED_SCRIPT" <<< "yes"
    
    [[ "$output" == *"sshd reloaded"* ]]
}

# ── Error handling and rollback ───────────────────────────────────────────────

@test "setup-ssh-mfa: rolls back changes if sshd test fails" {
    # Mock sshd to fail configuration test
    create_mock_with_body "sshd" '[[ "$1" == "-t" ]] && exit 1 || exit 0'
    
    bash "$PATCHED_SCRIPT" <<< "yes"
    
    # Drop-in should be removed
    [ ! -f "$SSHD_DROP_IN" ]
}

@test "setup-ssh-mfa: restores PAM backup on configuration failure" {
    # Create backup
    echo "ORIGINAL PAM CONTENT" > "$PAM_BACKUP"
    
    # Mock sshd to fail
    create_mock_with_body "sshd" '[[ "$1" == "-t" ]] && exit 1 || exit 0'
    
    bash "$PATCHED_SCRIPT" <<< "yes"
    
    # PAM file should be restored from backup
    assert_file_contains "$PAM_SSH_FILE" "ORIGINAL PAM CONTENT"
}

@test "setup-ssh-mfa: reports configuration test failure" {
    create_mock_with_body "sshd" '[[ "$1" == "-t" ]] && exit 1 || exit 0'
    
    run bash "$PATCHED_SCRIPT" <<< "yes"
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"SSH configuration test failed"* ]]
    [[ "$output" == *"reverting MFA changes"* ]]
}

# ── Idempotency ───────────────────────────────────────────────────────────────

@test "setup-ssh-mfa: detects existing configuration and skips by default" {
    # Create existing drop-in
    echo "# Existing MFA config" > "$SSHD_DROP_IN"
    
    APT_LOG="$BATS_TEST_TMPDIR/apt.log"
    create_call_log_mock "apt-get" "$APT_LOG"
    
    run bash "$PATCHED_SCRIPT"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"already configured"* ]]
    [[ "$output" == *"skipping"* ]]
    
    # Should not prompt or install
    [[ "$output" != *"Continue?"* ]]
    [ ! -s "$APT_LOG" ]
}

@test "setup-ssh-mfa: suggests --force flag when already configured" {
    echo "# Existing MFA config" > "$SSHD_DROP_IN"
    
    run bash "$PATCHED_SCRIPT"
    
    [[ "$output" == *"--force"* ]]
}

@test "setup-ssh-mfa: reconfigures when --force flag is provided" {
    echo "# Existing MFA config" > "$SSHD_DROP_IN"
    
    APT_LOG="$BATS_TEST_TMPDIR/apt.log"
    create_call_log_mock "apt-get" "$APT_LOG"
    
    run bash "$PATCHED_SCRIPT" --force <<< "yes"
    
    [ "$status" -eq 0 ]
    # Should proceed with installation and configuration
    [[ "$output" == *"Continue?"* ]]
}

@test "setup-ssh-mfa: allows multiple --force flags" {
    echo "# Existing MFA config" > "$SSHD_DROP_IN"
    
    run bash "$PATCHED_SCRIPT" --force --force <<< "yes"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"Continue?"* ]]
}

# ── User enrollment instructions ──────────────────────────────────────────────

@test "setup-ssh-mfa: displays enrollment instructions on completion" {
    run bash "$PATCHED_SCRIPT" <<< "yes"
    
    [[ "$output" == *"REQUIRED: ENROL EVERY SUDO USER NOW"* ]]
    [[ "$output" == *"google-authenticator"* ]]
}

@test "setup-ssh-mfa: instructs users to run google-authenticator" {
    run bash "$PATCHED_SCRIPT" <<< "yes"
    
    [[ "$output" == *"Each user who will log in via SSH must run"* ]]
    [[ "$output" == *"google-authenticator"* ]]
}

@test "setup-ssh-mfa: explains QR code scanning" {
    run bash "$PATCHED_SCRIPT" <<< "yes"
    
    [[ "$output" == *"scan the QR code"* ]]
    [[ "$output" == *"authenticator app"* ]]
}

@test "setup-ssh-mfa: explains nullok temporary behavior" {
    run bash "$PATCHED_SCRIPT" <<< "yes"
    
    [[ "$output" == *"nullok"* ]]
    [[ "$output" == *"log in without TOTP"* ]]
}

@test "setup-ssh-mfa: instructs removal of nullok after full enrollment" {
    run bash "$PATCHED_SCRIPT" <<< "yes"
    
    [[ "$output" == *"Once ALL users are enrolled"* ]]
    [[ "$output" == *"remove 'nullok'"* ]]
}

@test "setup-ssh-mfa: shows configuration summary" {
    run bash "$PATCHED_SCRIPT" <<< "yes"
    
    [[ "$output" == *"SSH MFA Setup Complete"* ]]
    [[ "$output" == *"Configuration:"* ]]
    [[ "$output" == *"SSH key + TOTP (two-factor)"* ]]
}

@test "setup-ssh-mfa: provides disable instructions" {
    run bash "$PATCHED_SCRIPT" <<< "yes"
    
    [[ "$output" == *"To disable MFA later"* ]]
    [[ "$output" == *"rm"* ]]
    [[ "$output" == *"98-mfa.conf"* ]]
    [[ "$output" == *"systemctl reload sshd"* ]]
}

# ── Security compliance references ────────────────────────────────────────────

@test "setup-ssh-mfa: mentions ISO 27001 compliance" {
    # Check script header or output for compliance references
    grep -q "ISO 27001" "$SCRIPT"
}

@test "setup-ssh-mfa: mentions NIST SP 800-53 compliance" {
    grep -q "NIST SP 800-53" "$SCRIPT"
}

# ── Output formatting and clarity ─────────────────────────────────────────────

@test "setup-ssh-mfa: uses clear section headers" {
    run bash "$PATCHED_SCRIPT" <<< "yes"
    
    [[ "$output" == *"═══"* ]]
}

@test "setup-ssh-mfa: includes informational [INFO] tags" {
    run bash "$PATCHED_SCRIPT" <<< "yes"
    
    [[ "$output" == *"[INFO]"* ]]
}

@test "setup-ssh-mfa: includes warning [WARN] tags for critical steps" {
    run bash "$PATCHED_SCRIPT" <<< "yes"
    
    [[ "$output" == *"[WARN]"* ]]
}

@test "setup-ssh-mfa: displays complete success message" {
    run bash "$PATCHED_SCRIPT" <<< "yes"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"Complete"* ]]
}
