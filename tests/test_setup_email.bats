#!/usr/bin/env bats
# Comprehensive tests for scripts/setup-email.sh
# Tests msmtp installation, configuration, TLS settings, and email sending.

load 'helpers/common'

SCRIPT="$REPO_ROOT/scripts/setup-email.sh"

setup() {
    setup_mocks

    # Set up test environment paths
    export MSMTPRC="$BATS_TEST_TMPDIR/msmtprc"
    export ALIASES_FILE="$BATS_TEST_TMPDIR/aliases"
    export MSMTP_LOG="$BATS_TEST_TMPDIR/msmtp.log"
    export LOGROTATE_CONF="$BATS_TEST_TMPDIR/logrotate-msmtp"
    
    LOG_DIR="$BATS_TEST_TMPDIR/var/log"
    mkdir -p "$LOG_DIR"

    # Mock system commands
    create_mock "apt-get"
    create_mock "chmod"
    create_mock "chown"
    create_mock "touch"
    create_mock "ln"
    create_mock "hostname"
    create_mock "mail"

    # Track command invocations
    APT_LOG="$BATS_TEST_TMPDIR/apt.log"
    CHMOD_LOG="$BATS_TEST_TMPDIR/chmod.log"
    CHOWN_LOG="$BATS_TEST_TMPDIR/chown.log"
    MAIL_LOG="$BATS_TEST_TMPDIR/mail.log"
    LN_LOG="$BATS_TEST_TMPDIR/ln.log"

    # Create wrapper script that redirects file paths for testing
    SCRIPT_WRAPPER="$BATS_TEST_TMPDIR/setup-email-wrapper.sh"
    cat > "$SCRIPT_WRAPPER" <<'WRAPPER'
#!/bin/bash
# Test wrapper - intercept file operations and redirect to test paths

# Skip sudo elevation for tests
if [ "$EUID" -ne 0 ]; then
    EUID=0
fi

# Read and modify the script on the fly
sed \
    -e "s|/etc/msmtprc|$MSMTPRC|g" \
    -e "s|/etc/aliases|$ALIASES_FILE|g" \
    -e "s|/var/log/msmtp.log|$MSMTP_LOG|g" \
    -e "s|/etc/logrotate.d/msmtp|$LOGROTATE_CONF|g" \
    -e '/exec sudo/d' \
    "$REPO_ROOT/scripts/setup-email.sh" | bash -s "$@"
WRAPPER
    chmod +x "$SCRIPT_WRAPPER"
}

teardown() {
    teardown_mocks
    rm -f "$MSMTPRC" "$ALIASES_FILE" "$MSMTP_LOG" "$LOGROTATE_CONF"
}

# ── Idempotency: msmtprc already exists ──────────────────────────────────────

@test "setup-email: skips configuration when /etc/msmtprc exists" {
    # Create existing config
    echo "# existing config" > "$MSMTPRC"
    
    create_call_log_mock "apt-get" "$APT_LOG"

    run bash "$SCRIPT_WRAPPER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already configured"* ]]
    [[ "$output" == *"skipping"* ]]

    # apt-get should not be called
    [ ! -s "$APT_LOG" ]
}

@test "setup-email: mentions --force flag when skipping" {
    echo "# existing config" > "$MSMTPRC"

    run bash "$SCRIPT_WRAPPER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--force"* ]]
}

@test "setup-email: forces reconfiguration with --force flag" {
    echo "# old config" > "$MSMTPRC"
    create_call_log_mock "apt-get" "$APT_LOG"

    # Provide input for all prompts
    run bash "$SCRIPT_WRAPPER" --force <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass
sender@example.com
Y
INPUT

    [ "$status" -eq 0 ]
    
    # apt-get should be called
    assert_file_exists "$APT_LOG"
    
    # Config should be regenerated
    assert_file_exists "$MSMTPRC"
    assert_file_contains "$MSMTPRC" "smtp.example.com"
}

# ── Interactive prompt handling ──────────────────────────────────────────────

@test "setup-email: prompts for root email address" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass
sender@example.com
Y
INPUT

    [ "$status" -eq 0 ]
    [[ "$output" == *"Email address to receive root/system emails"* ]]
}

@test "setup-email: prompts for SMTP server" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    [[ "$output" == *"SMTP server"* ]]
    [[ "$output" == *"smarthost"* ]]
}

@test "setup-email: prompts for SMTP port with default 587" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com

smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    [[ "$output" == *"SMTP port"* ]]
    [[ "$output" == *"587"* ]]
    
    # Config should use default port 587
    assert_file_contains "$MSMTPRC" "port           587"
}

@test "setup-email: accepts custom SMTP port" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
2525
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$MSMTPRC" "port           2525"
}

@test "setup-email: prompts for SMTP username" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    [[ "$output" == *"SMTP username"* ]]
}

@test "setup-email: prompts for SMTP password" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    [[ "$output" == *"SMTP password"* ]]
}

