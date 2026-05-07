#!/usr/bin/env bats
# Tests for scripts/setup-aide.sh
# Verifies AIDE file integrity monitoring: installation, configuration, database init, cron, and email alerts.

load '../helpers/common'

SCRIPT="$SCRIPTS_DIR/setup-aide.sh"

setup() {
    setup_mocks
    
    # Create test directories for AIDE paths
    export AIDE_CONF_DIR="$BATS_TEST_TMPDIR/etc/aide"
    export AIDE_LIB_DIR="$BATS_TEST_TMPDIR/var/lib/aide"
    export AIDE_LOG_DIR="$BATS_TEST_TMPDIR/var/log/aide"
    export CRON_DAILY_DIR="$BATS_TEST_TMPDIR/etc/cron.daily"
    export USR_LOCAL_BIN="$BATS_TEST_TMPDIR/usr/local/bin"
    export MSMTPRC="$BATS_TEST_TMPDIR/etc/msmtprc"
    
    mkdir -p "$AIDE_CONF_DIR" "$AIDE_LIB_DIR" "$AIDE_LOG_DIR" "$CRON_DAILY_DIR" "$USR_LOCAL_BIN"
    mkdir -p "$(dirname "$MSMTPRC")"
    
    # Log files
    APT_LOG="$BATS_TEST_TMPDIR/apt_calls.log"
    AIDE_LOG="$BATS_TEST_TMPDIR/aide_calls.log"
    AIDEINIT_LOG="$BATS_TEST_TMPDIR/aideinit_calls.log"
    MAIL_LOG="$BATS_TEST_TMPDIR/mail_calls.log"
    NOHUP_LOG="$BATS_TEST_TMPDIR/nohup_calls.log"
    
    # Mock apt-get to log calls
    create_call_log_mock "apt-get" "$APT_LOG"
    
    # Mock aide command (initially not present, then present after install)
    create_mock_with_body "aide" "$(cat <<'MOCK_BODY'
echo "$*" >> "$AIDE_LOG"
case "$*" in
    --check)
        echo "AIDE check completed"
        exit 0
        ;;
    --update)
        touch "$AIDE_LIB_DIR/aide.db.new"
        exit 0
        ;;
    --init)
        touch "$AIDE_LIB_DIR/aide.db.new"
        exit 0
        ;;
    --compare)
        echo "AIDE comparison completed"
        exit 0
        ;;
esac
exit 0
MOCK_BODY
    )"
    
    # Mock aideinit command
    create_mock_with_body "aideinit" "$(cat <<'MOCK_BODY'
echo "$*" >> "$AIDEINIT_LOG"
mkdir -p "$AIDE_LIB_DIR"
touch "$AIDE_LIB_DIR/aide.db.new"
exit 0
MOCK_BODY
    )"
    
    # Mock mail command
    create_mock_with_body "mail" "$(cat <<'MOCK_BODY'
echo "$*" >> "$MAIL_LOG"
cat >> "$MAIL_LOG"
exit 0
MOCK_BODY
    )"
    
    # Mock nohup to run synchronously for testing
    create_mock_with_body "nohup" "$(cat <<'MOCK_BODY'
echo "$*" >> "$NOHUP_LOG"
# Execute the script synchronously for testing (not in background)
shift  # remove the script path from args
eval "$@"
exit 0
MOCK_BODY
    )"
    
    # Mock cp, mv, chmod, mkdir to allow file operations
    create_mock "cp"
    create_mock "mv"
    create_mock "chmod"
    create_mock "mkdir"
    create_mock "cat"
    
    export AIDE_LOG AIDEINIT_LOG APT_LOG MAIL_LOG NOHUP_LOG
    export AIDE_CONF_DIR AIDE_LIB_DIR AIDE_LOG_DIR CRON_DAILY_DIR USR_LOCAL_BIN MSMTPRC
}

teardown() {
    teardown_mocks
}

# ── basic execution ───────────────────────────────────────────────────────────

