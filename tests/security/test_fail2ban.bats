#!/usr/bin/env bats
# Tests for scripts/setup-fail2ban-enhanced.sh
# Verifies fail2ban installation, SSH jail configuration with progressive bans

load '../helpers/common'

SCRIPT="$SCRIPTS_DIR/setup-fail2ban-enhanced.sh"

setup() {
    setup_mocks
    
    # Override paths for isolation
    export JAIL_LOCAL="$BATS_TEST_TMPDIR/jail.d/sshd-enhanced.conf"
    export JAIL_DIR="$BATS_TEST_TMPDIR/jail.d"
    mkdir -p "$JAIL_DIR"
    
    # Mock fail2ban-client to indicate it's installed
    create_mock_with_body "fail2ban-client" "$(cat <<'MOCK_BODY'
if [[ "$1" == "status" ]]; then
    echo "Status"
    echo "|- Number of jail:    1"
    echo "\`- Jail list:   sshd"
fi
exit 0
MOCK_BODY
    )"
    
    # Mock systemctl
    SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl_calls.log"
    create_mock_with_body "systemctl" "$(cat <<'MOCK_BODY'
echo "$*" >> "$SYSTEMCTL_LOG"
if [[ "$*" == "is-active --quiet fail2ban" ]]; then
    exit 0
fi
exit 0
MOCK_BODY
    )"
    
    # Mock apt-get (in case needed)
    create_call_log_mock "apt-get" "$BATS_TEST_TMPDIR/apt_calls.log"
    
    # Mock sleep to avoid delays
    create_mock "sleep"
    
    export SYSTEMCTL_LOG
    
    # Patch the script to use our overridden paths
    FAIL2BAN_SCRIPT="$BATS_TEST_TMPDIR/setup-fail2ban-patched.sh"
    sed \
        -e "s|/etc/fail2ban/jail.d|$JAIL_DIR|g" \
        "$SCRIPT" > "$FAIL2BAN_SCRIPT"
    chmod +x "$FAIL2BAN_SCRIPT"
}

teardown() {
    teardown_mocks
}

# ── basic execution ───────────────────────────────────────────────────────────

@test "setup-fail2ban: exits 0 on successful configuration" {
    run bash "$FAIL2BAN_SCRIPT" --force
    [ "$status" -eq 0 ]
}

@test "setup-fail2ban: runs without errors when fail2ban-client exists" {
    run bash "$FAIL2BAN_SCRIPT" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"fail2ban Enhanced Protection Complete"* ]]
}

@test "setup-fail2ban: exits 1 when fail2ban-client is not installed" {
    # Remove the mock to simulate missing fail2ban
    rm -f "$MOCK_BIN/fail2ban-client"
    
    run bash "$FAIL2BAN_SCRIPT" --force
    [ "$status" -eq 1 ]
    [[ "$output" == *"fail2ban is not installed"* ]]
}

# ── idempotency ───────────────────────────────────────────────────────────────

@test "setup-fail2ban: skips configuration if already configured (without --force)" {
    # Create existing config to simulate previous run
    touch "$JAIL_LOCAL"
    
    run bash "$FAIL2BAN_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already configured"* ]]
    [[ "$output" == *"skipping"* ]]
}

@test "setup-fail2ban: reconfigures when --force flag is provided" {
    # Create existing config
    echo "old config" > "$JAIL_LOCAL"
    
    run bash "$FAIL2BAN_SCRIPT" --force
    [ "$status" -eq 0 ]
    
    # Should contain new configuration, not old
    assert_file_exists "$JAIL_LOCAL"
    refute_file_contains "$JAIL_LOCAL" "old config"
}

# ── jail directory creation ───────────────────────────────────────────────────

@test "setup-fail2ban: creates jail.d directory if missing" {
    rm -rf "$JAIL_DIR"
    
    bash "$FAIL2BAN_SCRIPT" --force
    
    [ -d "$JAIL_DIR" ]
}

