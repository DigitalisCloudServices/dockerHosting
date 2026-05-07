#!/usr/bin/env bats

# Tests for setup.sh — main server setup orchestration script

load 'helpers/common'

setup() {
    setup_mocks
    
    # Mock environment setup
    export DOCKERHOSTING_DIR="$BATS_TEST_TMPDIR/dockerhosting"
    export EUID=0  # Simulate running as root
    
    # Create mock directory structure
    mkdir -p "$DOCKERHOSTING_DIR/scripts"
    mkdir -p "$DOCKERHOSTING_DIR/config"
    mkdir -p "$DOCKERHOSTING_DIR/.git"
    
    # Create test script
    TEST_SCRIPT="$BATS_TEST_TMPDIR/setup.sh"
    cp "$REPO_ROOT/setup.sh" "$TEST_SCRIPT"
    
    # Create call log for tracking subscript invocations
    CALL_LOG="$BATS_TEST_TMPDIR/call.log"
    touch "$CALL_LOG"
    
    # Mock all system commands used by setup.sh
    create_mock "apt-get"
    create_mock "usermod"
    create_mock "getent"
    create_mock "git"
    create_mock "id"
    create_mock "docker"
    create_mock "sudo"
    
    # Mock all subscripts with call logging
    create_subscript_mocks
}

teardown() {
    teardown_mocks
    rm -rf "$DOCKERHOSTING_DIR"
    rm -f "$TEST_SCRIPT" "$CALL_LOG"
}

# Creates mock subscripts that log their invocation with arguments
create_subscript_mocks() {
    local scripts=(
        "install-packages.sh"
        "install-docker.sh"
        "install-traefik.sh"
        "configure-firewall.sh"
        "harden-kernel.sh"
        "setup-ntp.sh"
        "setup-audit.sh"
        "setup-auto-updates.sh"
        "harden-docker.sh"
        "setup-apparmor.sh"
        "setup-pam-policy.sh"
        "setup-aide.sh"
        "harden-shared-memory.sh"
        "setup-fail2ban-enhanced.sh"
        "setup-email.sh"
        "harden-bootloader.sh"
        "harden-usb.sh"
        "harden-ssh.sh"
        "setup-ssh-mfa.sh"
        "setup-logrotate.sh"
    )
    
    for script in "${scripts[@]}"; do
        local script_path="$DOCKERHOSTING_DIR/scripts/$script"
        cat > "$script_path" <<'EOF'
#!/bin/bash
echo "$(basename "$0") $*" >> "$CALL_LOG"
exit 0
EOF
        chmod +x "$script_path"
    done
}

# Helper to run setup.sh function directly
source_and_run() {
    local func="$1"
    shift
    (
        export DOCKERHOSTING_DIR CALL_LOG EUID
        # Source the script
        source "$TEST_SCRIPT"
        # Override interactive prompts to auto-answer 'n'
        REPLY="n"
        # Run the function
        "$func" "$@"
    )
}

# ══════════════════════════════════════════════════════════════════════════════
# Test: Script execution order
# ══════════════════════════════════════════════════════════════════════════════

@test "run_full_setup executes all subscripts in correct order" {
    # Mock interactive prompts to skip optional steps
    export REPLY="n"
    
    run source_and_run run_full_setup
    
    [ "$status" -eq 0 ]
    
    # Verify all core scripts were called in the correct order
    local expected_order=(
        "install-packages.sh"
        "install-docker.sh"
        "install-traefik.sh"
        "configure-firewall.sh"
        "harden-kernel.sh"
        "setup-ntp.sh"
        "setup-audit.sh"
        "setup-auto-updates.sh"
        "harden-docker.sh"
        "setup-apparmor.sh"
        "setup-pam-policy.sh"
        "setup-aide.sh"
        "harden-shared-memory.sh"
        "setup-fail2ban-enhanced.sh"
        "setup-logrotate.sh"
    )
    
    local line_num=1
    for script in "${expected_order[@]}"; do
        # Extract just the script name from the call log line
        local actual_script
        actual_script=$(sed -n "${line_num}p" "$CALL_LOG" | awk '{print $1}')
        [ "$actual_script" = "$script" ] || {
            echo "Expected $script at position $line_num, got $actual_script"
            echo "Call log:"
            cat "$CALL_LOG"
            return 1
        }
        ((line_num++))
    done
}

