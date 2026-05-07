#!/usr/bin/env bats
# Tests for scripts/harden-ssh.sh (SSH hardening)

load '../helpers/common'

setup() {
    setup_mocks

    # Override file paths for isolation
    export SSHD_CONFIG="$BATS_TEST_TMPDIR/sshd_config"
    export SSHD_CONFIG_BACKUP="$BATS_TEST_TMPDIR/sshd_config.backup"
    export SSHD_CONFIG_DIR="$BATS_TEST_TMPDIR/sshd_config.d"
    export SSHD_HARDENING_CONF="$SSHD_CONFIG_DIR/99-hardening.conf"
    export SSH_BANNER="$BATS_TEST_TMPDIR/banner.txt"
    export FAIL2BAN_JAIL_DIR="$BATS_TEST_TMPDIR/fail2ban/jail.d"
    export FAIL2BAN_SSHD_CONF="$FAIL2BAN_JAIL_DIR/sshd.conf"

    mkdir -p "$SSHD_CONFIG_DIR" "$FAIL2BAN_JAIL_DIR"

    # Create a minimal original sshd_config
    cat > "$SSHD_CONFIG" <<'EOF'
# Original SSH configuration
Port 22
PermitRootLogin yes
PasswordAuthentication yes
EOF

    # Mock system commands
    create_mock "systemctl"
    create_mock "sshd"  # sshd -t validates config
    create_mock "chmod"
    create_mock "fail2ban-client"

    # Patch the script to use our overridden paths
    HARDEN_SSH_SCRIPT="$BATS_TEST_TMPDIR/harden-ssh-patched.sh"
    sed \
        -e "s|/etc/ssh/sshd_config.d/99-hardening.conf|$SSHD_HARDENING_CONF|g" \
        -e "s|/etc/ssh/sshd_config.backup|$SSHD_CONFIG_BACKUP|g" \
        -e "s|/etc/ssh/sshd_config|$SSHD_CONFIG|g" \
        -e "s|/etc/ssh/sshd_config.d|$SSHD_CONFIG_DIR|g" \
        -e "s|/etc/ssh/banner.txt|$SSH_BANNER|g" \
        -e "s|/etc/fail2ban/jail.d|$FAIL2BAN_JAIL_DIR|g" \
        "$SCRIPTS_DIR/harden-ssh.sh" > "$HARDEN_SSH_SCRIPT"
    chmod +x "$HARDEN_SSH_SCRIPT"
}

teardown() {
    teardown_mocks
}

# ── Basic functionality ────────────────────────────────────────────────────────

@test "harden-ssh: creates hardening configuration file" {
    run bash "$HARDEN_SSH_SCRIPT"
    [ "$status" -eq 0 ]
    
    assert_file_exists "$SSHD_HARDENING_CONF"
}

@test "harden-ssh: creates backup of original sshd_config" {
    run bash "$HARDEN_SSH_SCRIPT"
    [ "$status" -eq 0 ]
    
    assert_file_exists "$SSHD_CONFIG_BACKUP"
    assert_file_contains "$SSHD_CONFIG_BACKUP" "Original SSH configuration"
}

@test "harden-ssh: does not overwrite existing backup" {
    # Create existing backup with custom content
    echo "EXISTING BACKUP CONTENT" > "$SSHD_CONFIG_BACKUP"
    
    run bash "$HARDEN_SSH_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Backup should still have original content
    assert_file_contains "$SSHD_CONFIG_BACKUP" "EXISTING BACKUP CONTENT"
    refute_file_contains "$SSHD_CONFIG_BACKUP" "Original SSH configuration"
}

@test "harden-ssh: creates SSH banner file" {
    run bash "$HARDEN_SSH_SCRIPT"
    [ "$status" -eq 0 ]
    
    assert_file_exists "$SSH_BANNER"
    assert_file_contains "$SSH_BANNER" "AUTHORIZED ACCESS ONLY"
}

# ── Authentication settings ────────────────────────────────────────────────────

@test "harden-ssh: disables PasswordAuthentication" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "PasswordAuthentication no"
}

@test "harden-ssh: disables PermitRootLogin" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "PermitRootLogin no"
}

@test "harden-ssh: enables PubkeyAuthentication" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "PubkeyAuthentication yes"
}

@test "harden-ssh: disables PermitEmptyPasswords" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "PermitEmptyPasswords no"
}

@test "harden-ssh: disables ChallengeResponseAuthentication" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "ChallengeResponseAuthentication no"
}

@test "harden-ssh: disables KbdInteractiveAuthentication" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "KbdInteractiveAuthentication no"
}

@test "harden-ssh: enables UsePAM" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "UsePAM yes"
}

# ── Strong cryptography ────────────────────────────────────────────────────────

@test "harden-ssh: configures strong ciphers only" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "Ciphers chacha20-poly1305@openssh.com"
    assert_file_contains "$SSHD_HARDENING_CONF" "aes256-gcm@openssh.com"
    assert_file_contains "$SSHD_HARDENING_CONF" "aes128-gcm@openssh.com"
}

