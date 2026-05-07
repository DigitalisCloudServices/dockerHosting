#!/usr/bin/env bats
# Tests for utility scripts: cleanup-packages.sh and recover-docker.sh

load 'helpers/common'

# ══════════════════════════════════════════════════════════════════════════════
# Setup and Teardown
# ══════════════════════════════════════════════════════════════════════════════

setup() {
    setup_mocks

    # Create log files for tracking command calls
    APT_GET_LOG="$BATS_TEST_TMPDIR/apt-get.log"
    SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    JOURNALCTL_LOG="$BATS_TEST_TMPDIR/journalctl.log"
    DPKG_LOG="$BATS_TEST_TMPDIR/dpkg.log"
    
    # Create test home directories for NVM cleanup tests
    TEST_HOME_DIR="$BATS_TEST_TMPDIR/home/testuser"
    mkdir -p "$TEST_HOME_DIR"
    
    # Override /etc/docker path for recover-docker tests
    export DOCKER_CONFIG_DIR="$BATS_TEST_TMPDIR/docker"
    mkdir -p "$DOCKER_CONFIG_DIR"
    
    # Mock sudo to just execute the command (scripts auto-elevate)
    create_mock_with_body "sudo" 'shift; exec "$@"'
    
    # Mock date for consistent backup filenames
    create_mock_with_body "date" 'echo "20260507"'
}

teardown() {
    teardown_mocks
}

# ══════════════════════════════════════════════════════════════════════════════
# cleanup-packages.sh Tests
# ══════════════════════════════════════════════════════════════════════════════

# ── Basic Package Removal ─────────────────────────────────────────────────────

@test "cleanup-packages: requires root privileges" {
    # Mock id/EUID check to fail (not root)
    CLEANUP_SCRIPT="$BATS_TEST_TMPDIR/cleanup-test.sh"
    sed 's/if \[ "$EUID" -ne 0 \]/if true/' "$SCRIPTS_DIR/cleanup-packages.sh" > "$CLEANUP_SCRIPT"
    chmod +x "$CLEANUP_SCRIPT"
    
    run bash "$CLEANUP_SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "must be run as root" ]]
}

@test "cleanup-packages: executes apt-get remove with purge flag" {
    # Create mock dpkg that reports installed packages
    create_mock_with_body "dpkg" 'echo "ii  build-essential"'
    
    # Create apt-get mock that logs calls
    create_call_log_mock "apt-get" "$APT_GET_LOG"
    
    # Patch script to skip root check and user prompt
    CLEANUP_SCRIPT="$BATS_TEST_TMPDIR/cleanup-test.sh"
    sed \
        -e 's/if \[ "$EUID" -ne 0 \]/if false/' \
        -e 's/read -p "Do you want to continue.*/REPLY="y"/' \
        "$SCRIPTS_DIR/cleanup-packages.sh" > "$CLEANUP_SCRIPT"
    chmod +x "$CLEANUP_SCRIPT"
    
    run bash "$CLEANUP_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Verify apt-get remove was called with --purge
    assert_file_exists "$APT_GET_LOG"
    assert_file_contains "$APT_GET_LOG" "remove --purge -y"
}

@test "cleanup-packages: executes apt-get autoremove" {
    create_mock_with_body "dpkg" 'exit 1'  # No packages installed
    create_call_log_mock "apt-get" "$APT_GET_LOG"
    
    CLEANUP_SCRIPT="$BATS_TEST_TMPDIR/cleanup-test.sh"
    sed \
        -e 's/if \[ "$EUID" -ne 0 \]/if false/' \
        -e 's/read -p "Do you want to continue.*/REPLY="y"/' \
        "$SCRIPTS_DIR/cleanup-packages.sh" > "$CLEANUP_SCRIPT"
    chmod +x "$CLEANUP_SCRIPT"
    
    run bash "$CLEANUP_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Verify autoremove was called
    assert_file_exists "$APT_GET_LOG"
    assert_file_contains "$APT_GET_LOG" "autoremove -y"
}

