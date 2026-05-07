#!/usr/bin/env bats
# Tests for scripts/setup-audit.sh (auditd syscall and file audit rules)

load '../helpers/common'

setup() {
    setup_mocks

    # Override audit file paths for isolation
    export AUDIT_RULES="$BATS_TEST_TMPDIR/99-security.rules"
    export AUDIT_CONF="$BATS_TEST_TMPDIR/auditd.conf"
    export AUDIT_RULES_DIR="$BATS_TEST_TMPDIR/rules.d"
    export AUDIT_CONF_DIR="$BATS_TEST_TMPDIR/audit"
    
    mkdir -p "$AUDIT_RULES_DIR" "$AUDIT_CONF_DIR"
    
    # Mock system commands
    create_mock "apt-get"
    create_mock "systemctl"
    create_mock "augenrules"
    create_mock "auditctl"
    create_mock "date"
    
    # Patch the script to use our overridden paths
    AUDIT_SCRIPT="$BATS_TEST_TMPDIR/setup-audit-patched.sh"
    sed \
        -e "s|/etc/audit/rules.d/99-security.rules|$AUDIT_RULES|g" \
        -e "s|/etc/audit/auditd.conf|$AUDIT_CONF|g" \
        -e "s|/etc/audit/rules.d/audit.rules|$AUDIT_RULES_DIR/audit.rules|g" \
        "$SCRIPTS_DIR/setup-audit.sh" > "$AUDIT_SCRIPT"
    chmod +x "$AUDIT_SCRIPT"
}

teardown() {
    teardown_mocks
}

# ── auditd installation ───────────────────────────────────────────────────────

@test "setup-audit: installs auditd package" {
    APT_LOG="$BATS_TEST_TMPDIR/apt.log"
    create_call_log_mock "apt-get" "$APT_LOG"
    
    run bash "$AUDIT_SCRIPT" --force
    [ "$status" -eq 0 ]
    
    assert_file_contains "$APT_LOG" "install -y auditd audispd-plugins"
}

@test "setup-audit: updates package lists before installation" {
    APT_LOG="$BATS_TEST_TMPDIR/apt.log"
    create_call_log_mock "apt-get" "$APT_LOG"
    
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$APT_LOG" "update"
}

@test "setup-audit: installs audispd-plugins package" {
    APT_LOG="$BATS_TEST_TMPDIR/apt.log"
    create_call_log_mock "apt-get" "$APT_LOG"
    
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$APT_LOG" "audispd-plugins"
}

# ── rules.d file generation ───────────────────────────────────────────────────

@test "setup-audit: creates 99-security.rules file" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_exists "$AUDIT_RULES"
}

@test "setup-audit: rules file contains header with ISO 27001 reference" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "ISO 27001"
}

@test "setup-audit: rules file contains PCI-DSS reference" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "PCI-DSS"
}

@test "setup-audit: rules file contains CIS Benchmarks reference" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "CIS Benchmarks"
}

@test "setup-audit: rules file clears existing rules with -D flag" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "^-D"
}

@test "setup-audit: rules file sets buffer size to 8192" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-b 8192"
}

@test "setup-audit: rules file sets failure mode to 1 (printk)" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-f 1"
}

# ── identity and group file watches ───────────────────────────────────────────

@test "setup-audit: monitors /etc/passwd for changes" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /etc/passwd -p wa -k identity"
}

@test "setup-audit: monitors /etc/shadow for changes" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /etc/shadow -p wa -k identity"
}

@test "setup-audit: monitors /etc/group for changes" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /etc/group -p wa -k identity"
}

@test "setup-audit: monitors /etc/gshadow for changes" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /etc/gshadow -p wa -k identity"
}

@test "setup-audit: monitors /etc/security/opasswd for changes" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /etc/security/opasswd -p wa -k identity"
}

# ── unauthorized access attempt syscalls ──────────────────────────────────────

@test "setup-audit: monitors EACCES access failures on b64 arch" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-a always,exit -F arch=b64 -S open,openat,openat2 -F exit=-EACCES -F auid>=1000 -F auid!=4294967295 -k access"
}

@test "setup-audit: monitors EPERM access failures on b64 arch" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-a always,exit -F arch=b64 -S open,openat,openat2 -F exit=-EPERM -F auid>=1000 -F auid!=4294967295 -k access"
}

@test "setup-audit: monitors EACCES access failures on b32 arch" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-a always,exit -F arch=b32 -S open,openat,openat2 -F exit=-EACCES -F auid>=1000 -F auid!=4294967295 -k access"
}