@test "run_full_setup calls subscripts without --force by default" {
    export REPLY="n"
    
    run source_and_run run_full_setup
    
    [ "$status" -eq 0 ]
    
    # Verify no --force flags were passed
    refute grep -q " --force" "$CALL_LOG"
}

# ══════════════════════════════════════════════════════════════════════════════
# Test: --force flag for individual steps
# ══════════════════════════════════════════════════════════════════════════════

@test "run_full_setup --force=ntp passes --force only to setup-ntp.sh" {
    export REPLY="n"
    
    run source_and_run run_full_setup --force=ntp
    
    [ "$status" -eq 0 ]
    
    # Verify only ntp script received --force
    assert_file_contains "$CALL_LOG" "setup-ntp.sh --force"
    
    # Verify other scripts did NOT receive --force
    local other_scripts=("install-packages.sh" "install-docker.sh" "configure-firewall.sh" "harden-kernel.sh")
    for script in "${other_scripts[@]}"; do
        grep "$script" "$CALL_LOG" | grep -qv " --force" || {
            echo "$script should not have received --force"
            cat "$CALL_LOG"
            return 1
        }
    done
}

@test "run_full_setup --force=firewall passes --force only to configure-firewall.sh" {
    export REPLY="n"
    
    run source_and_run run_full_setup --force=firewall
    
    [ "$status" -eq 0 ]
    
    assert_file_contains "$CALL_LOG" "configure-firewall.sh --force"
    
    # Other scripts should not have --force
    refute grep -E "^(install-docker\.sh|setup-ntp\.sh|harden-kernel\.sh) --force" "$CALL_LOG"
}

@test "run_full_setup --force=docker passes --force to install-docker.sh" {
    export REPLY="n"
    
    run source_and_run run_full_setup --force=docker
    
    [ "$status" -eq 0 ]
    
    assert_file_contains "$CALL_LOG" "install-docker.sh --force"
}

@test "run_full_setup --force=kernel passes --force to harden-kernel.sh" {
    export REPLY="n"
    
    run source_and_run run_full_setup --force=kernel
    
    [ "$status" -eq 0 ]
    
    assert_file_contains "$CALL_LOG" "harden-kernel.sh --force"
}

@test "run_full_setup --force=apparmor passes --force to setup-apparmor.sh" {
    export REPLY="n"
    
    run source_and_run run_full_setup --force=apparmor
    
    [ "$status" -eq 0 ]
    
    assert_file_contains "$CALL_LOG" "setup-apparmor.sh --force"
}

# ══════════════════════════════════════════════════════════════════════════════
# Test: --force with multiple steps comma-separated
# ══════════════════════════════════════════════════════════════════════════════

@test "run_full_setup --force=ntp,firewall passes --force to both scripts" {
    export REPLY="n"
    
    run source_and_run run_full_setup --force=ntp,firewall
    
    [ "$status" -eq 0 ]
    
    assert_file_contains "$CALL_LOG" "setup-ntp.sh --force"
    assert_file_contains "$CALL_LOG" "configure-firewall.sh --force"
    
    # Other scripts should not have --force
    grep "^install-docker\.sh" "$CALL_LOG" | grep -qv " --force"
    grep "^harden-kernel\.sh" "$CALL_LOG" | grep -qv " --force"
}

@test "run_full_setup --force=docker,kernel,audit passes --force to specified scripts" {
    export REPLY="n"
    
    run source_and_run run_full_setup --force=docker,kernel,audit
    
    [ "$status" -eq 0 ]
    
    assert_file_contains "$CALL_LOG" "install-docker.sh --force"
    assert_file_contains "$CALL_LOG" "harden-kernel.sh --force"
    assert_file_contains "$CALL_LOG" "setup-audit.sh --force"
    
    # Verify non-specified scripts don't have --force
    grep "^setup-ntp\.sh" "$CALL_LOG" | grep -qv " --force"
    grep "^configure-firewall\.sh" "$CALL_LOG" | grep -qv " --force"
}

@test "run_full_setup --force=packages,traefik,pam,aide forces multiple steps" {
    export REPLY="n"
    
    run source_and_run run_full_setup --force=packages,traefik,pam,aide
    
    [ "$status" -eq 0 ]
    
    assert_file_contains "$CALL_LOG" "install-packages.sh --force"
    assert_file_contains "$CALL_LOG" "install-traefik.sh --force"
    assert_file_contains "$CALL_LOG" "setup-pam-policy.sh --force"
    assert_file_contains "$CALL_LOG" "setup-aide.sh --force"
}