@test "cleanup-packages: executes apt-get autoclean" {
    create_mock_with_body "dpkg" 'exit 1'  # No packages installed
    create_call_log_mock "apt-get" "$APT_GET_LOG"
    
    CLEANUP_SCRIPT="$BATS_TEST_TMPDIR/cleanup-test.sh"
    sed \
        -e 's/if \[ "$EUID" -ne 0 \]/if false/' \
        -e 's/read -p "Do you want to continue.*/REPLY="y"/' \
        "$SCRIPTS_DIR/cleanup-packages.sh" > "$CLEANUP_SCRIPT"
    chmod +x "$CLEANUP_SCRIPT"
    
    run bash "$CLEANUP_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Verify autoclean was called
    assert_file_exists "$APT_GET_LOG"
    assert_file_contains "$APT_GET_LOG" "autoclean -y"
}

@test "cleanup-packages: cleans /var/cache/apt by running autoclean" {
    # autoclean is responsible for cleaning /var/cache/apt
    create_mock_with_body "dpkg" 'exit 1'
    create_call_log_mock "apt-get" "$APT_GET_LOG"
    
    CLEANUP_SCRIPT="$BATS_TEST_TMPDIR/cleanup-test.sh"
    sed \
        -e 's/if \[ "$EUID" -ne 0 \]/if false/' \
        -e 's/read -p "Do you want to continue.*/REPLY="y"/' \
        "$SCRIPTS_DIR/cleanup-packages.sh" > "$CLEANUP_SCRIPT"
    chmod +x "$CLEANUP_SCRIPT"
    
    run bash "$CLEANUP_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Verify autoclean was executed (this cleans /var/cache/apt)
    grep -q "autoclean -y" "$APT_GET_LOG"
}

# ── User Confirmation ──────────────────────────────────────────────────────

@test "cleanup-packages: exits when user declines confirmation" {
    create_mock_with_body "dpkg" 'echo "ii  build-essential"'
    create_call_log_mock "apt-get" "$APT_GET_LOG"
    
    CLEANUP_SCRIPT="$BATS_TEST_TMPDIR/cleanup-test.sh"
    sed 's/if \[ "$EUID" -ne 0 \]/if false/' "$SCRIPTS_DIR/cleanup-packages.sh" > "$CLEANUP_SCRIPT"
    chmod +x "$CLEANUP_SCRIPT"
    
    # Answer 'n' to the confirmation prompt
    run bash "$CLEANUP_SCRIPT" <<< "n"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Cleanup cancelled" ]]
    
    # Verify no apt-get commands were executed
    [ ! -f "$APT_GET_LOG" ]
}

# ── NVM Cleanup ────────────────────────────────────────────────────────────

@test "cleanup-packages: removes NVM directory from user home" {
    create_mock_with_body "dpkg" 'exit 1'
    create_mock "apt-get"
    
    # Create NVM directory
    NVM_DIR="$TEST_HOME_DIR/.nvm"
    mkdir -p "$NVM_DIR"
    touch "$NVM_DIR/nvm.sh"
    
    CLEANUP_SCRIPT="$BATS_TEST_TMPDIR/cleanup-test.sh"
    sed \
        -e 's/if \[ "$EUID" -ne 0 \]/if false/' \
        -e 's/read -p "Do you want to continue.*/REPLY="y"/' \
        -e "s|/home/\*|$BATS_TEST_TMPDIR/home/*|g" \
        "$SCRIPTS_DIR/cleanup-packages.sh" > "$CLEANUP_SCRIPT"
    chmod +x "$CLEANUP_SCRIPT"
    
    run bash "$CLEANUP_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Verify NVM directory was removed
    [ ! -d "$NVM_DIR" ]
}

@test "cleanup-packages: removes NVM references from shell rc files" {
    create_mock_with_body "dpkg" 'exit 1'
    create_mock "apt-get"
    
    # Create NVM directory and bashrc with NVM references
    NVM_DIR="$TEST_HOME_DIR/.nvm"
    mkdir -p "$NVM_DIR"
    
    cat > "$TEST_HOME_DIR/.bashrc" << 'EOF'
export PATH=$PATH:/usr/local/bin
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
alias ll='ls -la'
EOF
    
    CLEANUP_SCRIPT="$BATS_TEST_TMPDIR/cleanup-test.sh"
    sed \
        -e 's/if \[ "$EUID" -ne 0 \]/if false/' \
        -e 's/read -p "Do you want to continue.*/REPLY="y"/' \
        -e "s|/home/\*|$BATS_TEST_TMPDIR/home/*|g" \
        "$SCRIPTS_DIR/cleanup-packages.sh" > "$CLEANUP_SCRIPT"
    chmod +x "$CLEANUP_SCRIPT"
    
    run bash "$CLEANUP_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Verify NVM lines were removed
    refute_file_contains "$TEST_HOME_DIR/.bashrc" "NVM_DIR"
    refute_file_contains "$TEST_HOME_DIR/.bashrc" "nvm.sh"
    refute_file_contains "$TEST_HOME_DIR/.bashrc" "bash_completion"
    
    # Verify other lines remain
    assert_file_contains "$TEST_HOME_DIR/.bashrc" "export PATH"
    assert_file_contains "$TEST_HOME_DIR/.bashrc" "alias ll"
}