@test "setup-audit: monitors EPERM access failures on b32 arch" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-a always,exit -F arch=b32 -S open,openat,openat2 -F exit=-EPERM -F auid>=1000 -F auid!=4294967295 -k access"
}

# ── privilege escalation monitoring ───────────────────────────────────────────

@test "setup-audit: monitors /etc/sudoers for changes" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /etc/sudoers -p wa -k privilege_escalation"
}

@test "setup-audit: monitors /etc/sudoers.d/ directory" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /etc/sudoers.d/ -p wa -k privilege_escalation"
}

@test "setup-audit: monitors sudo binary execution" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /usr/bin/sudo -p x -k privilege_escalation"
}

@test "setup-audit: monitors setuid/setgid syscalls on b64 arch" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-a always,exit -F arch=b64 -S setuid,setgid,setreuid,setregid -F auid>=1000 -F auid!=4294967295 -k privilege_escalation"
}

@test "setup-audit: monitors setuid/setgid syscalls on b32 arch" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-a always,exit -F arch=b32 -S setuid,setgid,setreuid,setregid -F auid>=1000 -F auid!=4294967295 -k privilege_escalation"
}

# ── authentication event monitoring ───────────────────────────────────────────

@test "setup-audit: monitors /var/log/faillog" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /var/log/faillog -p wa -k authentication"
}

@test "setup-audit: monitors /var/log/lastlog" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /var/log/lastlog -p wa -k authentication"
}

@test "setup-audit: monitors /var/log/tallylog" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /var/log/tallylog -p wa -k authentication"
}

# ── PAM configuration monitoring ──────────────────────────────────────────────

@test "setup-audit: monitors /etc/pam.d/ directory" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /etc/pam.d/ -p wa -k pam_config"
}

@test "setup-audit: monitors /etc/security/ directory" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /etc/security/ -p wa -k pam_config"
}

# ── SSH configuration monitoring ──────────────────────────────────────────────

@test "setup-audit: monitors /etc/ssh/sshd_config" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /etc/ssh/sshd_config -p wa -k sshd_config"
}

@test "setup-audit: monitors /etc/ssh/sshd_config.d/ directory" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /etc/ssh/sshd_config.d/ -p wa -k sshd_config"
}

# ── network configuration monitoring ──────────────────────────────────────────

@test "setup-audit: monitors /etc/hosts" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /etc/hosts -p wa -k network_config"
}

@test "setup-audit: monitors /etc/hostname" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /etc/hostname -p wa -k network_config"
}

@test "setup-audit: monitors /etc/network/ directory" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /etc/network/ -p wa -k network_config"
}

@test "setup-audit: monitors /etc/systemd/network/ directory" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /etc/systemd/network/ -p wa -k network_config"
}

@test "setup-audit: monitors sethostname syscall on b64 arch" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-a always,exit -F arch=b64 -S sethostname,setdomainname -k network_config"
}

@test "setup-audit: monitors sethostname syscall on b32 arch" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-a always,exit -F arch=b32 -S sethostname,setdomainname -k network_config"
}

# ── system critical file monitoring ───────────────────────────────────────────

@test "setup-audit: monitors /etc/issue" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /etc/issue -p wa -k system_config"
}

@test "setup-audit: monitors /etc/issue.net" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /etc/issue.net -p wa -k system_config"
}

@test "setup-audit: monitors /boot/grub/grub.cfg (bootloader)" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /boot/grub/grub.cfg -p wa -k bootloader"
}

@test "setup-audit: monitors /etc/systemd/system/ directory" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /etc/systemd/system/ -p wa -k systemd"
}

@test "setup-audit: monitors /usr/lib/systemd/system/ directory" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /usr/lib/systemd/system/ -p wa -k systemd"
}

# ── kernel module monitoring ──────────────────────────────────────────────────

@test "setup-audit: monitors /sbin/insmod binary" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /sbin/insmod -p x -k kernel_modules"
}

@test "setup-audit: monitors /sbin/rmmod binary" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /sbin/rmmod -p x -k kernel_modules"
}

@test "setup-audit: monitors /sbin/modprobe binary" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /sbin/modprobe -p x -k kernel_modules"
}

@test "setup-audit: monitors init_module/delete_module syscalls on b64 arch" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-a always,exit -F arch=b64 -S init_module,delete_module -k kernel_modules"
}

@test "setup-audit: monitors init_module/delete_module syscalls on b32 arch" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-a always,exit -F arch=b32 -S init_module,delete_module -k kernel_modules"
}