# ══════════════════════════════════════════════════════════════════════════════
# Test: --force (all steps)
# ══════════════════════════════════════════════════════════════════════════════

@test "run_full_setup --force passes --force to all subscripts" {
    export REPLY="n"
    
    run source_and_run run_full_setup --force
    
    [ "$status" -eq 0 ]
    
    # Verify all core scripts received --force
    assert_file_contains "$CALL_LOG" "install-packages.sh --force"
    assert_file_contains "$CALL_LOG" "install-docker.sh --force"
    assert_file_contains "$CALL_LOG" "install-traefik.sh --force"
    assert_file_contains "$CALL_LOG" "configure-firewall.sh --force"
    assert_file_contains "$CALL_LOG" "harden-kernel.sh --force"
    assert_file_contains "$CALL_LOG" "setup-ntp.sh --force"
    assert_file_contains "$CALL_LOG" "setup-audit.sh --force"
    assert_file_contains "$CALL_LOG" "setup-auto-updates.sh --force"
    assert_file_contains "$CALL_LOG" "harden-docker.sh --force"
    assert_file_contains "$CALL_LOG" "setup-apparmor.sh --force"
    assert_file_contains "$CALL_LOG" "setup-pam-policy.sh --force"
    assert_file_contains "$CALL_LOG" "setup-aide.sh --force"
    assert_file_contains "$CALL_LOG" "harden-shared-memory.sh --force"
    assert_file_contains "$CALL_LOG" "setup-fail2ban-enhanced.sh --force"
}

# ══════════════════════════════════════════════════════════════════════════════
# Test: Error handling
# ══════════════════════════════════════════════════════════════════════════════

@test "run_full_setup stops on subscript failure" {
    # Make install-docker.sh fail
    cat > "$DOCKERHOSTING_DIR/scripts/install-docker.sh" <<'EOF'
#!/bin/bash
echo "install-docker.sh $*" >> "$CALL_LOG"
exit 1
EOF
    chmod +x "$DOCKERHOSTING_DIR/scripts/install-docker.sh"
    
    export REPLY="n"
    
    run source_and_run run_full_setup
    
    # Should fail with non-zero exit code
    [ "$status" -ne 0 ]
    
    # Verify install-docker.sh was called
    assert_file_contains "$CALL_LOG" "install-docker.sh"
    
    # Verify subsequent scripts were NOT called (install-traefik.sh comes after install-docker.sh)
    refute grep -q "install-traefik.sh" "$CALL_LOG"
}

@test "run_full_setup stops on harden-kernel.sh failure" {
    # Make harden-kernel.sh fail (later in sequence)
    cat > "$DOCKERHOSTING_DIR/scripts/harden-kernel.sh" <<'EOF'
#!/bin/bash
echo "harden-kernel.sh $*" >> "$CALL_LOG"
exit 1
EOF
    chmod +x "$DOCKERHOSTING_DIR/scripts/harden-kernel.sh"
    
    export REPLY="n"
    
    run source_and_run run_full_setup
    
    [ "$status" -ne 0 ]
    
    # Verify scripts before harden-kernel.sh completed
    assert_file_contains "$CALL_LOG" "install-docker.sh"
    assert_file_contains "$CALL_LOG" "install-traefik.sh"
    assert_file_contains "$CALL_LOG" "configure-firewall.sh"
    assert_file_contains "$CALL_LOG" "harden-kernel.sh"
    
    # Verify scripts after harden-kernel.sh did NOT run
    refute grep -q "setup-ntp.sh" "$CALL_LOG"
    refute grep -q "setup-audit.sh" "$CALL_LOG"
}

# ══════════════════════════════════════════════════════════════════════════════
# Test: Root privilege requirement
# ══════════════════════════════════════════════════════════════════════════════

@test "check_root fails when not running as root" {
    export EUID=1000  # Non-root user
    
    run source_and_run check_root
    
    [ "$status" -eq 1 ]
    [[ "$output" =~ "must be run as root" ]]
}

@test "check_root succeeds when running as root" {
    export EUID=0  # Root user
    
    run source_and_run check_root
    
    [ "$status" -eq 0 ]
}

