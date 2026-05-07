#!/usr/bin/env bats
# Comprehensive tests for scripts/setup-apparmor.sh (AppArmor MAC)
# Tests package installation, profile loading, enforcement, and idempotency.

load 'helpers/common'

SCRIPT="$REPO_ROOT/scripts/setup-apparmor.sh"

setup() {
    setup_mocks
    
    # Mock system commands
    create_mock "apt-get"
    create_mock "systemctl"
    create_mock "update-grub"
    create_mock "grub-mkconfig"
    
    # Create fake /etc/default/grub
    export GRUB_FILE="$BATS_TEST_TMPDIR/grub"
    mkdir -p "$(dirname "$GRUB_FILE")"
    echo 'GRUB_CMDLINE_LINUX=""' > "$GRUB_FILE"
    
    # Create fake /proc/cmdline
    export PROC_CMDLINE="$BATS_TEST_TMPDIR/cmdline"
    echo "BOOT_IMAGE=/vmlinuz root=/dev/sda1 ro quiet" > "$PROC_CMDLINE"
    
    # Create fake AppArmor profile directories
    export APPARMOR_D="$BATS_TEST_TMPDIR/apparmor.d"
    mkdir -p "$APPARMOR_D"
    
    # Create mock aa-status that returns disabled by default
    create_mock_with_body "aa-status" 'exit 1'
    
    # Create mock apparmor_parser
    create_mock "apparmor_parser"
    
    # Create mock aa-enforce
    create_mock "aa-enforce"
    
    # Patch the script to use our test paths
    SETUP_APPARMOR_SCRIPT="$BATS_TEST_TMPDIR/setup-apparmor-patched.sh"
    sed \
        -e "s|/etc/default/grub|$GRUB_FILE|g" \
        -e "s|/proc/cmdline|$PROC_CMDLINE|g" \
        -e "s|/etc/apparmor.d|$APPARMOR_D|g" \
        "$SCRIPT" > "$SETUP_APPARMOR_SCRIPT"
    chmod +x "$SETUP_APPARMOR_SCRIPT"
}

teardown() {
    teardown_mocks
}

# ── Package installation ──────────────────────────────────────────────────────

@test "setup-apparmor: installs apparmor package" {
    local apt_log="$BATS_TEST_TMPDIR/apt.log"
    create_call_log_mock "apt-get" "$apt_log"
    
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    
    assert_file_exists "$apt_log"
    assert_file_contains "$apt_log" "install"
    assert_file_contains "$apt_log" "apparmor"
}

@test "setup-apparmor: installs apparmor-utils package" {
    local apt_log="$BATS_TEST_TMPDIR/apt.log"
    create_call_log_mock "apt-get" "$apt_log"
    
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    
    assert_file_contains "$apt_log" "apparmor-utils"
}

@test "setup-apparmor: installs apparmor-profiles package" {
    local apt_log="$BATS_TEST_TMPDIR/apt.log"
    create_call_log_mock "apt-get" "$apt_log"
    
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    
    assert_file_contains "$apt_log" "apparmor-profiles"
}

@test "setup-apparmor: installs apparmor-profiles-extra package" {
    local apt_log="$BATS_TEST_TMPDIR/apt.log"
    create_call_log_mock "apt-get" "$apt_log"
    
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    
    assert_file_contains "$apt_log" "apparmor-profiles-extra"
}

@test "setup-apparmor: uses apt-get with -y flag for non-interactive install" {
    local apt_log="$BATS_TEST_TMPDIR/apt.log"
    create_call_log_mock "apt-get" "$apt_log"
    
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    
    assert_file_contains "$apt_log" "-y"
}

# ── GRUB kernel parameter configuration ──────────────────────────────────────

@test "setup-apparmor: adds apparmor=1 to GRUB_CMDLINE_LINUX" {
    bash "$SETUP_APPARMOR_SCRIPT"
    
    assert_file_contains "$GRUB_FILE" "apparmor=1"
}

@test "setup-apparmor: adds security=apparmor to GRUB_CMDLINE_LINUX" {
    bash "$SETUP_APPARMOR_SCRIPT"
    
    assert_file_contains "$GRUB_FILE" "security=apparmor"
}

@test "setup-apparmor: preserves existing GRUB_CMDLINE_LINUX content" {
    echo 'GRUB_CMDLINE_LINUX="quiet splash"' > "$GRUB_FILE"
    
    bash "$SETUP_APPARMOR_SCRIPT"
    
    assert_file_contains "$GRUB_FILE" "quiet splash"
    assert_file_contains "$GRUB_FILE" "apparmor=1"
}

@test "setup-apparmor: calls update-grub after modifying GRUB config" {
    local grub_log="$BATS_TEST_TMPDIR/grub.log"
    create_call_log_mock "update-grub" "$grub_log"
    
    bash "$SETUP_APPARMOR_SCRIPT"
    
    assert_file_exists "$grub_log"
}