@test "cleanup-packages: creates backup of rc files before modification" {
    create_mock_with_body "dpkg" 'exit 1'
    create_mock "apt-get"
    
    NVM_DIR="$TEST_HOME_DIR/.nvm"
    mkdir -p "$NVM_DIR"
    
    echo 'export NVM_DIR="$HOME/.nvm"' > "$TEST_HOME_DIR/.bashrc"
    
    CLEANUP_SCRIPT="$BATS_TEST_TMPDIR/cleanup-test.sh"
    sed \
        -e 's/if \[ "$EUID" -ne 0 \]/if false/' \
        -e 's/read -p "Do you want to continue.*/REPLY="y"/' \
        -e "s|/home/\*|$BATS_TEST_TMPDIR/home/*|g" \
        "$SCRIPTS_DIR/cleanup-packages.sh" > "$CLEANUP_SCRIPT"
    chmod +x "$CLEANUP_SCRIPT"
    
    run bash "$CLEANUP_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Verify backup was created
    [ -f "$TEST_HOME_DIR/.bashrc.backup.20260507" ]
}

@test "cleanup-packages: handles missing NVM installation gracefully" {
    create_mock_with_body "dpkg" 'exit 1'
    create_mock "apt-get"
    
    CLEANUP_SCRIPT="$BATS_TEST_TMPDIR/cleanup-test.sh"
    sed \
        -e 's/if \[ "$EUID" -ne 0 \]/if false/' \
        -e 's/read -p "Do you want to continue.*/REPLY="y"/' \
        -e "s|/home/\*|$BATS_TEST_TMPDIR/home/*|g" \
        "$SCRIPTS_DIR/cleanup-packages.sh" > "$CLEANUP_SCRIPT"
    chmod +x "$CLEANUP_SCRIPT"
    
    run bash "$CLEANUP_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "No NVM installations found" ]]
}

@test "cleanup-packages: skips already clean system" {
    create_mock_with_body "dpkg" 'exit 1'  # No packages installed
    create_mock "apt-get"
    
    CLEANUP_SCRIPT="$BATS_TEST_TMPDIR/cleanup-test.sh"
    sed \
        -e 's/if \[ "$EUID" -ne 0 \]/if false/' \
        -e 's/read -p "Do you want to continue.*/REPLY="y"/' \
        "$SCRIPTS_DIR/cleanup-packages.sh" > "$CLEANUP_SCRIPT"
    chmod +x "$CLEANUP_SCRIPT"
    
    run bash "$CLEANUP_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "No packages to remove" ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# recover-docker.sh Tests
# ══════════════════════════════════════════════════════════════════════════════

# ── Docker Restart ─────────────────────────────────────────────────────────

@test "recover-docker: executes systemctl restart docker" {
    create_call_log_mock "systemctl" "$SYSTEMCTL_LOG"
    create_mock "docker"
    
    RECOVER_SCRIPT="$BATS_TEST_TMPDIR/recover-test.sh"
    sed \
        -e "s|/etc/docker|$DOCKER_CONFIG_DIR|g" \
        -e 's/if \[ "$EUID" -ne 0 \]/if false/' \
        "$SCRIPTS_DIR/recover-docker.sh" > "$RECOVER_SCRIPT"
    chmod +x "$RECOVER_SCRIPT"
    
    run bash "$RECOVER_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Verify restart command was called
    assert_file_exists "$SYSTEMCTL_LOG"
    assert_file_contains "$SYSTEMCTL_LOG" "restart docker"
}

@test "recover-docker: checks docker status with systemctl" {
    create_call_log_mock "systemctl" "$SYSTEMCTL_LOG"
    create_mock "docker"
    
    RECOVER_SCRIPT="$BATS_TEST_TMPDIR/recover-test.sh"
    sed \
        -e "s|/etc/docker|$DOCKER_CONFIG_DIR|g" \
        -e 's/if \[ "$EUID" -ne 0 \]/if false/' \
        "$SCRIPTS_DIR/recover-docker.sh" > "$RECOVER_SCRIPT"
    chmod +x "$RECOVER_SCRIPT"
    
    run bash "$RECOVER_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Verify status check was performed
    assert_file_contains "$SYSTEMCTL_LOG" "is-active"
}

@test "recover-docker: displays success message when docker recovers" {
    # Mock systemctl is-active to return success
    create_mock_with_body "systemctl" 'if [[ "$1" == "is-active" ]]; then exit 0; fi'
    create_mock "docker"
    
    RECOVER_SCRIPT="$BATS_TEST_TMPDIR/recover-test.sh"
    sed \
        -e "s|/etc/docker|$DOCKER_CONFIG_DIR|g" \
        -e 's/if \[ "$EUID" -ne 0 \]/if false/' \
        "$SCRIPTS_DIR/recover-docker.sh" > "$RECOVER_SCRIPT"
    chmod +x "$RECOVER_SCRIPT"
    
    run bash "$RECOVER_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Docker recovered successfully" ]]
}