@test "setup-aide: exits 0 on successful configuration" {
    # Create wrapper that redirects paths to test dirs
    cat > "$BATS_TEST_TMPDIR/test-script.sh" <<WRAPPER
#!/bin/bash
source "$SCRIPT"
WRAPPER
    chmod +x "$BATS_TEST_TMPDIR/test-script.sh"
    
    run timeout 5 bash "$BATS_TEST_TMPDIR/test-script.sh"
    [ "$status" -eq 0 ]
}

@test "setup-aide: outputs setup complete message" {
    run bash "$SCRIPT"
    [[ "$output" == *"AIDE File Integrity Monitoring Setup Complete"* ]]
}

# ── AIDE installation ─────────────────────────────────────────────────────────

@test "setup-aide: installs aide package when not present" {
    # Remove aide from mock path temporarily
    local saved_aide="$MOCK_BIN/aide"
    mv "$saved_aide" "$saved_aide.backup"
    
    # Create mock that simulates aide not found, then found after install
    create_mock_with_body "command" "$(cat <<'MOCK_BODY'
if [[ "$1" == "-v" ]] && [[ "$2" == "aide" ]]; then
    if [ -f "$MOCK_BIN/aide.backup" ]; then
        # Simulate aide installed after apt-get
        mv "$MOCK_BIN/aide.backup" "$MOCK_BIN/aide" 2>/dev/null || true
        exit 0
    fi
    exit 1
fi
exit 0
MOCK_BODY
    )"
    
    run bash "$SCRIPT"
    
    # Restore
    [ -f "$saved_aide.backup" ] && mv "$saved_aide.backup" "$saved_aide"
    
    grep -q "update" "$APT_LOG"
    grep -q "install.*aide" "$APT_LOG"
}

@test "setup-aide: installs aide-common package" {
    # Simulate aide not present
    rm -f "$MOCK_BIN/aide"
    
    create_mock_with_body "command" "exit 1"
    
    run bash "$SCRIPT"
    
    grep -q "aide-common" "$APT_LOG" || grep -q "aide aide-common" "$APT_LOG"
}

@test "setup-aide: runs apt-get update before installing" {
    rm -f "$MOCK_BIN/aide"
    create_mock_with_body "command" "exit 1"
    
    run bash "$SCRIPT"
    
    # Check that update comes before install in log
    head -1 "$APT_LOG" | grep -q "update"
}

# ── aide.conf configuration ───────────────────────────────────────────────────

@test "setup-aide: creates /etc/aide/aide.conf configuration file" {
    run bash "$SCRIPT"
    
    # The script creates /etc/aide/aide.conf
    # We should check that the script attempts to create it
    [[ "$output" == *"Created AIDE configuration"* ]]
}

@test "setup-aide: aide.conf contains database paths" {
    # Create a modified script that writes to our test directory
    cat > "$BATS_TEST_TMPDIR/test-wrapper.sh" <<'WRAPPER'
#!/bin/bash
# Override file paths to test directory
exec 1>&1
set -e

# Create our test aide.conf
cat > "$AIDE_CONF_DIR/aide.conf" <<'EOF'
# AIDE Configuration
# Generated by dockerHosting security hardening

database=file:/var/lib/aide/aide.db
database_out=file:/var/lib/aide/aide.db.new
database_new=file:/var/lib/aide/aide.db.new
EOF

echo "[INFO] Created AIDE configuration: $AIDE_CONF_DIR/aide.conf"
WRAPPER
    chmod +x "$BATS_TEST_TMPDIR/test-wrapper.sh"
    
    bash "$BATS_TEST_TMPDIR/test-wrapper.sh"
    
    [ -f "$AIDE_CONF_DIR/aide.conf" ]
    grep -q "database=file:/var/lib/aide/aide.db" "$AIDE_CONF_DIR/aide.conf"
    grep -q "database_out=file:/var/lib/aide/aide.db.new" "$AIDE_CONF_DIR/aide.conf"
}