@test "setup-apparmor: skips GRUB modification if apparmor=1 already in cmdline" {
    echo "BOOT_IMAGE=/vmlinuz root=/dev/sda1 apparmor=1 security=apparmor" > "$PROC_CMDLINE"
    
    # Record GRUB file state before
    local grub_before
    grub_before=$(cat "$GRUB_FILE")
    
    bash "$SETUP_APPARMOR_SCRIPT"
    
    # GRUB file should be unchanged
    local grub_after
    grub_after=$(cat "$GRUB_FILE")
    [ "$grub_before" = "$grub_after" ]
}

@test "setup-apparmor: skips GRUB modification if security=apparmor already in cmdline" {
    echo "BOOT_IMAGE=/vmlinuz root=/dev/sda1 security=apparmor" > "$PROC_CMDLINE"
    
    local grub_before
    grub_before=$(cat "$GRUB_FILE")
    
    bash "$SETUP_APPARMOR_SCRIPT"
    
    local grub_after
    grub_after=$(cat "$GRUB_FILE")
    [ "$grub_before" = "$grub_after" ]
}

@test "setup-apparmor: handles missing /etc/default/grub gracefully" {
    rm -f "$GRUB_FILE"
    
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "not found" ]] || [[ "$output" =~ "must be added manually" ]]
}

# ── AppArmor profile loading (when already enabled) ───────────────────────────

@test "setup-apparmor: loads Docker profile when AppArmor is active" {
    # Mock aa-status to indicate AppArmor is enabled
    create_mock_with_body "aa-status" '[[ "$1" == "--enabled" ]] && exit 0; exit 1'
    
    # Create fake Docker profile
    touch "$APPARMOR_D/docker"
    
    local parser_log="$BATS_TEST_TMPDIR/parser.log"
    create_call_log_mock "apparmor_parser" "$parser_log"
    
    bash "$SETUP_APPARMOR_SCRIPT"
    
    assert_file_exists "$parser_log"
    assert_file_contains "$parser_log" "-r"
    assert_file_contains "$parser_log" "docker"
}

@test "setup-apparmor: loads extra profiles from /etc/apparmor.d/ when active" {
    # Mock aa-status to indicate AppArmor is enabled
    create_mock_with_body "aa-status" '[[ "$1" == "--enabled" ]] && exit 0; exit 1'
    
    # Create fake extra profiles
    touch "$APPARMOR_D/usr.sbin.apache2"
    touch "$APPARMOR_D/usr.bin.firefox"
    
    local parser_log="$BATS_TEST_TMPDIR/parser.log"
    create_call_log_mock "apparmor_parser" "$parser_log"
    
    bash "$SETUP_APPARMOR_SCRIPT"
    
    assert_file_exists "$parser_log"
    assert_file_contains "$parser_log" "apache2"
    assert_file_contains "$parser_log" "firefox"
}

@test "setup-apparmor: uses apparmor_parser -r flag to reload profiles" {
    create_mock_with_body "aa-status" '[[ "$1" == "--enabled" ]] && exit 0; exit 1'
    touch "$APPARMOR_D/docker"
    
    local parser_log="$BATS_TEST_TMPDIR/parser.log"
    create_call_log_mock "apparmor_parser" "$parser_log"
    
    bash "$SETUP_APPARMOR_SCRIPT"
    
    assert_file_contains "$parser_log" "-r"
}

@test "setup-apparmor: skips profile loading when AppArmor is not active" {
    # aa-status returns failure (AppArmor not active)
    create_mock_with_body "aa-status" 'exit 1'
    
    local parser_log="$BATS_TEST_TMPDIR/parser.log"
    create_call_log_mock "apparmor_parser" "$parser_log"
    
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    
    # apparmor_parser should not be called
    [ ! -f "$parser_log" ]
}

@test "setup-apparmor: handles missing Docker profile gracefully" {
    create_mock_with_body "aa-status" '[[ "$1" == "--enabled" ]] && exit 0; exit 1'
    
    # No docker profile exists - should not fail
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
}

# ── aa-status verification ────────────────────────────────────────────────────

@test "setup-apparmor: calls aa-status --enabled to check AppArmor state" {
    local status_log="$BATS_TEST_TMPDIR/status.log"
    create_call_log_mock "aa-status" "$status_log"
    
    bash "$SETUP_APPARMOR_SCRIPT"
    
    assert_file_exists "$status_log"
    assert_file_contains "$status_log" "--enabled"
}

@test "setup-apparmor: calls aa-status --summary when AppArmor is active" {
    create_mock_with_body "aa-status" '
        if [[ "$1" == "--enabled" ]]; then
            exit 0
        elif [[ "$1" == "--summary" ]]; then
            echo "apparmor module is loaded."
            echo "5 profiles are loaded."
            echo "5 profiles are in enforce mode."
            exit 0
        fi
    '
    
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "profiles are loaded" ]] || [[ "$output" =~ "status" ]]
}

@test "setup-apparmor: displays summary output when AppArmor is active" {
    create_mock_with_body "aa-status" '[[ "$1" == "--enabled" ]] && exit 0; exit 1'
    
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "AppArmor" ]]
}