# ── Error Handling ─────────────────────────────────────────────────────────

@test "recover-docker: handles failed docker restart gracefully" {
    # Mock systemctl is-active to return failure (docker not running)
    create_mock_with_body "systemctl" 'if [[ "$1" == "is-active" ]]; then exit 1; fi'
    create_mock "journalctl"
    
    RECOVER_SCRIPT="$BATS_TEST_TMPDIR/recover-test.sh"
    sed \
        -e "s|/etc/docker|$DOCKER_CONFIG_DIR|g" \
        -e 's/if \[ "$EUID" -ne 0 \]/if false/' \
        "$SCRIPTS_DIR/recover-docker.sh" > "$RECOVER_SCRIPT"
    chmod +x "$RECOVER_SCRIPT"
    
    run bash "$RECOVER_SCRIPT"
    [ "$status" -eq 0 ]  # Script doesn't fail, just reports error
    [[ "$output" =~ "Docker still failing" ]]
}

@test "recover-docker: displays journalctl command on failure" {
    create_mock_with_body "systemctl" 'if [[ "$1" == "is-active" ]]; then exit 1; fi'
    
    RECOVER_SCRIPT="$BATS_TEST_TMPDIR/recover-test.sh"
    sed \
        -e "s|/etc/docker|$DOCKER_CONFIG_DIR|g" \
        -e 's/if \[ "$EUID" -ne 0 \]/if false/' \
        "$SCRIPTS_DIR/recover-docker.sh" > "$RECOVER_SCRIPT"
    chmod +x "$RECOVER_SCRIPT"
    
    run bash "$RECOVER_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "journalctl -xeu docker.service" ]]
}

@test "recover-docker: suggests checking logs with journalctl" {
    create_mock_with_body "systemctl" 'if [[ "$1" == "is-active" ]]; then exit 1; fi'
    
    RECOVER_SCRIPT="$BATS_TEST_TMPDIR/recover-test.sh"
    sed \
        -e "s|/etc/docker|$DOCKER_CONFIG_DIR|g" \
        -e 's/if \[ "$EUID" -ne 0 \]/if false/' \
        "$SCRIPTS_DIR/recover-docker.sh" > "$RECOVER_SCRIPT"
    chmod +x "$RECOVER_SCRIPT"
    
    run bash "$RECOVER_SCRIPT"
    [[ "$output" =~ "Check logs:" ]]
    [[ "$output" =~ "journalctl" ]]
}

# ── Backup Restoration ─────────────────────────────────────────────────────

