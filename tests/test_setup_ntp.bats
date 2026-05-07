#!/usr/bin/env bats
# Comprehensive tests for scripts/setup-ntp.sh
# Tests chrony installation, configuration generation, security settings, and idempotency.

load 'helpers/common'

SCRIPT="$REPO_ROOT/scripts/setup-ntp.sh"

setup() {
    setup_mocks

    # Set up test environment paths
    export CHRONY_CONF="$BATS_TEST_TMPDIR/chrony.conf"
    export CHRONY_BACKUP="$BATS_TEST_TMPDIR/chrony.conf.backup"
    DRIFT_DIR="$BATS_TEST_TMPDIR/var/lib/chrony"
    LOG_DIR="$BATS_TEST_TMPDIR/var/log/chrony"
    mkdir -p "$DRIFT_DIR" "$LOG_DIR"

    # Mock system commands
    create_mock "apt-get"
    create_mock "systemctl"
    create_mock "chronyc"
    create_mock "sleep"

    # Mock command to indicate chrony not installed by default
    create_mock_with_body "command" 'exit 1'

    # Track command invocations
    APT_LOG="$BATS_TEST_TMPDIR/apt.log"
    SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    CHRONYC_LOG="$BATS_TEST_TMPDIR/chronyc.log"

    # Modify script to use test paths
    export SCRIPT_WRAPPER="$BATS_TEST_TMPDIR/setup-ntp-wrapper.sh"
    cat > "$SCRIPT_WRAPPER" <<'EOF'
#!/bin/bash
# Wrapper to override paths for testing
source "${BASH_SOURCE%/*}/../scripts/setup-ntp.sh" \
    | sed "s|/etc/chrony/chrony.conf|$CHRONY_CONF|g"
EOF
    chmod +x "$SCRIPT_WRAPPER"
}

teardown() {
    teardown_mocks
    rm -f "$CHRONY_CONF" "$CHRONY_BACKUP"
}

# ── Idempotency: chrony already running ──────────────────────────────────────

@test "setup-ntp: skips configuration when chrony is already active" {
    # Mock chrony already installed and running
    create_mock_with_body "command" 'exit 0'
    create_mock_with_body "systemctl" '[[ "$*" == *"is-active"* ]] && exit 0 || exit 1'
    create_mock_with_body "chronyc" 'echo "Reference ID"; echo "Stratum"; exit 0'
    create_call_log_mock "apt-get" "$APT_LOG"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already running"* ]]
    [[ "$output" == *"skipping"* ]]

    # apt-get should not be called
    [ ! -s "$APT_LOG" ]
}

@test "setup-ntp: forces reconfiguration with --force flag" {
    # chrony running but --force should reconfigure
    create_mock_with_body "command" 'exit 0'
    create_mock_with_body "systemctl" '[[ "$*" == *"is-active"* ]] && exit 0; echo "$*" >> '"$SYSTEMCTL_LOG"'; exit 0'

    # Create existing config
    echo "# old config" > "$CHRONY_CONF"

    run bash "$SCRIPT" --force
    [ "$status" -eq 0 ]

    # systemctl restart should be called
    [ -f "$SYSTEMCTL_LOG" ]
    grep -q "restart chrony" "$SYSTEMCTL_LOG"
}

# ── systemd-timesyncd conflict handling ──────────────────────────────────────

@test "setup-ntp: stops systemd-timesyncd before installing chrony" {
    create_call_log_mock "systemctl" "$SYSTEMCTL_LOG"

    # Mock systemd-timesyncd as active
    create_mock_with_body "systemctl" '
        if [[ "$*" == *"is-active"* ]] && [[ "$*" == *"systemd-timesyncd"* ]]; then
            exit 0
        fi
        echo "$*" >> '"$SYSTEMCTL_LOG"'
        exit 0
    '

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    # Verify systemd-timesyncd was stopped and disabled
    grep -q "stop systemd-timesyncd" "$SYSTEMCTL_LOG"
    grep -q "disable systemd-timesyncd" "$SYSTEMCTL_LOG"
}

@test "setup-ntp: mentions systemd-timesyncd replacement in output" {
    create_mock_with_body "systemctl" '
        [[ "$*" == *"is-active"* ]] && [[ "$*" == *"systemd-timesyncd"* ]] && exit 0
        exit 0
    '

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Stopping systemd-timesyncd"* ]]
    [[ "$output" == *"replaced by chrony"* ]]
}

# ── chrony installation ───────────────────────────────────────────────────────

@test "setup-ntp: installs chrony when not present" {
    create_call_log_mock "apt-get" "$APT_LOG"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    assert_file_exists "$APT_LOG"
    assert_file_contains "$APT_LOG" "install"
    assert_file_contains "$APT_LOG" "chrony"
}

@test "setup-ntp: installs chrony with -y flag for non-interactive mode" {
    create_call_log_mock "apt-get" "$APT_LOG"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    assert_file_contains "$APT_LOG" "-y"
}

@test "setup-ntp: confirms installation in output" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Installing chrony"* ]]
}

# ── Configuration backup ──────────────────────────────────────────────────────