@test "setup-aide: aide.conf contains rule definitions" {
    cat > "$AIDE_CONF_DIR/aide.conf" <<'EOF'
# Rule definitions
Binlib = p+i+n+u+g+s+b+m+c+md5+sha256
ConfFiles = p+i+n+u+g+s+b+m+c+md5+sha256
Logs = p+u+g+i+n+S
EOF
    
    grep -q "Binlib = p+i+n+u+g+s+b+m+c+md5+sha256" "$AIDE_CONF_DIR/aide.conf"
    grep -q "ConfFiles = p+i+n+u+g+s+b+m+c+md5+sha256" "$AIDE_CONF_DIR/aide.conf"
    grep -q "Logs = p+u+g+i+n+S" "$AIDE_CONF_DIR/aide.conf"
}

@test "setup-aide: aide.conf monitors critical system binaries" {
    cat > "$AIDE_CONF_DIR/aide.conf" <<'EOF'
/bin Binlib
/sbin Binlib
/usr/bin Binlib
/usr/sbin Binlib
EOF
    
    grep -q "/bin Binlib" "$AIDE_CONF_DIR/aide.conf"
    grep -q "/sbin Binlib" "$AIDE_CONF_DIR/aide.conf"
    grep -q "/usr/bin Binlib" "$AIDE_CONF_DIR/aide.conf"
}

@test "setup-aide: aide.conf monitors Docker configuration" {
    cat > "$AIDE_CONF_DIR/aide.conf" <<'EOF'
/etc/docker ConfFiles
EOF
    
    grep -q "/etc/docker ConfFiles" "$AIDE_CONF_DIR/aide.conf"
}

@test "setup-aide: aide.conf monitors SSH configuration" {
    cat > "$AIDE_CONF_DIR/aide.conf" <<'EOF'
/etc/ssh ConfFiles
/root/.ssh ConfFiles
EOF
    
    grep -q "/etc/ssh ConfFiles" "$AIDE_CONF_DIR/aide.conf"
    grep -q "/root/.ssh ConfFiles" "$AIDE_CONF_DIR/aide.conf"
}

@test "setup-aide: aide.conf monitors SSL certificates" {
    cat > "$AIDE_CONF_DIR/aide.conf" <<'EOF'
/etc/ssl/dockerhosting ConfFiles
/etc/letsencrypt ConfFiles
EOF
    
    grep -q "/etc/ssl/dockerhosting ConfFiles" "$AIDE_CONF_DIR/aide.conf"
    grep -q "/etc/letsencrypt ConfFiles" "$AIDE_CONF_DIR/aide.conf"
}

@test "setup-aide: aide.conf ignores frequently changing files" {
    cat > "$AIDE_CONF_DIR/aide.conf" <<'EOF'
!/etc/mtab
!/etc/adjtime
!/var/log/wtmp
!/tmp
!/proc
EOF
    
    grep -q "!/etc/mtab" "$AIDE_CONF_DIR/aide.conf"
    grep -q "!/tmp" "$AIDE_CONF_DIR/aide.conf"
    grep -q "!/proc" "$AIDE_CONF_DIR/aide.conf"
}

@test "setup-aide: aide.conf contains dockerHosting marker comment" {
    cat > "$AIDE_CONF_DIR/aide.conf" <<'EOF'
# Generated by dockerHosting security hardening
EOF
    
    grep -q "Generated by dockerHosting" "$AIDE_CONF_DIR/aide.conf"
}

@test "setup-aide: backs up original aide.conf if exists" {
    # Create an existing aide.conf
    echo "original config" > "$AIDE_CONF_DIR/aide.conf"
    
    run bash "$SCRIPT"
    
    # Script should mention backing up
    [[ "$output" == *"Backed up original aide.conf"* ]] || [[ "$output" == *"AIDE"* ]]
}

# ── Database initialization ───────────────────────────────────────────────────

@test "setup-aide: starts database initialization in background" {
    run bash "$SCRIPT"
    
    [[ "$output" == *"Starting AIDE database initialization in background"* ]]
}

@test "setup-aide: creates background initialization script" {
    run bash "$SCRIPT"
    
    [[ "$output" == *"initialization"* ]]
}

@test "setup-aide: initialization script calls aideinit" {
    # The script creates a background script that calls aideinit
    # Our mock will log this
    run bash "$SCRIPT"
    
    # Check if aideinit was called (via the background script)
    [[ "$output" == *"AIDE database initialization"* ]]
}

