#!/usr/bin/env bats
# Tests for scripts/harden-ssh.sh
# Focused on the connection-rate / liveness settings added 2026-06-24 in
# response to a leaked-sshd-session incident on UAT (velaair1).  The pre-
# existing hardening (PermitRootLogin, cipher list, banner, fail2ban jail)
# is exercised in production by setup.sh and is intentionally not re-
# asserted here in full.

load '../helpers/common'

SCRIPT="$SCRIPTS_DIR/harden-ssh.sh"

setup() {
    setup_mocks

    # Redirected paths.  The real script writes to /etc/ssh and /etc/fail2ban,
    # which neither bats nor unprivileged CI can touch.  Mirror the
    # setup-fail2ban-enhanced.bats pattern: sed-rewrite to a tmp tree.
    export SSHD_CONFIG_D="$BATS_TEST_TMPDIR/etc/ssh/sshd_config.d"
    export SSHD_BACKUP="$BATS_TEST_TMPDIR/etc/ssh/sshd_config.backup"
    export SSHD_CONFIG="$BATS_TEST_TMPDIR/etc/ssh/sshd_config"
    export BANNER="$BATS_TEST_TMPDIR/etc/ssh/banner.txt"
    export F2B_JAIL_D="$BATS_TEST_TMPDIR/etc/fail2ban/jail.d"
    export HARDENED_CONF="$SSHD_CONFIG_D/99-hardening.conf"

    mkdir -p "$SSHD_CONFIG_D" "$F2B_JAIL_D" "$(dirname "$SSHD_CONFIG")"
    printf "# fixture sshd_config\n" > "$SSHD_CONFIG"

    # Mocks
    create_mock "sshd"           # sshd -t  →  always valid
    create_mock "systemctl"      # systemctl reload sshd
    # fail2ban-client absent on purpose — exercises the no-fail2ban branch.

    # Patch the script to use temp paths.  Two-phase sed: first replace the
    # real paths with unique placeholders (longest match first so prefixes
    # don't cannibalise each other), then expand the placeholders to the
    # tmp paths.  Doing it in one phase causes the catch-all sshd_config rule
    # to re-substitute inside the just-emitted sshd_config.backup path.
    HARDEN_SCRIPT="$BATS_TEST_TMPDIR/harden-ssh-patched.sh"
    sed \
        -e 's|/etc/ssh/sshd_config\.d|__P_SSHD_D__|g' \
        -e 's|/etc/ssh/sshd_config\.backup|__P_SSHD_BACKUP__|g' \
        -e 's|/etc/ssh/sshd_config|__P_SSHD_CONF__|g' \
        -e 's|/etc/ssh/banner\.txt|__P_BANNER__|g' \
        -e 's|/etc/fail2ban/jail\.d|__P_F2B__|g' \
        -e "s|__P_SSHD_D__|$SSHD_CONFIG_D|g" \
        -e "s|__P_SSHD_BACKUP__|$SSHD_BACKUP|g" \
        -e "s|__P_SSHD_CONF__|$SSHD_CONFIG|g" \
        -e "s|__P_BANNER__|$BANNER|g" \
        -e "s|__P_F2B__|$F2B_JAIL_D|g" \
        "$SCRIPT" > "$HARDEN_SCRIPT"
    chmod +x "$HARDEN_SCRIPT"
}

teardown() {
    teardown_mocks
}

# ── basic execution ───────────────────────────────────────────────────────────

@test "harden-ssh: exits 0 on a clean run" {
    run bash "$HARDEN_SCRIPT" --force
    [ "$status" -eq 0 ]
}

@test "harden-ssh: writes the hardening drop-in" {
    bash "$HARDEN_SCRIPT" --force
    assert_file_exists "$HARDENED_CONF"
}

# ── idempotency / --force ─────────────────────────────────────────────────────

@test "harden-ssh: skips when drop-in already present (no --force)" {
    touch "$HARDENED_CONF"
    run bash "$HARDEN_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already hardened"* ]]
    [[ "$output" == *"skipping"* ]]
}

@test "harden-ssh: --force overwrites an existing drop-in" {
    echo "stale" > "$HARDENED_CONF"
    bash "$HARDEN_SCRIPT" --force
    refute_file_contains "$HARDENED_CONF" "stale"
    assert_file_contains "$HARDENED_CONF" "PermitRootLogin no"
}

# ── connection-rate / liveness (2026-06-24 additions) ─────────────────────────

@test "harden-ssh: ClientAliveInterval is 60s (reap dead clients in ~3 min)" {
    bash "$HARDEN_SCRIPT" --force
    assert_file_contains "$HARDENED_CONF" "ClientAliveInterval 60"
    refute_file_contains "$HARDENED_CONF" "ClientAliveInterval 300"
}

@test "harden-ssh: ClientAliveCountMax is 3 (3 × 60s = ~180s reap window)" {
    bash "$HARDEN_SCRIPT" --force
    assert_file_contains "$HARDENED_CONF" "ClientAliveCountMax 3"
}

@test "harden-ssh: caps any single source IP to 5 unauth slots" {
    bash "$HARDEN_SCRIPT" --force
    assert_file_contains "$HARDENED_CONF" "PerSourceMaxStartups 5"
}

@test "harden-ssh: groups source IPs by /24 for the per-source cap" {
    bash "$HARDEN_SCRIPT" --force
    assert_file_contains "$HARDENED_CONF" "PerSourceNetBlockSize 24"
}

# ── retained baseline hardening ───────────────────────────────────────────────
# These checks make sure a future edit doesn't accidentally drop core hardening.

@test "harden-ssh: PermitRootLogin disabled" {
    bash "$HARDEN_SCRIPT" --force
    assert_file_contains "$HARDENED_CONF" "PermitRootLogin no"
}

@test "harden-ssh: PasswordAuthentication disabled" {
    bash "$HARDEN_SCRIPT" --force
    assert_file_contains "$HARDENED_CONF" "PasswordAuthentication no"
}

@test "harden-ssh: MaxAuthTries set to 3" {
    bash "$HARDEN_SCRIPT" --force
    assert_file_contains "$HARDENED_CONF" "MaxAuthTries 3"
}

@test "harden-ssh: LoginGraceTime set to 30" {
    bash "$HARDEN_SCRIPT" --force
    assert_file_contains "$HARDENED_CONF" "LoginGraceTime 30"
}

# ── config validation + reload ────────────────────────────────────────────────

@test "harden-ssh: runs 'sshd -t' before reloading" {
    SSHD_LOG="$BATS_TEST_TMPDIR/sshd_calls.log"
    create_call_log_mock "sshd" "$SSHD_LOG"
    bash "$HARDEN_SCRIPT" --force
    grep -q -- "-t" "$SSHD_LOG"
}

@test "harden-ssh: aborts and removes drop-in when 'sshd -t' fails" {
    create_mock_with_body "sshd" "exit 1"
    run bash "$HARDEN_SCRIPT" --force
    [ "$status" -ne 0 ]
    [ ! -f "$HARDENED_CONF" ]
}

@test "harden-ssh: reloads sshd after a successful run" {
    SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl_calls.log"
    create_call_log_mock "systemctl" "$SYSTEMCTL_LOG"
    bash "$HARDEN_SCRIPT" --force
    grep -q "reload sshd" "$SYSTEMCTL_LOG"
}

# ── banner ────────────────────────────────────────────────────────────────────

@test "harden-ssh: writes an authorized-access banner" {
    bash "$HARDEN_SCRIPT" --force
    assert_file_exists "$BANNER"
    assert_file_contains "$BANNER" "AUTHORIZED ACCESS ONLY"
}