# ── SSH jail configuration ────────────────────────────────────────────────────

@test "setup-fail2ban: creates sshd-enhanced.conf jail file" {
    bash "$FAIL2BAN_SCRIPT" --force
    
    assert_file_exists "$JAIL_LOCAL"
}

@test "setup-fail2ban: SSH jail is enabled" {
    bash "$FAIL2BAN_SCRIPT" --force
    
    assert_file_contains "$JAIL_LOCAL" "enabled = true"
}

@test "setup-fail2ban: SSH jail monitors ssh port" {
    bash "$FAIL2BAN_SCRIPT" --force
    
    assert_file_contains "$JAIL_LOCAL" "port = ssh"
}

@test "setup-fail2ban: SSH jail uses sshd filter" {
    bash "$FAIL2BAN_SCRIPT" --force
    
    assert_file_contains "$JAIL_LOCAL" "filter = sshd"
}

@test "setup-fail2ban: SSH jail monitors /var/log/auth.log" {
    bash "$FAIL2BAN_SCRIPT" --force
    
    assert_file_contains "$JAIL_LOCAL" "logpath = /var/log/auth.log"
}

# ── ban threshold (maxretry) ──────────────────────────────────────────────────

@test "setup-fail2ban: sets maxretry to 3 failed attempts" {
    bash "$FAIL2BAN_SCRIPT" --force
    
    assert_file_contains "$JAIL_LOCAL" "maxretry = 3"
}

@test "setup-fail2ban: sets findtime to 600 seconds (10 minutes)" {
    bash "$FAIL2BAN_SCRIPT" --force
    
    assert_file_contains "$JAIL_LOCAL" "findtime = 600"
}

# ── progressive ban times ─────────────────────────────────────────────────────

@test "setup-fail2ban: sets initial bantime to 3600 seconds (1 hour)" {
    bash "$FAIL2BAN_SCRIPT" --force
    
    assert_file_contains "$JAIL_LOCAL" "bantime = 3600"
}

@test "setup-fail2ban: enables progressive ban time increment" {
    bash "$FAIL2BAN_SCRIPT" --force
    
    assert_file_contains "$JAIL_LOCAL" "bantime.increment = true"
}

@test "setup-fail2ban: configures ban time multipliers for progressive bans" {
    bash "$FAIL2BAN_SCRIPT" --force
    
    # Multipliers: 1 2 4 8 16 32 64 result in:
    # 1h, 2h, 4h, 8h, 16h, 32h, 64h (capped at maxtime)
    assert_file_contains "$JAIL_LOCAL" "bantime.multipliers = 1 2 4 8 16 32 64"
}

@test "setup-fail2ban: sets maximum ban time to 604800 seconds (7 days)" {
    bash "$FAIL2BAN_SCRIPT" --force
    
    assert_file_contains "$JAIL_LOCAL" "bantime.maxtime = 604800"
}

@test "setup-fail2ban: jail configuration includes [sshd] section header" {
    bash "$FAIL2BAN_SCRIPT" --force
    
    assert_file_contains "$JAIL_LOCAL" "[sshd]"
}

# ── stale configuration cleanup ───────────────────────────────────────────────

@test "setup-fail2ban: removes stale nginx-enhanced.conf if present" {
    local nginx_jail="$JAIL_DIR/nginx-enhanced.conf"
    echo "stale nginx config" > "$nginx_jail"
    
    bash "$FAIL2BAN_SCRIPT" --force
    
    [ ! -f "$nginx_jail" ]
}

# ── service restart ───────────────────────────────────────────────────────────

@test "setup-fail2ban: restarts fail2ban service after configuration" {
    bash "$FAIL2BAN_SCRIPT" --force
    
    grep -q "restart fail2ban" "$SYSTEMCTL_LOG"
}