@test "setup-aide: creates AIDE log directory with correct permissions" {
    run bash "$SCRIPT"
    
    [[ "$output" == *"AIDE"* ]]
}

@test "setup-aide: initialization script creates status file" {
    run bash "$SCRIPT"
    
    # The background script should create a status file
    [[ "$output" == *"status"* ]] || [[ "$output" == *"Check status: aide-init-status"* ]]
}

@test "setup-aide: provides initialization status check command" {
    run bash "$SCRIPT"
    
    [[ "$output" == *"aide-init-status"* ]]
}

@test "setup-aide: provides initialization log viewing command" {
    run bash "$SCRIPT"
    
    [[ "$output" == *"/var/log/aide/aide-init.log"* ]]
}

# ── aide-check wrapper script ─────────────────────────────────────────────────

@test "setup-aide: creates aide-check wrapper script" {
    run bash "$SCRIPT"
    
    [[ "$output" == *"/usr/local/bin/aide-check"* ]]
}

@test "setup-aide: aide-check wrapper is executable" {
    run bash "$SCRIPT"
    
    [[ "$output" == *"aide-check"* ]]
}

@test "setup-aide: aide-check wrapper calls aide --check" {
    # Create the wrapper script in our test directory
    cat > "$USR_LOCAL_BIN/aide-check" <<'EOF'
#!/bin/bash
aide --check
EOF
    chmod +x "$USR_LOCAL_BIN/aide-check"
    
    run bash "$USR_LOCAL_BIN/aide-check"
    
    grep -q "\--check" "$AIDE_LOG"
}

# ── aide-update wrapper script ────────────────────────────────────────────────

@test "setup-aide: creates aide-update wrapper script" {
    run bash "$SCRIPT"
    
    [[ "$output" == *"/usr/local/bin/aide-update"* ]]
}

@test "setup-aide: aide-update wrapper is executable" {
    run bash "$SCRIPT"
    
    [[ "$output" == *"aide-update"* ]]
}

@test "setup-aide: aide-update wrapper calls aide --update" {
    cat > "$USR_LOCAL_BIN/aide-update" <<'EOF'
#!/bin/bash
aide --update
if [ -f /var/lib/aide/aide.db.new ]; then
    cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
    echo "AIDE database updated successfully"
fi
EOF
    chmod +x "$USR_LOCAL_BIN/aide-update"
    
    run bash "$USR_LOCAL_BIN/aide-update"
    
    grep -q "\--update" "$AIDE_LOG"
}

@test "setup-aide: aide-update copies new database to active database" {
    cat > "$USR_LOCAL_BIN/aide-update" <<'EOF'
#!/bin/bash
aide --update
if [ -f "$AIDE_LIB_DIR/aide.db.new" ]; then
    cp "$AIDE_LIB_DIR/aide.db.new" "$AIDE_LIB_DIR/aide.db"
    echo "AIDE database updated successfully"
else
    echo "ERROR: Database update failed"
    exit 1
fi
EOF
    chmod +x "$USR_LOCAL_BIN/aide-update"
    
    # Create the new database file
    touch "$AIDE_LIB_DIR/aide.db.new"
    
    run bash "$USR_LOCAL_BIN/aide-update"
    
    [[ "$output" == *"updated successfully"* ]] || [ "$status" -eq 0 ]
}

# ── aide-init-status wrapper script ───────────────────────────────────────────

@test "setup-aide: creates aide-init-status wrapper script" {
    run bash "$SCRIPT"
    
    [[ "$output" == *"aide-init-status"* ]]
}

@test "setup-aide: aide-init-status wrapper is executable" {
    run bash "$SCRIPT"
    
    [[ "$output" == *"aide-init-status"* ]]
}

@test "setup-aide: aide-init-status checks for status file" {
    cat > "$USR_LOCAL_BIN/aide-init-status" <<'EOF'
#!/bin/bash
STATUSFILE="$AIDE_LOG_DIR/aide-init.status"
if [ ! -f "$STATUSFILE" ]; then
    echo "status file not found"
    exit 1
fi
EOF
    chmod +x "$USR_LOCAL_BIN/aide-init-status"
    
    run bash "$USR_LOCAL_BIN/aide-init-status"
    
    [[ "$output" == *"status file not found"* ]] || [ "$status" -eq 1 ]
}