@test "harden-ssh: configures strong MACs only" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "MACs hmac-sha2-512-etm@openssh.com"
    assert_file_contains "$SSHD_HARDENING_CONF" "hmac-sha2-256-etm@openssh.com"
    assert_file_contains "$SSHD_HARDENING_CONF" "hmac-sha2-512"
}

@test "harden-ssh: configures strong key exchange algorithms" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "KexAlgorithms curve25519-sha256"
    assert_file_contains "$SSHD_HARDENING_CONF" "diffie-hellman-group16-sha512"
    assert_file_contains "$SSHD_HARDENING_CONF" "diffie-hellman-group18-sha512"
}

# ── Connection limits and timeouts ─────────────────────────────────────────────

@test "harden-ssh: sets MaxAuthTries to 3" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "MaxAuthTries 3"
}

@test "harden-ssh: sets ClientAliveInterval to 300 seconds" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "ClientAliveInterval 300"
}

@test "harden-ssh: sets ClientAliveCountMax to 2" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "ClientAliveCountMax 2"
}

@test "harden-ssh: sets LoginGraceTime to 30 seconds" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "LoginGraceTime 30"
}

@test "harden-ssh: sets MaxSessions to 5" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "MaxSessions 5"
}

# ── Disable forwarding ─────────────────────────────────────────────────────────

@test "harden-ssh: disables X11Forwarding" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "X11Forwarding no"
}

@test "harden-ssh: disables AllowTcpForwarding" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "AllowTcpForwarding no"
}

@test "harden-ssh: disables AllowAgentForwarding" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "AllowAgentForwarding no"
}

# ── Security features ──────────────────────────────────────────────────────────

@test "harden-ssh: enables StrictModes" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "StrictModes yes"
}

@test "harden-ssh: disables HostbasedAuthentication" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "HostbasedAuthentication no"
}

@test "harden-ssh: disables PermitUserEnvironment" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "PermitUserEnvironment no"
}

@test "harden-ssh: disables Compression" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "Compression no"
}

@test "harden-ssh: sets LogLevel to VERBOSE" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "LogLevel VERBOSE"
}

@test "harden-ssh: sets SyslogFacility to AUTH" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "SyslogFacility AUTH"
}

@test "harden-ssh: configures SSH banner" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SSHD_HARDENING_CONF" "Banner $SSH_BANNER"
}

# ── Configuration validation ───────────────────────────────────────────────────

@test "harden-ssh: tests configuration with sshd -t before applying" {
    SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    SSHD_LOG="$BATS_TEST_TMPDIR/sshd.log"
    
    create_call_log_mock "systemctl" "$SYSTEMCTL_LOG"
    create_call_log_mock "sshd" "$SSHD_LOG"
    
    bash "$HARDEN_SSH_SCRIPT"
    
    # Verify sshd -t was called
    assert_file_contains "$SSHD_LOG" "-t"
}

@test "harden-ssh: reverts changes if sshd -t fails" {
    # Make sshd -t fail
    create_mock_with_body "sshd" 'exit 1'
    
    run bash "$HARDEN_SSH_SCRIPT"
    [ "$status" -eq 1 ]
    
    # Hardening config should be removed
    [[ ! -f "$SSHD_HARDENING_CONF" ]]
}

@test "harden-ssh: preserves backup when reverting failed config" {
    # Create backup first
    echo "BACKUP CONTENT" > "$SSHD_CONFIG_BACKUP"
    
    # Make sshd -t fail
    create_mock_with_body "sshd" 'exit 1'
    
    run bash "$HARDEN_SSH_SCRIPT"
    [ "$status" -eq 1 ]
    
    # Backup should still exist
    assert_file_exists "$SSHD_CONFIG_BACKUP"
    assert_file_contains "$SSHD_CONFIG_BACKUP" "BACKUP CONTENT"
}

# ── Service management ─────────────────────────────────────────────────────────

@test "harden-ssh: reloads sshd service after configuration" {
    SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    create_call_log_mock "systemctl" "$SYSTEMCTL_LOG"
    
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SYSTEMCTL_LOG" "reload sshd"
}

@test "harden-ssh: does not reload sshd if config test fails" {
    SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    create_call_log_mock "systemctl" "$SYSTEMCTL_LOG"
    
    # Make sshd -t fail
    create_mock_with_body "sshd" 'exit 1'
    
    run bash "$HARDEN_SSH_SCRIPT"
    [ "$status" -eq 1 ]
    
    # Should not contain reload command
    if [[ -f "$SYSTEMCTL_LOG" ]]; then
        refute_file_contains "$SYSTEMCTL_LOG" "reload sshd"
    fi
}

# ── fail2ban integration ───────────────────────────────────────────────────────