@test "setup-ntp: backs up existing chrony.conf before modification" {
    # Create a fake existing config
    echo "# original config" > "$CHRONY_CONF"

    # Mock cp command to actually copy for this test
    create_mock_with_body "cp" '
        if [[ "$1" == "'"$CHRONY_CONF"'" ]] && [[ "$2" == "'"$CHRONY_BACKUP"'" ]]; then
            cat "$1" > "$2"
        fi
        exit 0
    '

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    assert_file_exists "$CHRONY_BACKUP"
    [[ "$output" == *"Backed up original chrony.conf"* ]]
}

@test "setup-ntp: does not overwrite existing backup" {
    # Create both files
    echo "# original" > "$CHRONY_CONF"
    echo "# backup" > "$CHRONY_BACKUP"

    local backup_content
    backup_content=$(cat "$CHRONY_BACKUP")

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    # Backup should remain unchanged
    [ "$(cat "$CHRONY_BACKUP")" == "$backup_content" ]
}

# ── chrony.conf generation: pool sources ──────────────────────────────────────

@test "setup-ntp: generates chrony.conf with at least 2 pool sources" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    assert_file_exists "$CHRONY_CONF"

    # Count pool directives
    local pool_count
    pool_count=$(grep -c "^pool" "$CHRONY_CONF")
    [ "$pool_count" -ge 2 ]
}

@test "setup-ntp: uses debian.pool.ntp.org sources" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    assert_file_exists "$CHRONY_CONF"
    assert_file_contains "$CHRONY_CONF" "0.debian.pool.ntp.org"
    assert_file_contains "$CHRONY_CONF" "1.debian.pool.ntp.org"
    assert_file_contains "$CHRONY_CONF" "2.debian.pool.ntp.org"
    assert_file_contains "$CHRONY_CONF" "3.debian.pool.ntp.org"
}

@test "setup-ntp: pool directives include iburst option" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    # All pool lines should have iburst
    local pool_lines iburst_lines
    pool_lines=$(grep -c "^pool" "$CHRONY_CONF")
    iburst_lines=$(grep "^pool" "$CHRONY_CONF" | grep -c "iburst")
    [ "$pool_lines" -eq "$iburst_lines" ]
}

@test "setup-ntp: pool directives include maxsources parameter" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    # Check for maxsources in pool directives
    grep "^pool" "$CHRONY_CONF" | grep -q "maxsources"
}

@test "setup-ntp: pool directives limit maxsources to 3 or 4" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    # Extract maxsources values and verify they're reasonable (3 or 4)
    local maxsources_values
    maxsources_values=$(grep "^pool" "$CHRONY_CONF" | grep -oP 'maxsources \K\d+' | sort -u)

    for val in $maxsources_values; do
        [ "$val" -ge 3 ] && [ "$val" -le 4 ]
    done
}

@test "setup-ntp: pool directives include minpoll and maxpoll" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    # All pool lines should have both minpoll and maxpoll
    local pool_count minpoll_count maxpoll_count
    pool_count=$(grep -c "^pool" "$CHRONY_CONF")
    minpoll_count=$(grep "^pool" "$CHRONY_CONF" | grep -c "minpoll")
    maxpoll_count=$(grep "^pool" "$CHRONY_CONF" | grep -c "maxpoll")

    [ "$pool_count" -eq "$minpoll_count" ]
    [ "$pool_count" -eq "$maxpoll_count" ]
}

# ── chrony.conf generation: security settings ─────────────────────────────────

@test "setup-ntp: configures driftfile for rate tracking" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    assert_file_contains "$CHRONY_CONF" "driftfile"
    assert_file_contains "$CHRONY_CONF" "/var/lib/chrony/drift"
}

@test "setup-ntp: configures makestep for initial time correction" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    assert_file_contains "$CHRONY_CONF" "makestep"

    # Verify makestep parameters (threshold and limit)
    grep -q "makestep 1.0 3" "$CHRONY_CONF"
}

@test "setup-ntp: enables rtcsync for hardware clock synchronisation" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    assert_file_contains "$CHRONY_CONF" "rtcsync"
}

@test "setup-ntp: configures log directory" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    assert_file_contains "$CHRONY_CONF" "logdir"
    assert_file_contains "$CHRONY_CONF" "/var/log/chrony"
}

@test "setup-ntp: enables measurements, statistics, and tracking logs" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    assert_file_contains "$CHRONY_CONF" "log measurements statistics tracking"
}

@test "setup-ntp: denies all external NTP access" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    assert_file_contains "$CHRONY_CONF" "deny all"
}

@test "setup-ntp: allows localhost access only" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    assert_file_contains "$CHRONY_CONF" "allow 127.0.0.1"
    assert_file_contains "$CHRONY_CONF" "allow ::1"
}

@test "setup-ntp: requires minimum of 2 agreeing sources" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    assert_file_contains "$CHRONY_CONF" "minsources 2"
}

@test "setup-ntp: includes security comment headers" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    assert_file_contains "$CHRONY_CONF" "dockerHosting security hardening"
    assert_file_contains "$CHRONY_CONF" "ISO 27001"
    assert_file_contains "$CHRONY_CONF" "CIS Benchmark"
}