@test "setup-fail2ban: verifies fail2ban is active after restart" {
    bash "$FAIL2BAN_SCRIPT" --force
    
    grep -q "is-active --quiet fail2ban" "$SYSTEMCTL_LOG"
}

@test "setup-fail2ban: exits 1 if fail2ban fails to start" {
    # Mock systemctl is-active to fail
    create_mock_with_body "systemctl" "$(cat <<'MOCK_BODY'
echo "$*" >> "$SYSTEMCTL_LOG"
if [[ "$*" == "is-active --quiet fail2ban" ]]; then
    exit 1
fi
exit 0
MOCK_BODY
    )"
    
    run bash "$FAIL2BAN_SCRIPT" --force
    [ "$status" -eq 1 ]
    [[ "$output" == *"fail2ban failed to start"* ]]
}

# ── fail2ban-client status check ──────────────────────────────────────────────

@test "setup-fail2ban: calls fail2ban-client status to display active jails" {
    local client_log="$BATS_TEST_TMPDIR/fail2ban_client.log"
    
    create_mock_with_body "fail2ban-client" "$(cat <<MOCK_BODY
echo "\$*" >> "$client_log"
if [[ "\$1" == "status" ]]; then
    echo "Status"
    echo "|- Number of jail:    1"
    echo "\\\`- Jail list:   sshd"
fi
exit 0
MOCK_BODY
    )"
    
    bash "$FAIL2BAN_SCRIPT" --force
    
    assert_file_exists "$client_log"
    assert_file_contains "$client_log" "status"
}

# ── output messages ───────────────────────────────────────────────────────────

@test "setup-fail2ban: displays SSH brute-force protection message" {
    run bash "$FAIL2BAN_SCRIPT" --force
    
    [[ "$output" == *"SSH brute-force"* ]]
    [[ "$output" == *"3 attempts"* ]]
    [[ "$output" == *"1 hour ban"* ]]
}

@test "setup-fail2ban: displays ban time escalation schedule" {
    run bash "$FAIL2BAN_SCRIPT" --force
    
    [[ "$output" == *"1st ban: 1 hour"* ]]
    [[ "$output" == *"2nd ban: 2 hours"* ]]
    [[ "$output" == *"3rd ban: 4 hours"* ]]
    [[ "$output" == *"4th ban: 8 hours"* ]]
    [[ "$output" == *"7 days maximum"* ]]
}

@test "setup-fail2ban: displays useful fail2ban commands" {
    run bash "$FAIL2BAN_SCRIPT" --force
    
    [[ "$output" == *"fail2ban-client status"* ]]
    [[ "$output" == *"fail2ban-client banned"* ]]
    [[ "$output" == *"fail2ban-client unban"* ]]
}

@test "setup-fail2ban: displays enhanced SSH jail configuration message" {
    run bash "$FAIL2BAN_SCRIPT" --force
    
    [[ "$output" == *"Enhanced SSH jail configuration"* ]]
}

# ── complete workflow integration ─────────────────────────────────────────────

@test "setup-fail2ban: complete workflow creates valid configuration" {
    # Start fresh
    rm -f "$JAIL_LOCAL"
    
    run bash "$FAIL2BAN_SCRIPT" --force
    [ "$status" -eq 0 ]
    
    # Verify file created
    assert_file_exists "$JAIL_LOCAL"
    
    # Verify all critical settings present
    assert_file_contains "$JAIL_LOCAL" "[sshd]"
    assert_file_contains "$JAIL_LOCAL" "enabled = true"
    assert_file_contains "$JAIL_LOCAL" "maxretry = 3"
    assert_file_contains "$JAIL_LOCAL" "bantime = 3600"
    assert_file_contains "$JAIL_LOCAL" "bantime.increment = true"
    assert_file_contains "$JAIL_LOCAL" "bantime.maxtime = 604800"
    
    # Verify service restarted
    grep -q "restart fail2ban" "$SYSTEMCTL_LOG"
}