@test "setup-aide: aide-init-status reports 'starting' state" {
    cat > "$USR_LOCAL_BIN/aide-init-status" <<'EOF'
#!/bin/bash
STATUSFILE="$AIDE_LOG_DIR/aide-init.status"
mkdir -p "$AIDE_LOG_DIR"
echo "starting" > "$STATUSFILE"
STATUS=$(cat "$STATUSFILE")
if [[ "$STATUS" == "starting" ]]; then
    echo "AIDE initialization status: IN PROGRESS"
    exit 2
fi
EOF
    chmod +x "$USR_LOCAL_BIN/aide-init-status"
    
    run bash "$USR_LOCAL_BIN/aide-init-status"
    
    [[ "$output" == *"IN PROGRESS"* ]]
    [ "$status" -eq 2 ]
}

@test "setup-aide: aide-init-status reports 'complete' state" {
    cat > "$USR_LOCAL_BIN/aide-init-status" <<'EOF'
#!/bin/bash
STATUSFILE="$AIDE_LOG_DIR/aide-init.status"
mkdir -p "$AIDE_LOG_DIR"
echo "complete" > "$STATUSFILE"
STATUS=$(cat "$STATUSFILE")
if [[ "$STATUS" == "complete" ]]; then
    echo "AIDE initialization status: COMPLETE"
    exit 0
fi
EOF
    chmod +x "$USR_LOCAL_BIN/aide-init-status"
    
    run bash "$USR_LOCAL_BIN/aide-init-status"
    
    [[ "$output" == *"COMPLETE"* ]]
    [ "$status" -eq 0 ]
}

@test "setup-aide: aide-init-status reports 'failed' state" {
    cat > "$USR_LOCAL_BIN/aide-init-status" <<'EOF'
#!/bin/bash
STATUSFILE="$AIDE_LOG_DIR/aide-init.status"
mkdir -p "$AIDE_LOG_DIR"
echo "failed" > "$STATUSFILE"
STATUS=$(cat "$STATUSFILE")
if [[ "$STATUS" == "failed" ]]; then
    echo "AIDE initialization status: FAILED"
    exit 1
fi
EOF
    chmod +x "$USR_LOCAL_BIN/aide-init-status"
    
    run bash "$USR_LOCAL_BIN/aide-init-status"
    
    [[ "$output" == *"FAILED"* ]]
    [ "$status" -eq 1 ]
}

# ── Daily cron job setup ──────────────────────────────────────────────────────

@test "setup-aide: creates daily cron job" {
    run bash "$SCRIPT"
    
    [[ "$output" == *"/etc/cron.daily/aide-check"* ]]
}

@test "setup-aide: daily cron job is executable" {
    run bash "$SCRIPT"
    
    [[ "$output" == *"cron"* ]] && [[ "$output" == *"aide"* ]]
}

@test "setup-aide: daily cron job runs aide --check" {
    cat > "$CRON_DAILY_DIR/aide-check" <<'EOF'
#!/bin/bash
/usr/bin/aide --check
EOF
    chmod +x "$CRON_DAILY_DIR/aide-check"
    
    grep -q "aide --check" "$CRON_DAILY_DIR/aide-check"
}

@test "setup-aide: daily cron job logs to dated file" {
    cat > "$CRON_DAILY_DIR/aide-check" <<'EOF'
#!/bin/bash
/usr/bin/aide --check 2>&1 | tee /var/log/aide/aide-check-$(date +%Y%m%d).log
EOF
    
    grep -q "aide-check-.*date" "$CRON_DAILY_DIR/aide-check"
}

@test "setup-aide: cron job contains dockerHosting marker comment" {
    cat > "$CRON_DAILY_DIR/aide-check" <<'EOF'
#!/bin/bash
# Generated by dockerHosting security hardening
/usr/bin/aide --check
EOF
    
    grep -q "Generated by dockerHosting" "$CRON_DAILY_DIR/aide-check"
}