# ── Service management ────────────────────────────────────────────────────────

@test "setup-ntp: enables chrony service" {
    create_call_log_mock "systemctl" "$SYSTEMCTL_LOG"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    assert_file_exists "$SYSTEMCTL_LOG"
    assert_file_contains "$SYSTEMCTL_LOG" "enable chrony"
}

@test "setup-ntp: restarts chrony service after configuration" {
    create_call_log_mock "systemctl" "$SYSTEMCTL_LOG"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    assert_file_contains "$SYSTEMCTL_LOG" "restart chrony"
}

@test "setup-ntp: uses canonical unit name (chrony not chronyd)" {
    create_call_log_mock "systemctl" "$SYSTEMCTL_LOG"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    # Should use "chrony" not "chronyd"
    assert_file_contains "$SYSTEMCTL_LOG" "enable chrony"
    assert_file_contains "$SYSTEMCTL_LOG" "restart chrony"
    refute_file_contains "$SYSTEMCTL_LOG" "chronyd"
}

@test "setup-ntp: verifies chrony service is active after restart" {
    create_mock_with_body "systemctl" '
        if [[ "$*" == *"is-active"* ]]; then
            exit 0
        fi
        echo "$*" >> '"$SYSTEMCTL_LOG"'
        exit 0
    '

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"chrony is running"* ]]
}

@test "setup-ntp: exits with error if chrony fails to start" {
    create_mock_with_body "systemctl" '
        if [[ "$*" == *"is-active"* ]]; then
            exit 1
        fi
        exit 0
    '
    create_mock_with_body "journalctl" 'echo "mock journal output"; exit 0'

    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"chrony failed to start"* ]]
}

# ── Time synchronisation verification ────────────────────────────────────────

@test "setup-ntp: waits briefly for initial sync after service start" {
    SLEEP_LOG="$BATS_TEST_TMPDIR/sleep.log"
    create_call_log_mock "sleep" "$SLEEP_LOG"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    # Verify sleep was called (typically sleep 2)
    assert_file_exists "$SLEEP_LOG"
    assert_file_contains "$SLEEP_LOG" "2"
}

@test "setup-ntp: queries chronyc tracking after service start" {
    create_call_log_mock "chronyc" "$CHRONYC_LOG"
    create_mock_with_body "systemctl" '[[ "$*" == *"is-active"* ]] && exit 0; exit 0'

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    assert_file_exists "$CHRONYC_LOG"
    assert_file_contains "$CHRONYC_LOG" "tracking"
}

@test "setup-ntp: displays chrony tracking output in success message" {
    create_mock_with_body "systemctl" '[[ "$*" == *"is-active"* ]] && exit 0; exit 0'
    create_mock_with_body "chronyc" '
        echo "Reference ID    : 192.168.1.1 (ntp.example.com)"
        echo "Stratum         : 3"
        echo "Ref time (UTC)  : Thu May 07 12:00:00 2026"
        exit 0
    '

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"chrony is running"* ]]
    [[ "$output" == *"Reference ID"* ]]
}

# ── Output and documentation ──────────────────────────────────────────────────

@test "setup-ntp: confirms configuration write" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Wrote /etc/chrony/chrony.conf"* ]] || [[ "$output" == *"chrony.conf"* ]]
}

@test "setup-ntp: displays completion banner" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NTP Hardening Complete"* ]]
}

@test "setup-ntp: provides configuration summary" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Configuration summary"* ]]
    [[ "$output" == *"NTP daemon"* ]]
    [[ "$output" == *"chrony"* ]]
}

@test "setup-ntp: mentions Debian pool sources in summary" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Debian pool"* ]]
}

@test "setup-ntp: documents localhost-only access control" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"localhost only"* ]]
    [[ "$output" == *"no server role"* ]]
}

@test "setup-ntp: documents minimum sources requirement" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 agreeing sources"* ]] || [[ "$output" == *"Minimum sources"* ]]
}

@test "setup-ntp: provides useful commands in output" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Useful commands"* ]]
    [[ "$output" == *"chronyc tracking"* ]]
    [[ "$output" == *"chronyc sources"* ]]
}

# ── Configuration file integrity ──────────────────────────────────────────────

@test "setup-ntp: generated config is valid bash heredoc output" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    assert_file_exists "$CHRONY_CONF"

    # File should not contain EOF marker or shell syntax
    refute_file_contains "$CHRONY_CONF" "EOF"
    refute_file_contains "$CHRONY_CONF" "cat >"
}

@test "setup-ntp: config contains no shell variables or expansions" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    # Should not contain unexpanded variables
    refute_file_contains "$CHRONY_CONF" '$'
    refute_file_contains "$CHRONY_CONF" '`'
}

@test "setup-ntp: all pool directives are properly formatted" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    # Extract pool lines and verify they match expected format
    local pool_lines
    pool_lines=$(grep "^pool" "$CHRONY_CONF")

    while IFS= read -r line; do
        # Each pool line should have: pool <hostname> <options>
        [[ "$line" =~ ^pool\ +[a-z0-9.-]+\ +iburst ]]
    done <<< "$pool_lines"
}