@test "recover-docker: restores from most recent backup when available" {
    # Create backup files
    touch "$DOCKER_CONFIG_DIR/daemon.json.backup.2026-05-01"
    echo '{"test": "old"}' > "$DOCKER_CONFIG_DIR/daemon.json.backup.2026-05-01"
    
    touch "$DOCKER_CONFIG_DIR/daemon.json.backup.2026-05-07"
    echo '{"test": "recent"}' > "$DOCKER_CONFIG_DIR/daemon.json.backup.2026-05-07"
    
    create_mock "systemctl"
    create_mock "docker"
    
    RECOVER_SCRIPT="$BATS_TEST_TMPDIR/recover-test.sh"
    sed \
        -e "s|/etc/docker|$DOCKER_CONFIG_DIR|g" \
        -e 's/if \[ "$EUID" -ne 0 \]/if false/' \
        "$SCRIPTS_DIR/recover-docker.sh" > "$RECOVER_SCRIPT"
    chmod +x "$RECOVER_SCRIPT"
    
    run bash "$RECOVER_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Verify most recent backup was used
    assert_file_contains "$DOCKER_CONFIG_DIR/daemon.json" '"test": "recent"'
    [[ "$output" =~ "Restoring from backup" ]]
}

@test "recover-docker: creates minimal config when no backup exists" {
    create_mock "systemctl"
    create_mock "docker"
    
    RECOVER_SCRIPT="$BATS_TEST_TMPDIR/recover-test.sh"
    sed \
        -e "s|/etc/docker|$DOCKER_CONFIG_DIR|g" \
        -e 's/if \[ "$EUID" -ne 0 \]/if false/' \
        "$SCRIPTS_DIR/recover-docker.sh" > "$RECOVER_SCRIPT"
    chmod +x "$RECOVER_SCRIPT"
    
    run bash "$RECOVER_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Verify minimal config was created
    assert_file_exists "$DOCKER_CONFIG_DIR/daemon.json"
    assert_file_contains "$DOCKER_CONFIG_DIR/daemon.json" '"log-driver": "json-file"'
    assert_file_contains "$DOCKER_CONFIG_DIR/daemon.json" '"live-restore": true'
    [[ "$output" =~ "creating minimal working configuration" ]]
}

@test "recover-docker: minimal config includes storage-driver overlay2" {
    create_mock "systemctl"
    create_mock "docker"
    
    RECOVER_SCRIPT="$BATS_TEST_TMPDIR/recover-test.sh"
    sed \
        -e "s|/etc/docker|$DOCKER_CONFIG_DIR|g" \
        -e 's/if \[ "$EUID" -ne 0 \]/if false/' \
        "$SCRIPTS_DIR/recover-docker.sh" > "$RECOVER_SCRIPT"
    chmod +x "$RECOVER_SCRIPT"
    
    run bash "$RECOVER_SCRIPT"
    [ "$status" -eq 0 ]
    
    assert_file_contains "$DOCKER_CONFIG_DIR/daemon.json" '"storage-driver": "overlay2"'
}

@test "recover-docker: minimal config includes systemd cgroup driver" {
    create_mock "systemctl"
    create_mock "docker"
    
    RECOVER_SCRIPT="$BATS_TEST_TMPDIR/recover-test.sh"
    sed \
        -e "s|/etc/docker|$DOCKER_CONFIG_DIR|g" \
        -e 's/if \[ "$EUID" -ne 0 \]/if false/' \
        "$SCRIPTS_DIR/recover-docker.sh" > "$RECOVER_SCRIPT"
    chmod +x "$RECOVER_SCRIPT"
    
    run bash "$RECOVER_SCRIPT"
    [ "$status" -eq 0 ]
    
    assert_file_contains "$DOCKER_CONFIG_DIR/daemon.json" '"exec-opts"'
    assert_file_contains "$DOCKER_CONFIG_DIR/daemon.json" 'native.cgroupdriver=systemd'
}

# ── Root Privilege Handling ────────────────────────────────────────────────

@test "recover-docker: auto-elevates to root when not running as root" {
    # The script has auto-elevation logic that calls sudo
    # Our sudo mock just executes the script, so we verify it works
    create_mock "systemctl"
    create_mock "docker"
    
    # Don't patch the EUID check - let it detect non-root
    RECOVER_SCRIPT="$BATS_TEST_TMPDIR/recover-test.sh"
    sed "s|/etc/docker|$DOCKER_CONFIG_DIR|g" "$SCRIPTS_DIR/recover-docker.sh" > "$RECOVER_SCRIPT"
    chmod +x "$RECOVER_SCRIPT"
    
    # Set EUID to non-root value
    run env EUID=1000 bash "$RECOVER_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "requires root privileges" ]]
}