@test "setup-email: prompts for from address with default" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user@example.com
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    [[ "$output" == *"From address"* ]]
    
    # Should default to SMTP username
    assert_file_contains "$MSMTPRC" "from           smtp-user@example.com"
}

@test "setup-email: accepts custom from address" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass
custom-sender@example.com
Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$MSMTPRC" "from           custom-sender@example.com"
}

@test "setup-email: prompts for TLS with Y/n default" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    [[ "$output" == *"Use TLS"* ]]
}

@test "setup-email: rejects empty required fields and re-prompts" {
    run bash "$SCRIPT_WRAPPER" <<INPUT


admin@example.com
smtp.example.com
587

smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    
    # Should show error for empty email
    [[ "$output" == *"Email address is required"* ]]
    
    # Should eventually succeed
    assert_file_exists "$MSMTPRC"
}

# ── msmtp installation ────────────────────────────────────────────────────────

@test "setup-email: installs msmtp and related packages" {
    create_call_log_mock "apt-get" "$APT_LOG"

    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    
    assert_file_exists "$APT_LOG"
    assert_file_contains "$APT_LOG" "install"
    assert_file_contains "$APT_LOG" "msmtp"
    assert_file_contains "$APT_LOG" "msmtp-mta"
    assert_file_contains "$APT_LOG" "mailutils"
    assert_file_contains "$APT_LOG" "bsd-mailx"
}

@test "setup-email: updates package cache before installation" {
    create_call_log_mock "apt-get" "$APT_LOG"

    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    
    # First apt-get call should be update
    head -n 1 "$APT_LOG" | grep -q "update"
}

@test "setup-email: installs with -y flag for non-interactive mode" {
    create_call_log_mock "apt-get" "$APT_LOG"

    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$APT_LOG" "-y"
}

@test "setup-email: confirms installation in output" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    [[ "$output" == *"Installing msmtp"* ]]
}

# ── /etc/msmtprc configuration generation ────────────────────────────────────

@test "setup-email: generates valid msmtprc configuration" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_exists "$MSMTPRC"
}

@test "setup-email: includes defaults section in msmtprc" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$MSMTPRC" "defaults"
}

@test "setup-email: sets SMTP host in configuration" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.gmail.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$MSMTPRC" "host           smtp.gmail.com"
}

@test "setup-email: sets SMTP port in configuration" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
465
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$MSMTPRC" "port           465"
}

@test "setup-email: sets from address in configuration" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass
noreply@example.com
Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$MSMTPRC" "from           noreply@example.com"
}

@test "setup-email: sets username in configuration" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
myusername
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$MSMTPRC" "user           myusername"
}

@test "setup-email: sets password in configuration" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
supersecret

Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$MSMTPRC" "password       supersecret"
}

@test "setup-email: sets default account reference" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$MSMTPRC" "account        default"
    assert_file_contains "$MSMTPRC" "account default : default"
}

@test "setup-email: sets log file path" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$MSMTPRC" "logfile"
}

@test "setup-email: sets CA certificate path" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$MSMTPRC" "tls_trust_file /etc/ssl/certs/ca-certificates.crt"
}

# ── TLS configuration ─────────────────────────────────────────────────────────

@test "setup-email: enables TLS when user confirms (Y)" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$MSMTPRC" "tls            on"
}

@test "setup-email: enables TLS by default (empty input)" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass


INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$MSMTPRC" "tls            on"
}

@test "setup-email: disables TLS when user declines (n)" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

n
INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$MSMTPRC" "tls            off"
}

@test "setup-email: disables TLS when user declines (N)" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

N
INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$MSMTPRC" "tls            off"
}

# ── Auth settings ─────────────────────────────────────────────────────────────

@test "setup-email: enables authentication in config" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$MSMTPRC" "auth           on"
}

# ── File permissions ──────────────────────────────────────────────────────────

@test "setup-email: sets msmtprc permissions to 600" {
    create_call_log_mock "chmod" "$CHMOD_LOG"

    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    
    assert_file_exists "$CHMOD_LOG"
    grep -q "600.*msmtprc" "$CHMOD_LOG"
}

@test "setup-email: sets msmtprc owner to root:root" {
    create_call_log_mock "chown" "$CHOWN_LOG"

    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    
    assert_file_exists "$CHOWN_LOG"
    grep -q "root:root.*msmtprc" "$CHOWN_LOG"
}

@test "setup-email: confirms securing configuration file in output" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    [[ "$output" == *"msmtp configuration secured"* ]]
    [[ "$output" == *"600"* ]]
}

@test "setup-email: creates log file with correct permissions" {
    create_call_log_mock "chmod" "$CHMOD_LOG"

    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    
    # Log should be created with 660
    grep -q "660.*msmtp.log" "$CHMOD_LOG"
}

@test "setup-email: sets log file owner appropriately" {
    create_call_log_mock "chown" "$CHOWN_LOG"

    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    
    # Should try to chown to root:msmtp, fallback to root:root
    assert_file_exists "$CHOWN_LOG"
    [[ -s "$CHOWN_LOG" ]]
}