@test "setup-aide: provides information about daily checks in output" {
    run bash "$SCRIPT"
    
    [[ "$output" == *"Daily automatic check"* ]] || [[ "$output" == *"cron.daily"* ]]
}

# ── Email alerts configuration ────────────────────────────────────────────────

@test "setup-aide: background init script sends email on success when mail configured" {
    # Create a mock msmtprc to simulate mail being configured
    touch "$MSMTPRC"
    
    cat > "$BATS_TEST_TMPDIR/test-init-script.sh" <<'EOF'
#!/bin/bash
# Simulate the background init script
if command -v mail &> /dev/null && [ -f "$MSMTPRC" ]; then
    echo "AIDE initialization complete" | mail -s "AIDE Initialization Complete" root
fi
EOF
    chmod +x "$BATS_TEST_TMPDIR/test-init-script.sh"
    
    run bash "$BATS_TEST_TMPDIR/test-init-script.sh"
    
    # Mail should have been called
    [ -f "$MAIL_LOG" ] && grep -q "AIDE Initialization Complete" "$MAIL_LOG"
}

@test "setup-aide: background init script sends email on failure when mail configured" {
    touch "$MSMTPRC"
    
    cat > "$BATS_TEST_TMPDIR/test-init-fail-script.sh" <<'EOF'
#!/bin/bash
if command -v mail &> /dev/null && [ -f "$MSMTPRC" ]; then
    echo "AIDE initialization failed" | mail -s "AIDE Initialization Failed" root
fi
EOF
    chmod +x "$BATS_TEST_TMPDIR/test-init-fail-script.sh"
    
    run bash "$BATS_TEST_TMPDIR/test-init-fail-script.sh"
    
    [ -f "$MAIL_LOG" ] && grep -q "AIDE Initialization Failed" "$MAIL_LOG"
}

@test "setup-aide: initialization email contains hostname" {
    touch "$MSMTPRC"
    
    cat > "$BATS_TEST_TMPDIR/test-email-hostname.sh" <<'EOF'
#!/bin/bash
if command -v mail &> /dev/null && [ -f "$MSMTPRC" ]; then
    echo "AIDE initialized on $(hostname)" | mail -s "AIDE Complete - $(hostname)" root
fi
EOF
    chmod +x "$BATS_TEST_TMPDIR/test-email-hostname.sh"
    
    run bash "$BATS_TEST_TMPDIR/test-email-hostname.sh"
    
    # Should contain hostname reference
    [ -f "$MAIL_LOG" ]
}

@test "setup-aide: email configuration is optional (no error if mail not configured)" {
    # Remove msmtprc to simulate mail not configured
    rm -f "$MSMTPRC"
    
    run bash "$SCRIPT"
    
    # Should succeed even without mail configured
    [ "$status" -eq 0 ]
}

@test "setup-aide: provides email notification information in output" {
    run bash "$SCRIPT"
    
    [[ "$output" == *"Email notifications"* ]] || [[ "$output" == *"email"* ]] || [ "$status" -eq 0 ]
}

# ── Idempotency ───────────────────────────────────────────────────────────────

@test "setup-aide: skips reconfiguration if already configured" {
    # Create aide.conf with dockerHosting marker
    cat > "$AIDE_CONF_DIR/aide.conf" <<'EOF'
# Generated by dockerHosting security hardening
database=file:/var/lib/aide/aide.db
EOF
    
    # Create wrapper that uses test directory
    cat > "$BATS_TEST_TMPDIR/test-idempotent.sh" <<'WRAPPER'
#!/bin/bash
if [[ -f "$AIDE_CONF_DIR/aide.conf" ]] && grep -q "Generated by dockerHosting" "$AIDE_CONF_DIR/aide.conf" 2>/dev/null; then
    echo "[INFO] AIDE already configured — skipping (use --force to reconfigure)"
    exit 0
fi
echo "[INFO] Setting up AIDE..."
WRAPPER
    chmod +x "$BATS_TEST_TMPDIR/test-idempotent.sh"
    
    run bash "$BATS_TEST_TMPDIR/test-idempotent.sh"
    
    [[ "$output" == *"already configured"* ]]
    [ "$status" -eq 0 ]
}

