#!/usr/bin/env bats
# Tests for scripts/harden-shared-memory.sh
# Validates /dev/shm hardening with secure mount options

load '../helpers/common'

setup() {
    setup_mocks
    
    # Override fstab path to test location
    export FSTAB="$BATS_TEST_TMPDIR/fstab"
    export FSTAB_BACKUP="$BATS_TEST_TMPDIR/fstab.backup"
    
    # Create initial fstab without /dev/shm entry
    cat > "$FSTAB" <<'EOF'
# /etc/fstab: static file system information
UUID=1234-5678 / ext4 defaults 0 1
UUID=abcd-efgh /boot ext4 defaults 0 2
EOF
    
    # Log file for mount commands
    MOUNT_LOG="$BATS_TEST_TMPDIR/mount.log"
    
    # Mock mount command to return different states and log remount calls
    create_mock_with_body "mount" "
        if [[ \"\$*\" == *\"remount\"* ]]; then
            echo \"\$*\" >> \"$MOUNT_LOG\"
            exit 0
        elif [[ \"\$*\" == \"\" ]]; then
            # Return current mount state based on test scenario
            if [[ -f \"$BATS_TEST_TMPDIR/mount_hardened\" ]]; then
                echo 'tmpfs on /dev/shm type tmpfs (rw,nosuid,nodev,noexec,relatime,size=2097152k)'
            elif [[ -f \"$BATS_TEST_TMPDIR/mount_unhardened\" ]]; then
                echo 'tmpfs on /dev/shm type tmpfs (rw,nosuid,nodev,relatime,size=2097152k)'
            else
                echo 'tmpfs on /dev/shm type tmpfs (rw,nosuid,nodev,relatime,size=2097152k)'
            fi
            exit 0
        else
            echo \"\$*\" >> \"$MOUNT_LOG\"
            exit 0
        fi
    "
    
    # Mock sed to work with our test fstab
    create_mock_with_body "sed" "
        if [[ \"\$1\" == \"-i\" ]]; then
            # Remove /dev/shm lines from test fstab
            /usr/bin/grep -v '/dev/shm' \"$FSTAB\" > \"$FSTAB.tmp\" || true
            mv \"$FSTAB.tmp\" \"$FSTAB\"
        else
            /usr/bin/sed \"\$@\"
        fi
    "
    
    # Mock cp for backup operations
    create_mock_with_body "cp" "
        /bin/cp \"\$@\"
    "
    
    # Mock rm for cleanup
    create_mock "rm"
    create_mock "chmod"
    create_mock "echo"
    
    # Patch the script to use our overridden paths
    HARDEN_SHM_SCRIPT="$BATS_TEST_TMPDIR/harden-shared-memory-patched.sh"
    sed \
        -e "s|/etc/fstab.backup|$FSTAB_BACKUP|g" \
        -e "s|/etc/fstab|$FSTAB|g" \
        "$SCRIPTS_DIR/harden-shared-memory.sh" > "$HARDEN_SHM_SCRIPT"
    chmod +x "$HARDEN_SHM_SCRIPT"
}

teardown() {
    teardown_mocks
}

# ── fstab entry creation ──────────────────────────────────────────────────────

@test "harden-shared-memory: creates /dev/shm entry in fstab" {
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    assert_file_contains "$FSTAB" "/dev/shm"
}

@test "harden-shared-memory: fstab entry uses tmpfs filesystem type" {
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    assert_file_contains "$FSTAB" "tmpfs /dev/shm tmpfs"
}

@test "harden-shared-memory: creates backup of original fstab" {
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    assert_file_exists "$FSTAB_BACKUP"
    # Backup should have original content (no /dev/shm entry)
    refute_file_contains "$FSTAB_BACKUP" "/dev/shm"
}

@test "harden-shared-memory: does not overwrite existing fstab backup" {
    # Create existing backup with marker content
    echo "EXISTING BACKUP MARKER" > "$FSTAB_BACKUP"
    
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    assert_file_contains "$FSTAB_BACKUP" "EXISTING BACKUP MARKER"
}

# ── noexec mount option ───────────────────────────────────────────────────────

@test "harden-shared-memory: fstab entry includes noexec option" {
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    assert_file_contains "$FSTAB" "noexec"
}

@test "harden-shared-memory: noexec appears in mount options field" {
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Check that noexec is in the options field (4th field)
    local fstab_line=$(grep '/dev/shm' "$FSTAB")
    [[ "$fstab_line" =~ tmpfs[[:space:]]+/dev/shm[[:space:]]+tmpfs[[:space:]]+.*noexec ]]
}

# ── nodev mount option ────────────────────────────────────────────────────────

@test "harden-shared-memory: fstab entry includes nodev option" {
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    assert_file_contains "$FSTAB" "nodev"
}

@test "harden-shared-memory: nodev appears in mount options field" {
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    local fstab_line=$(grep '/dev/shm' "$FSTAB")
    [[ "$fstab_line" =~ tmpfs[[:space:]]+/dev/shm[[:space:]]+tmpfs[[:space:]]+.*nodev ]]
}

# ── nosuid mount option ───────────────────────────────────────────────────────

@test "harden-shared-memory: fstab entry includes nosuid option" {
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    assert_file_contains "$FSTAB" "nosuid"
}

@test "harden-shared-memory: nosuid appears in mount options field" {
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    local fstab_line=$(grep '/dev/shm' "$FSTAB")
    [[ "$fstab_line" =~ tmpfs[[:space:]]+/dev/shm[[:space:]]+tmpfs[[:space:]]+.*nosuid ]]
}

# ── all security options together ─────────────────────────────────────────────

@test "harden-shared-memory: fstab entry includes all security options (noexec,nodev,nosuid)" {
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    local fstab_line=$(grep '/dev/shm' "$FSTAB")
    [[ "$fstab_line" =~ noexec ]] || return 1
    [[ "$fstab_line" =~ nodev ]] || return 1
    [[ "$fstab_line" =~ nosuid ]] || return 1
}

# ── defaults option ───────────────────────────────────────────────────────────

@test "harden-shared-memory: fstab entry includes defaults option" {
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    assert_file_contains "$FSTAB" "defaults"
}

@test "harden-shared-memory: defaults appears before security options" {
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Expected format: defaults,noexec,nodev,nosuid
    local fstab_line=$(grep '/dev/shm' "$FSTAB")
    [[ "$fstab_line" =~ defaults,noexec,nodev,nosuid ]]
}

# ── complete fstab entry format ───────────────────────────────────────────────

@test "harden-shared-memory: fstab entry has correct complete format" {
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Full expected entry: tmpfs /dev/shm tmpfs defaults,noexec,nodev,nosuid,size=2G 0 0
    local fstab_line=$(grep '/dev/shm' "$FSTAB")
    [[ "$fstab_line" =~ ^tmpfs[[:space:]]+/dev/shm[[:space:]]+tmpfs[[:space:]]+defaults,noexec,nodev,nosuid ]]
}

@test "harden-shared-memory: fstab entry has size limit" {
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    assert_file_contains "$FSTAB" "size=2G"
}

@test "harden-shared-memory: fstab entry has correct dump and pass values" {
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Should end with " 0 0"
    local fstab_line=$(grep '/dev/shm' "$FSTAB")
    [[ "$fstab_line" =~ [[:space:]]0[[:space:]]0[[:space:]]*$ ]]
}

# ── mount -o remount execution ────────────────────────────────────────────────

@test "harden-shared-memory: executes mount -o remount" {
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    assert_file_exists "$MOUNT_LOG"
    assert_file_contains "$MOUNT_LOG" "remount"
}

@test "harden-shared-memory: remounts /dev/shm specifically" {
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    assert_file_contains "$MOUNT_LOG" "/dev/shm"
}

@test "harden-shared-memory: uses correct remount syntax" {
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Should call: mount -o remount /dev/shm
    assert_file_contains "$MOUNT_LOG" "-o remount /dev/shm"
}

# ── idempotency (entry already exists) ───────────────────────────────────────

@test "harden-shared-memory: detects already hardened /dev/shm" {
    # Set mount to return hardened state
    touch "$BATS_TEST_TMPDIR/mount_hardened"
    
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Should exit early without modifying fstab
    refute_file_contains "$FSTAB" "/dev/shm"
}

@test "harden-shared-memory: does not modify fstab when already hardened" {
    touch "$BATS_TEST_TMPDIR/mount_hardened"
    
    # Add marker to fstab to verify it's not modified
    echo "# MARKER CONTENT" >> "$FSTAB"
    
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Marker should still be there
    assert_file_contains "$FSTAB" "# MARKER CONTENT"
}

@test "harden-shared-memory: does not create backup when already hardened" {
    touch "$BATS_TEST_TMPDIR/mount_hardened"
    
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Backup should not be created
    [[ ! -f "$FSTAB_BACKUP" ]]
}

@test "harden-shared-memory: does not remount when already hardened" {
    touch "$BATS_TEST_TMPDIR/mount_hardened"
    
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Mount log should not exist (no remount called)
    [[ ! -f "$MOUNT_LOG" ]]
}

# ── existing /dev/shm entry handling ──────────────────────────────────────────

@test "harden-shared-memory: removes existing /dev/shm entry before adding new one" {
    # Add an existing unhardened /dev/shm entry
    echo "tmpfs /dev/shm tmpfs defaults 0 0" >> "$FSTAB"
    
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Should only have one /dev/shm entry
    local count=$(grep -c '/dev/shm' "$FSTAB")
    [ "$count" -eq 1 ]
}

@test "harden-shared-memory: replaces unhardened entry with hardened one" {
    # Add an existing unhardened entry
    echo "tmpfs /dev/shm tmpfs defaults 0 0" >> "$FSTAB"
    
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    # New entry should have security options
    assert_file_contains "$FSTAB" "noexec"
    assert_file_contains "$FSTAB" "nodev"
    assert_file_contains "$FSTAB" "nosuid"
}

@test "harden-shared-memory: preserves other fstab entries" {
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Original entries should still exist
    assert_file_contains "$FSTAB" "UUID=1234-5678 / ext4"
    assert_file_contains "$FSTAB" "UUID=abcd-efgh /boot ext4"
}

# ── script exit status ────────────────────────────────────────────────────────

@test "harden-shared-memory: exits successfully when hardening applied" {
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "harden-shared-memory: exits successfully when already hardened" {
    touch "$BATS_TEST_TMPDIR/mount_hardened"
    
    run bash "$HARDEN_SHM_SCRIPT"
    [ "$status" -eq 0 ]
}