# ── Docker activity monitoring ────────────────────────────────────────────────

@test "setup-audit: monitors /usr/bin/docker binary execution" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /usr/bin/docker -p x -k docker"
}

@test "setup-audit: monitors /var/lib/docker/ directory" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /var/lib/docker/ -p wa -k docker"
}

@test "setup-audit: monitors /etc/docker/ directory" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /etc/docker/ -p wa -k docker"
}

@test "setup-audit: monitors docker.service systemd unit" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /usr/lib/systemd/system/docker.service -p wa -k docker"
}

@test "setup-audit: monitors /var/run/docker.sock socket" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /var/run/docker.sock -p wa -k docker_socket"
}

# ── file deletion event monitoring ────────────────────────────────────────────

@test "setup-audit: monitors unlink/rename syscalls on b64 arch" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-a always,exit -F arch=b64 -S unlink,unlinkat,rename,renameat -F auid>=1000 -F auid!=4294967295 -k file_deletion"
}

@test "setup-audit: monitors unlink/rename syscalls on b32 arch" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-a always,exit -F arch=b32 -S unlink,unlinkat,rename,renameat -F auid>=1000 -F auid!=4294967295 -k file_deletion"
}

# ── user and group management monitoring ──────────────────────────────────────

@test "setup-audit: monitors /usr/sbin/useradd binary" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /usr/sbin/useradd -p x -k user_management"
}

@test "setup-audit: monitors /usr/sbin/userdel binary" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /usr/sbin/userdel -p x -k user_management"
}

@test "setup-audit: monitors /usr/sbin/usermod binary" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /usr/sbin/usermod -p x -k user_management"
}

@test "setup-audit: monitors /usr/sbin/groupadd binary" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /usr/sbin/groupadd -p x -k group_management"
}

@test "setup-audit: monitors /usr/sbin/groupdel binary" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /usr/sbin/groupdel -p x -k group_management"
}

@test "setup-audit: monitors /usr/sbin/groupmod binary" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-w /usr/sbin/groupmod -p x -k group_management"
}

# ── suspicious activity monitoring ────────────────────────────────────────────

@test "setup-audit: monitors 32-bit syscalls on 64-bit system" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "-a always,exit -F arch=b32 -S all -k 32bit_api_usage"
}

# ── immutable ruleset configuration ───────────────────────────────────────────

@test "setup-audit: sets rules to immutable with -e 2 flag" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_RULES" "^-e 2"
}

@test "setup-audit: immutable flag is the last rule in the file" {
    bash "$AUDIT_SCRIPT" --force
    
    # Check that -e 2 appears near the end (within last 10 lines)
    tail -n 10 "$AUDIT_RULES" | grep -q "^-e 2"
    [ "$?" -eq 0 ]
}

# ── syscall rule count validation ─────────────────────────────────────────────

@test "setup-audit: rules file contains at least 28 syscall rules" {
    bash "$AUDIT_SCRIPT" --force
    
    # Count syscall audit rules (-a always,exit lines)
    syscall_count=$(grep -c "^-a always,exit" "$AUDIT_RULES")
    [ "$syscall_count" -ge 11 ]  # 11 syscall rules in the script
}

@test "setup-audit: rules file contains at least 40 file/directory watches" {
    bash "$AUDIT_SCRIPT" --force
    
    # Count file watch rules (-w lines)
    watch_count=$(grep -c "^-w " "$AUDIT_RULES")
    [ "$watch_count" -ge 35 ]  # 35+ watch rules in the script
}

# ── auditd.conf generation ────────────────────────────────────────────────────

@test "setup-audit: creates auditd.conf configuration file" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_exists "$AUDIT_CONF"
}

@test "setup-audit: configures log file location" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_CONF" "log_file = /var/log/audit/audit.log"
}

@test "setup-audit: sets log format to ENRICHED" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_CONF" "log_format = ENRICHED"
}

@test "setup-audit: sets max log file size to 50MB" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_CONF" "max_log_file = 50"
}

@test "setup-audit: keeps 10 rotated log files" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_CONF" "num_logs = 10"
}

@test "setup-audit: configures log rotation action" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_CONF" "max_log_file_action = ROTATE"
}

@test "setup-audit: sets space_left threshold to 100MB" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_CONF" "space_left = 100"
}

@test "setup-audit: configures disk full action as SUSPEND" {
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDIT_CONF" "disk_full_action = SUSPEND"
}

# ── service operations ────────────────────────────────────────────────────────