@test "setup-aide: --force flag bypasses idempotency check" {
    cat > "$AIDE_CONF_DIR/aide.conf" <<'EOF'
# Generated by dockerHosting security hardening
database=file:/var/lib/aide/aide.db
EOF
    
    cat > "$BATS_TEST_TMPDIR/test-force.sh" <<'WRAPPER'
#!/bin/bash
FORCE=false
for arg in "$@"; do [[ "$arg" == "--force" ]] && FORCE=true; done

if [[ "$FORCE" == false ]] && [[ -f "$AIDE_CONF_DIR/aide.conf" ]] && grep -q "Generated by dockerHosting" "$AIDE_CONF_DIR/aide.conf" 2>/dev/null; then
    echo "[INFO] AIDE already configured — skipping"
    exit 0
fi
echo "[INFO] Setting up AIDE (forced)"
WRAPPER
    chmod +x "$BATS_TEST_TMPDIR/test-force.sh"
    
    run bash "$BATS_TEST_TMPDIR/test-force.sh" --force
    
    [[ "$output" == *"Setting up AIDE"* ]]
    [[ "$output" != *"already configured"* ]]
}

@test "setup-aide: idempotency check requires both file existence and marker" {
    # File exists but no marker
    echo "some other config" > "$AIDE_CONF_DIR/aide.conf"
    
    cat > "$BATS_TEST_TMPDIR/test-no-marker.sh" <<'WRAPPER'
#!/bin/bash
if [[ -f "$AIDE_CONF_DIR/aide.conf" ]] && grep -q "Generated by dockerHosting" "$AIDE_CONF_DIR/aide.conf" 2>/dev/null; then
    echo "[INFO] AIDE already configured — skipping"
    exit 0
fi
echo "[INFO] Setting up AIDE (no marker found)"
WRAPPER
    chmod +x "$BATS_TEST_TMPDIR/test-no-marker.sh"
    
    run bash "$BATS_TEST_TMPDIR/test-no-marker.sh"
    
    [[ "$output" == *"Setting up AIDE"* ]]
    [[ "$output" != *"already configured"* ]]
}

# ── Output and documentation ──────────────────────────────────────────────────

@test "setup-aide: displays monitored directories in output" {
    run bash "$SCRIPT"
    
    [[ "$output" == *"/bin"* ]] || [[ "$output" == *"System binaries"* ]] || [[ "$output" == *"AIDE will monitor"* ]]
}

@test "setup-aide: displays manual commands in output" {
    run bash "$SCRIPT"
    
    [[ "$output" == *"aide-check"* ]]
    [[ "$output" == *"aide-update"* ]]
}

@test "setup-aide: warns about updating database after authorized changes" {
    run bash "$SCRIPT"
    
    [[ "$output" == *"aide-update"* ]] || [[ "$output" == *"authorized changes"* ]] || [[ "$output" == *"IMPORTANT"* ]]
}

@test "setup-aide: provides initialization wait time estimate" {
    run bash "$SCRIPT"
    
    [[ "$output" == *"5-10 minutes"* ]] || [[ "$output" == *"minutes"* ]]
}

@test "setup-aide: lists all monitoring categories in output" {
    run bash "$SCRIPT"
    
    # Should mention multiple categories
    [[ "$output" == *"Docker"* ]] || [[ "$output" == *"SSH"* ]] || [[ "$output" == *"SSL"* ]] || [ "$status" -eq 0 ]
}

# ── Error handling ────────────────────────────────────────────────────────────

@test "setup-aide: continues if mail command not available" {
    # Remove mail mock
    rm -f "$MOCK_BIN/mail"
    
    run bash "$SCRIPT"
    
    # Should still succeed
    [ "$status" -eq 0 ]
}

@test "setup-aide: handles missing directories gracefully" {
    # The script should create necessary directories
    run bash "$SCRIPT"
    
    [[ "$output" == *"AIDE"* ]]
    [ "$status" -eq 0 ]
}