# ── Idempotency and --force flag ──────────────────────────────────────────────

@test "setup-apparmor: skips setup when AppArmor already enabled (no --force)" {
    # Mock aa-status to indicate AppArmor is already enabled
    create_mock_with_body "aa-status" 'exit 0'
    
    local apt_log="$BATS_TEST_TMPDIR/apt.log"
    create_call_log_mock "apt-get" "$apt_log"
    
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "already enabled" ]]
    
    # apt-get should not be called
    [ ! -f "$apt_log" ]
}

@test "setup-apparmor: displays skip message when already enabled" {
    create_mock_with_body "aa-status" 'exit 0'
    
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "skipping" ]] || [[ "$output" =~ "already enabled" ]]
}

@test "setup-apparmor: shows use --force hint when already enabled" {
    create_mock_with_body "aa-status" 'exit 0'
    
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "--force" ]]
}

@test "setup-apparmor: runs setup with --force even when already enabled" {
    create_mock_with_body "aa-status" 'exit 0'
    
    local apt_log="$BATS_TEST_TMPDIR/apt.log"
    create_call_log_mock "apt-get" "$apt_log"
    
    run bash "$SETUP_APPARMOR_SCRIPT" --force
    [ "$status" -eq 0 ]
    
    # apt-get should be called despite AppArmor being enabled
    assert_file_exists "$apt_log"
}

@test "setup-apparmor: --force flag bypasses idempotency check" {
    create_mock_with_body "aa-status" 'exit 0'
    
    run bash "$SETUP_APPARMOR_SCRIPT" --force
    [ "$status" -eq 0 ]
    refute_file_contains <(echo "$output") "skipping"
}

@test "setup-apparmor: handles multiple invocations without error" {
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Second run with same state
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
}

# ── Error handling ────────────────────────────────────────────────────────────

@test "setup-apparmor: exits 0 even if AppArmor not active yet" {
    # AppArmor installed but not active (needs reboot)
    create_mock_with_body "aa-status" 'exit 1'
    
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "setup-apparmor: displays reboot warning when kernel params added" {
    # AppArmor not in cmdline yet
    echo "BOOT_IMAGE=/vmlinuz root=/dev/sda1" > "$PROC_CMDLINE"
    
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "REBOOT" ]] || [[ "$output" =~ "reboot" ]]
}

@test "setup-apparmor: handles apparmor_parser failures gracefully" {
    create_mock_with_body "aa-status" '[[ "$1" == "--enabled" ]] && exit 0; exit 1'
    touch "$APPARMOR_D/docker"
    
    # Mock apparmor_parser to fail
    create_mock_with_body "apparmor_parser" 'exit 1'
    
    # Should still complete successfully
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "setup-apparmor: handles missing aa-status command gracefully" {
    # Remove aa-status mock to simulate missing command
    rm -f "$MOCK_BIN/aa-status"
    
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "setup-apparmor: handles update-grub failure gracefully" {
    create_mock_with_body "update-grub" 'exit 1'
    
    # Should still complete
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
}

# ── Output and information display ────────────────────────────────────────────

@test "setup-apparmor: displays setup complete message" {
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Setup Complete" ]] || [[ "$output" =~ "Complete" ]]
}

@test "setup-apparmor: displays configuration summary" {
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Configuration summary" ]] || [[ "$output" =~ "summary" ]]
}

@test "setup-apparmor: mentions docker-default profile in output" {
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "docker-default" ]] || [[ "$output" =~ "Docker containers" ]]
}

@test "setup-apparmor: displays useful commands section" {
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Useful commands" ]] || [[ "$output" =~ "aa-status" ]]
}

@test "setup-apparmor: shows aa-enforce command in help output" {
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "aa-enforce" ]]
}

@test "setup-apparmor: shows aa-complain command in help output" {
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "aa-complain" ]]
}

@test "setup-apparmor: shows aa-genprof command in help output" {
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "aa-genprof" ]]
}

@test "setup-apparmor: displays ACTIVE status when AppArmor in cmdline" {
    echo "BOOT_IMAGE=/vmlinuz apparmor=1 security=apparmor" > "$PROC_CMDLINE"
    
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "ACTIVE" ]]
}

@test "setup-apparmor: displays PENDING REBOOT status when not in cmdline" {
    echo "BOOT_IMAGE=/vmlinuz root=/dev/sda1" > "$PROC_CMDLINE"
    
    run bash "$SETUP_APPARMOR_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PENDING REBOOT" ]] || [[ "$output" =~ "REBOOT" ]]
}

# ── Script safety and best practices ──────────────────────────────────────────

@test "setup-apparmor: uses set -euo pipefail for strict error handling" {
    # Verify script contains strict mode
    assert_file_contains "$SCRIPT" "set -euo pipefail"
}

@test "setup-apparmor: script is executable" {
    [ -x "$SCRIPT" ]
}

@test "setup-apparmor: has shebang for bash" {
    head -n 1 "$SCRIPT" | grep -q "^#!/bin/bash"
}