# ── Mail aliases configuration ────────────────────────────────────────────────

@test "setup-email: creates /etc/aliases file" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_exists "$ALIASES_FILE"
}

@test "setup-email: forwards root mail to configured email" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
sysadmin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$ALIASES_FILE" "root: sysadmin@example.com"
}

@test "setup-email: forwards default to configured email" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
alerts@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$ALIASES_FILE" "default: alerts@example.com"
}

@test "setup-email: forwards system accounts to root" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$ALIASES_FILE" "postmaster: root"
    assert_file_contains "$ALIASES_FILE" "abuse: root"
    assert_file_contains "$ALIASES_FILE" "nobody: root"
}

@test "setup-email: confirms configuring aliases in output" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    [[ "$output" == *"Configuring mail aliases"* ]]
}

# ── MTA configuration ─────────────────────────────────────────────────────────

@test "setup-email: creates symlink for sendmail to msmtp" {
    create_call_log_mock "ln" "$LN_LOG"

    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    
    assert_file_exists "$LN_LOG"
    # Should create symlinks for both /usr/sbin/sendmail and /usr/bin/sendmail
    grep -q "sendmail" "$LN_LOG"
}

@test "setup-email: confirms setting msmtp as default MTA" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    [[ "$output" == *"Setting msmtp as default MTA"* ]]
}

# ── Log rotation configuration ────────────────────────────────────────────────

@test "setup-email: creates logrotate configuration" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_exists "$LOGROTATE_CONF"
}

@test "setup-email: configures daily log rotation" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$LOGROTATE_CONF" "daily"
}

@test "setup-email: configures 14-day retention" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$LOGROTATE_CONF" "rotate 14"
}

@test "setup-email: enables compression in logrotate" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    assert_file_contains "$LOGROTATE_CONF" "compress"
}

@test "setup-email: confirms configuring log rotation" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    [[ "$output" == *"Configuring log rotation"* ]]
}

# ── Test email sending ────────────────────────────────────────────────────────

@test "setup-email: sends test email to configured address" {
    create_call_log_mock "mail" "$MAIL_LOG"
    create_mock_with_body "hostname" 'echo "testhost"'

    run bash "$SCRIPT_WRAPPER" <<INPUT
test@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    
    assert_file_exists "$MAIL_LOG"
    assert_file_contains "$MAIL_LOG" "test@example.com"
}

@test "setup-email: test email includes subject line" {
    create_call_log_mock "mail" "$MAIL_LOG"
    create_mock_with_body "hostname" 'echo "myserver"'

    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    
    assert_file_contains "$MAIL_LOG" "-s"
    assert_file_contains "$MAIL_LOG" "Test Email"
}

@test "setup-email: confirms testing email configuration" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    [[ "$output" == *"Testing email configuration"* ]]
}

@test "setup-email: warns if test email fails" {
    create_mock_with_body "mail" 'exit 1'

    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    [[ "$output" == *"Test email may have failed"* ]]
    [[ "$output" == *"msmtp.log"* ]]
}

@test "setup-email: continues even if test email fails" {
    create_mock_with_body "mail" 'exit 1'

    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    [[ "$output" == *"Email Configuration Complete"* ]]
}

# ── Success confirmation ──────────────────────────────────────────────────────

@test "setup-email: displays completion message" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    [[ "$output" == *"Email Configuration Complete"* ]]
}

@test "setup-email: includes header banner in output" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass

Y
INPUT

    [ "$status" -eq 0 ]
    [[ "$output" == *"Email Notification Setup"* ]]
}

# ── Full workflow integration ─────────────────────────────────────────────────

@test "setup-email: complete workflow creates all required files" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
admin@example.com
smtp.example.com
587
smtp-user
smtp-pass
sender@example.com
Y
INPUT

    [ "$status" -eq 0 ]
    
    # All configuration files should exist
    assert_file_exists "$MSMTPRC"
    assert_file_exists "$ALIASES_FILE"
    assert_file_exists "$LOGROTATE_CONF"
}

@test "setup-email: complete workflow with all settings" {
    run bash "$SCRIPT_WRAPPER" <<INPUT
sysadmin@example.com
smtp.gmail.com
587
emailuser@gmail.com
mypassword123
noreply@example.com
Y
INPUT

    [ "$status" -eq 0 ]
    
    # Verify all settings in msmtprc
    assert_file_contains "$MSMTPRC" "host           smtp.gmail.com"
    assert_file_contains "$MSMTPRC" "port           587"
    assert_file_contains "$MSMTPRC" "from           noreply@example.com"
    assert_file_contains "$MSMTPRC" "user           emailuser@gmail.com"
    assert_file_contains "$MSMTPRC" "password       mypassword123"
    assert_file_contains "$MSMTPRC" "tls            on"
    assert_file_contains "$MSMTPRC" "auth           on"
    
    # Verify aliases
    assert_file_contains "$ALIASES_FILE" "root: sysadmin@example.com"
}