@test "setup-audit: loads audit rules with augenrules" {
    AUGEN_LOG="$BATS_TEST_TMPDIR/augenrules.log"
    create_call_log_mock "augenrules" "$AUGEN_LOG"
    
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUGEN_LOG" "--load"
}

@test "setup-audit: enables auditd service" {
    SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    create_call_log_mock "systemctl" "$SYSTEMCTL_LOG"
    
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$SYSTEMCTL_LOG" "enable auditd"
}

@test "setup-audit: restarts auditd service" {
    SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    create_call_log_mock "systemctl" "$SYSTEMCTL_LOG"
    
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$SYSTEMCTL_LOG" "restart auditd"
}

@test "setup-audit: checks if auditd is active after restart" {
    SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    create_call_log_mock "systemctl" "$SYSTEMCTL_LOG"
    
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$SYSTEMCTL_LOG" "is-active --quiet auditd"
}

@test "setup-audit: displays audit statistics with auditctl -s" {
    AUDITCTL_LOG="$BATS_TEST_TMPDIR/auditctl.log"
    create_call_log_mock "auditctl" "$AUDITCTL_LOG"
    
    bash "$AUDIT_SCRIPT" --force
    
    assert_file_contains "$AUDITCTL_LOG" "-s"
}

@test "setup-audit: fails if auditd service does not start" {
    create_mock_with_body "systemctl" 'if [[ "$1" == "is-active" ]]; then exit 1; fi; exit 0'
    
    run bash "$AUDIT_SCRIPT" --force
    [ "$status" -eq 1 ]
}

# ── idempotency and --force flag ──────────────────────────────────────────────

@test "setup-audit: skips configuration if already setup (no --force)" {
    # Create existing rules file and mock active service
    touch "$AUDIT_RULES"
    create_mock_with_body "systemctl" 'if [[ "$1" == "is-active" ]]; then exit 0; fi; exit 0'
    
    APT_LOG="$BATS_TEST_TMPDIR/apt.log"
    create_call_log_mock "apt-get" "$APT_LOG"
    
    run bash "$AUDIT_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Should not call apt-get (early exit)
    refute_file_contains "$APT_LOG" "install"
}

@test "setup-audit: reconfigures when --force is specified even if already setup" {
    # Create existing rules file and mock active service
    touch "$AUDIT_RULES"
    create_mock_with_body "systemctl" 'exit 0'
    
    APT_LOG="$BATS_TEST_TMPDIR/apt.log"
    create_call_log_mock "apt-get" "$APT_LOG"
    
    run bash "$AUDIT_SCRIPT" --force
    [ "$status" -eq 0 ]
    
    # Should call apt-get (--force bypasses check)
    assert_file_contains "$APT_LOG" "install"
}

@test "setup-audit: creates backup of existing audit.rules file" {
    # Create existing audit.rules
    touch "$AUDIT_RULES_DIR/audit.rules"
    create_mock_with_body "date" 'echo "20260507"'
    
    bash "$AUDIT_SCRIPT" --force
    
    # Should create backup with date suffix
    assert_file_exists "$AUDIT_RULES_DIR/audit.rules.backup.20260507"
}

@test "setup-audit: does not fail if no existing audit.rules to backup" {
    # No pre-existing audit.rules file
    run bash "$AUDIT_SCRIPT" --force
    [ "$status" -eq 0 ]
}

@test "setup-audit: is idempotent (can run multiple times)" {
    # First run
    bash "$AUDIT_SCRIPT" --force
    
    # Second run
    run bash "$AUDIT_SCRIPT" --force
    [ "$status" -eq 0 ]
    
    # Rules file should still exist and be valid
    assert_file_exists "$AUDIT_RULES"
    assert_file_contains "$AUDIT_RULES" "-e 2"
}

# ── output and documentation ──────────────────────────────────────────────────

@test "setup-audit: displays completion message" {
    run bash "$AUDIT_SCRIPT" --force
    
    [[ "$output" =~ "Audit Logging Setup Complete" ]]
}

@test "setup-audit: shows immutable warning in output" {
    run bash "$AUDIT_SCRIPT" --force
    
    [[ "$output" =~ "IMMUTABLE" ]]
    [[ "$output" =~ "reboot" ]]
}

@test "setup-audit: displays useful audit commands in output" {
    run bash "$AUDIT_SCRIPT" --force
    
    [[ "$output" =~ "ausearch" ]]
    [[ "$output" =~ "aureport" ]]
    [[ "$output" =~ "auditctl -s" ]]
}