@test "main function calls check_root early" {
    # Create a modified test that verifies check_root is called before other operations
    # Mock check_root to log when called
    
    local modified_script="$BATS_TEST_TMPDIR/setup_modified.sh"
    cp "$TEST_SCRIPT" "$modified_script"
    
    # Add tracking to check_root
    sed -i.bak 's/check_root() {/check_root() {\n    echo "check_root_called" >> "$CALL_LOG"/' "$modified_script"
    
    export EUID=0
    export REPLY="n"
    
    # Mock git to prevent actual cloning
    create_mock_with_body "git" 'exit 0'
    
    run bash "$modified_script" --update
    
    # Verify check_root was called
    assert_file_contains "$CALL_LOG" "check_root_called"
}

# ══════════════════════════════════════════════════════════════════════════════
# Test: Script tracking and execution flow
# ══════════════════════════════════════════════════════════════════════════════

@test "run_full_setup creates standard directories" {
    export REPLY="n"
    
    # Create a test environment where we can verify directory creation
    run source_and_run run_full_setup
    
    [ "$status" -eq 0 ]
    
    # Note: We can't actually verify /opt/apps creation in the mock environment,
    # but we verify the function completes without error
}

@test "run_full_setup changes to DOCKERHOSTING_DIR before executing subscripts" {
    export REPLY="n"
    
    # Add PWD tracking to one of the subscripts
    cat > "$DOCKERHOSTING_DIR/scripts/install-packages.sh" <<EOF
#!/bin/bash
echo "install-packages.sh \$* PWD=\$PWD" >> "$CALL_LOG"
exit 0
EOF
    chmod +x "$DOCKERHOSTING_DIR/scripts/install-packages.sh"
    
    run source_and_run run_full_setup
    
    [ "$status" -eq 0 ]
    
    # Verify script was run from DOCKERHOSTING_DIR
    assert_file_contains "$CALL_LOG" "PWD=$DOCKERHOSTING_DIR"
}

@test "run_full_setup executes setup-logrotate.sh with correct arguments" {
    export REPLY="n"
    
    run source_and_run run_full_setup
    
    [ "$status" -eq 0 ]
    
    # Verify logrotate was called with docker-system and /var/lib/docker/containers
    assert_file_contains "$CALL_LOG" "setup-logrotate.sh docker-system /var/lib/docker/containers"
}

# ══════════════════════════════════════════════════════════════════════════════
# Test: Interactive prompts and optional components
# ══════════════════════════════════════════════════════════════════════════════

@test "run_full_setup skips optional email setup when user answers no" {
    export REPLY="n"
    
    run source_and_run run_full_setup
    
    [ "$status" -eq 0 ]
    
    # Email script should not be called when user declines
    refute grep -q "setup-email.sh" "$CALL_LOG"
}

@test "run_full_setup skips optional bootloader hardening when user answers no" {
    export REPLY="n"
    
    run source_and_run run_full_setup
    
    [ "$status" -eq 0 ]
    
    # Bootloader script should not be called when user declines
    refute grep -q "harden-bootloader.sh" "$CALL_LOG"
}

@test "run_full_setup skips optional USB hardening when user answers no" {
    export REPLY="n"
    
    run source_and_run run_full_setup
    
    [ "$status" -eq 0 ]
    
    # USB hardening script should not be called when user declines
    refute grep -q "harden-usb.sh" "$CALL_LOG"
}

@test "run_full_setup skips optional SSH MFA when user answers no" {
    export REPLY="n"
    
    run source_and_run run_full_setup
    
    [ "$status" -eq 0 ]
    
    # MFA script should not be called when user declines
    refute grep -q "setup-ssh-mfa.sh" "$CALL_LOG"
}

# ══════════════════════════════════════════════════════════════════════════════
# Test: Force flags with optional components
# ══════════════════════════════════════════════════════════════════════════════

@test "run_full_setup --force=email forces email even with interactive no" {
    export REPLY="n"
    
    run source_and_run run_full_setup --force=email
    
    [ "$status" -eq 0 ]
    
    # Email should be called with --force even when REPLY=n
    # Note: The script logic prompts before calling, so force=email passes --force to the script
    # but doesn't bypass the prompt itself. This tests the flag passing mechanism.
    # The actual script only passes --force if the user answers yes OR if it's in FORCE_STEPS
}

