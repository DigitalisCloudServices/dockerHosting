#!/usr/bin/env bats
# Tests for scripts/setup-audit.sh (auditd rules)

load '../helpers/common'

setup() {
    setup_mocks

    AUDIT_DIR="$BATS_TEST_TMPDIR/audit"
    RULES="$AUDIT_DIR/rules.d/99-security.rules"
    mkdir -p "$AUDIT_DIR/rules.d"

    create_mock "apt-get"
    create_mock "augenrules"
    create_mock "systemctl"
    create_mock "auditctl"
    # Default: every syscall name is known (x86_64-like)
    create_mock "ausyscall"

    SETUP_AUDIT_SCRIPT="$BATS_TEST_TMPDIR/setup-audit-patched.sh"
    # Point the GRUB watch at a directory that never exists, so the
    # missing-path filter is exercised regardless of the test host
    sed -e "s|/etc/audit|$AUDIT_DIR|g" \
        -e "s|/boot/grub/grub.cfg|$BATS_TEST_TMPDIR/no-such-dir/grub.cfg|" \
        "$SCRIPTS_DIR/setup-audit.sh" > "$SETUP_AUDIT_SCRIPT"
}

teardown() {
    teardown_mocks
}

@test "setup-audit: keeps all syscalls when the architecture knows them" {
    run bash "$SETUP_AUDIT_SCRIPT" --force
    [ "$status" -eq 0 ]
    assert_file_contains "$RULES" '-F arch=b64 -S open,openat,openat2 -F exit=-EACCES'
    assert_file_contains "$RULES" '-F arch=b64 -S unlink,unlinkat,rename,renameat '
}

@test "setup-audit: drops syscalls unknown on arm64 but keeps the rule" {
    # aarch64 native table lacks open/unlink/rename/renameat; compat (b32) has them
    create_mock_with_body "ausyscall" '[[ "$1" == b64 && "$2" =~ ^(open|unlink|rename|renameat)$ ]] && exit 1; exit 0'
    run bash "$SETUP_AUDIT_SCRIPT" --force
    [ "$status" -eq 0 ]
    assert_file_contains "$RULES" '-F arch=b64 -S openat,openat2 -F exit=-EACCES'
    assert_file_contains "$RULES" '-F arch=b64 -S unlinkat -F auid'
    assert_file_contains "$RULES" '-F arch=b32 -S open,openat,openat2 -F exit=-EACCES'
}

@test "setup-audit: drops a rule entirely when none of its syscalls exist" {
    create_mock_with_body "ausyscall" 'exit 1'
    run bash "$SETUP_AUDIT_SCRIPT" --force
    [ "$status" -eq 0 ]
    refute_file_contains "$RULES" '-S open'
    refute_file_contains "$RULES" '-S init_module'
    # -S all is not a syscall name and must survive
    assert_file_contains "$RULES" '-F arch=b32 -S all -k 32bit_api_usage'
    assert_file_contains "$RULES" '-e 2'
}

@test "setup-audit: drops watches whose directory is missing, keeps the rest" {
    run bash "$SETUP_AUDIT_SCRIPT" --force
    [ "$status" -eq 0 ]
    refute_file_contains "$RULES" 'no-such-dir'
    assert_file_contains "$RULES" '-w /etc/passwd -p wa -k identity'
    assert_file_contains "$RULES" '-w /etc/pam.d/ -p wa -k pam_config'
}