@test "harden-ssh: configures fail2ban SSH jail when fail2ban is available" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_exists "$FAIL2BAN_SSHD_CONF"
    assert_file_contains "$FAIL2BAN_SSHD_CONF" "[sshd]"
    assert_file_contains "$FAIL2BAN_SSHD_CONF" "enabled = true"
}

@test "harden-ssh: sets fail2ban maxretry to 3" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$FAIL2BAN_SSHD_CONF" "maxretry = 3"
}

@test "harden-ssh: sets fail2ban findtime to 600 seconds" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$FAIL2BAN_SSHD_CONF" "findtime = 600"
}

@test "harden-ssh: sets fail2ban bantime to 3600 seconds" {
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$FAIL2BAN_SSHD_CONF" "bantime = 3600"
}

@test "harden-ssh: restarts fail2ban service after configuration" {
    SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    create_call_log_mock "systemctl" "$SYSTEMCTL_LOG"
    
    bash "$HARDEN_SSH_SCRIPT"
    
    assert_file_contains "$SYSTEMCTL_LOG" "restart fail2ban"
}

@test "harden-ssh: skips fail2ban configuration when not installed" {
    # Remove fail2ban-client mock
    rm -f "$MOCK_BIN/fail2ban-client"
    
    run bash "$HARDEN_SSH_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Should still succeed without fail2ban
    assert_file_exists "$SSHD_HARDENING_CONF"
}

# ── Idempotency ────────────────────────────────────────────────────────────────

@test "harden-ssh: skips configuration if already hardened (without --force)" {
    # Run once to create hardening config
    bash "$HARDEN_SSH_SCRIPT"
    
    # Modify the hardening config to detect if it's recreated
    echo "# MODIFIED" >> "$SSHD_HARDENING_CONF"
    
    # Run again without --force
    run bash "$HARDEN_SSH_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Should still contain our modification (not recreated)
    assert_file_contains "$SSHD_HARDENING_CONF" "# MODIFIED"
    
    # Output should indicate skipping
    [[ "$output" =~ "already hardened" ]] || [[ "$output" =~ "skipping" ]]
}

@test "harden-ssh: reconfigures when --force flag is used" {
    # Run once to create hardening config
    bash "$HARDEN_SSH_SCRIPT"
    
    # Modify the hardening config
    echo "# MODIFIED" >> "$SSHD_HARDENING_CONF"
    
    # Run again with --force
    bash "$HARDEN_SSH_SCRIPT" --force
    
    # Should NOT contain our modification (was recreated)
    refute_file_contains "$SSHD_HARDENING_CONF" "# MODIFIED"
    
    # Should still contain proper hardening settings
    assert_file_contains "$SSHD_HARDENING_CONF" "PasswordAuthentication no"
}

@test "harden-ssh: is fully idempotent with --force (multiple runs produce same result)" {
    # Run three times with --force
    bash "$HARDEN_SSH_SCRIPT" --force
    cp "$SSHD_HARDENING_CONF" "$BATS_TEST_TMPDIR/first.conf"
    
    bash "$HARDEN_SSH_SCRIPT" --force
    cp "$SSHD_HARDENING_CONF" "$BATS_TEST_TMPDIR/second.conf"
    
    bash "$HARDEN_SSH_SCRIPT" --force
    cp "$SSHD_HARDENING_CONF" "$BATS_TEST_TMPDIR/third.conf"
    
    # All three runs should produce identical files
    run diff "$BATS_TEST_TMPDIR/first.conf" "$BATS_TEST_TMPDIR/second.conf"
    [ "$status" -eq 0 ]
    
    run diff "$BATS_TEST_TMPDIR/second.conf" "$BATS_TEST_TMPDIR/third.conf"
    [ "$status" -eq 0 ]
}

# ── Edge cases ─────────────────────────────────────────────────────────────────

@test "harden-ssh: creates sshd_config.d directory if it doesn't exist" {
    # Remove the directory
    rm -rf "$SSHD_CONFIG_DIR"
    
    bash "$HARDEN_SSH_SCRIPT"
    
    # Directory and config should be created
    [[ -d "$SSHD_CONFIG_DIR" ]]
    assert_file_exists "$SSHD_HARDENING_CONF"
}

@test "harden-ssh: handles existing fail2ban jail.d directory" {
    # Create existing fail2ban configuration
    mkdir -p "$FAIL2BAN_JAIL_DIR"
    echo "[DEFAULT]" > "$FAIL2BAN_JAIL_DIR/defaults.conf"
    
    bash "$HARDEN_SSH_SCRIPT"
    
    # Should create SSH jail without affecting existing config
    assert_file_exists "$FAIL2BAN_SSHD_CONF"
    assert_file_exists "$FAIL2BAN_JAIL_DIR/defaults.conf"
}

@test "harden-ssh: script exits cleanly on success" {
    run bash "$HARDEN_SSH_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "harden-ssh: produces informative output messages" {
    run bash "$HARDEN_SSH_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Check for key informational messages
    [[ "$output" =~ "Hardening SSH" ]]
    [[ "$output" =~ "SSH Hardening Complete" ]]
}