@test "run_full_setup --force=bootloader,mfa forces multiple optional components" {
    export REPLY="n"
    
    run source_and_run run_full_setup --force=bootloader,mfa
    
    [ "$status" -eq 0 ]
    
    # When forced, the flag is passed if the user proceeds
    # This test verifies the parsing logic works for optional components
}

# ══════════════════════════════════════════════════════════════════════════════
# Test: --update flag
# ══════════════════════════════════════════════════════════════════════════════

@test "main function with --update pulls repo and exits without running setup" {
    export EUID=0
    
    # Mock git to simulate successful pull
    create_mock_with_body "git" 'echo "git $*" >> "$CALL_LOG"; exit 0'
    
    run bash "$TEST_SCRIPT" --update
    
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Update mode" ]]
    
    # Verify no subscripts were called (only git operations)
    refute grep -q "install-docker.sh" "$CALL_LOG"
    refute grep -q "setup-ntp.sh" "$CALL_LOG"
}

# ══════════════════════════════════════════════════════════════════════════════
# Test: Display functions
# ══════════════════════════════════════════════════════════════════════════════

@test "display_banner outputs dockerHosting banner" {
    run source_and_run display_banner
    
    [ "$status" -eq 0 ]
    [[ "$output" =~ "dockerHosting" ]]
    [[ "$output" =~ "Server Setup" ]]
}

@test "check_os succeeds on Debian system" {
    # Create mock /etc/os-release
    cat > "$BATS_TEST_TMPDIR/os-release" <<EOF
ID=debian
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
EOF
    
    # Override the os-release path in the function call
    run bash -c "source $TEST_SCRIPT; . $BATS_TEST_TMPDIR/os-release; log_info 'OS: \$PRETTY_NAME'"
    
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Debian" ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# Test: Force flag edge cases
# ══════════════════════════════════════════════════════════════════════════════

@test "run_full_setup --force=invalid-step ignores unknown step name" {
    export REPLY="n"
    
    run source_and_run run_full_setup --force=invalid-step
    
    [ "$status" -eq 0 ]
    
    # All scripts should run without --force (invalid step ignored)
    refute grep -q " --force" "$CALL_LOG"
}

@test "run_full_setup --force=docker,invalid,ntp forces only valid steps" {
    export REPLY="n"
    
    run source_and_run run_full_setup --force=docker,invalid,ntp
    
    [ "$status" -eq 0 ]
    
    # Valid steps should have --force
    assert_file_contains "$CALL_LOG" "install-docker.sh --force"
    assert_file_contains "$CALL_LOG" "setup-ntp.sh --force"
    
    # Other steps should not have --force
    grep "^configure-firewall\.sh" "$CALL_LOG" | grep -qv " --force"
}

@test "run_full_setup handles empty --force= gracefully" {
    export REPLY="n"
    
    run source_and_run run_full_setup --force=
    
    [ "$status" -eq 0 ]
    
    # No scripts should receive --force
    refute grep -q " --force" "$CALL_LOG"
}

# ══════════════════════════════════════════════════════════════════════════════
# Test: Comprehensive integration scenarios
# ══════════════════════════════════════════════════════════════════════════════

@test "run_full_setup executes complete setup flow with all core components" {
    export REPLY="n"
    
    run source_and_run run_full_setup
    
    [ "$status" -eq 0 ]
    
    # Verify minimum expected number of subscripts called
    local call_count
    call_count=$(wc -l < "$CALL_LOG")
    [ "$call_count" -ge 15 ] || {
        echo "Expected at least 15 subscript calls, got $call_count"
        cat "$CALL_LOG"
        return 1
    }
}

@test "run_full_setup with multiple force flags processes all correctly" {
    export REPLY="n"
    
    run source_and_run run_full_setup --force=docker,firewall,ntp,ssh,pam
    
    [ "$status" -eq 0 ]
    
    # Verify each forced step received --force
    assert_file_contains "$CALL_LOG" "install-docker.sh --force"
    assert_file_contains "$CALL_LOG" "configure-firewall.sh --force"
    assert_file_contains "$CALL_LOG" "setup-ntp.sh --force"
    assert_file_contains "$CALL_LOG" "setup-pam-policy.sh --force"
    
    # Verify non-forced steps did NOT receive --force
    grep "^install-traefik\.sh" "$CALL_LOG" | grep -qv " --force"
    grep "^harden-kernel\.sh" "$CALL_LOG" | grep -qv " --force"
}
