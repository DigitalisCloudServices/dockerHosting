#!/usr/bin/env bats
# Characterization tests for scripts/configure-observability-egress.sh
#
# These tests capture the current behavior of the egress allowlist
# configurator: argument validation, EUID check, runtime-vs-template file
# selection, ipset population, ufw before.rules patching, refresh unit
# installation, and idempotency.

load 'helpers/common'

SCRIPT="$SCRIPTS_DIR/configure-observability-egress.sh"

setup() {
    setup_mocks

    # Isolate every path the script writes to.
    export OBS_ETC_DIR="$BATS_TEST_TMPDIR/etc/observability"
    export OBS_SYSTEMD_DIR="$BATS_TEST_TMPDIR/etc/systemd/system"
    export IPSET_NAME="test_obs_egress"
    export TEMPLATE_DIR="$BATS_TEST_TMPDIR/templates"
    mkdir -p "$OBS_ETC_DIR" "$OBS_SYSTEMD_DIR" "$TEMPLATE_DIR/observability"

    # The script writes the refresh helper to /usr/local/sbin; redirect it.
    SBIN_DIR="$BATS_TEST_TMPDIR/usr/local/sbin"
    mkdir -p "$SBIN_DIR"

    # Provide a default newrelic egress template (two FQDNs).
    cat > "$TEMPLATE_DIR/observability/newrelic.egress" <<'EOF'
# header comment
example-api.example.com
# blank line below

other-api.example.com  # trailing comment
EOF

    # Set up ufw before.rules baseline.
    export UFW_BEFORE_RULES="$BATS_TEST_TMPDIR/etc/ufw/before.rules"
    mkdir -p "$(dirname "$UFW_BEFORE_RULES")"
    cat > "$UFW_BEFORE_RULES" <<'EOF'
# Begin
*filter
:ufw-before-output - [0:0]
-A ufw-before-output -j ACCEPT
COMMIT
EOF

    # ── mocks for external binaries ──────────────────────────────────────────
    IPSET_LOG="$BATS_TEST_TMPDIR/ipset_calls.log"
    export IPSET_LOG
    # By default, ipset list <name> fails -> set doesn't yet exist.
    cat > "$MOCK_BIN/ipset" <<'IPSET_MOCK'
#!/bin/bash
echo "$*" >> "$IPSET_LOG"
case "$1" in
    list) exit 1 ;;
    *)    exit 0 ;;
esac
IPSET_MOCK
    chmod +x "$MOCK_BIN/ipset"

    GETENT_LOG="$BATS_TEST_TMPDIR/getent_calls.log"
    export GETENT_LOG
    cat > "$MOCK_BIN/getent" <<'GETENT_MOCK'
#!/bin/bash
echo "$*" >> "$GETENT_LOG"
# Return one IPv4 + one IPv6 line per host so we can verify v6 is skipped.
echo "203.0.113.10  $2"
echo "2001:db8::1   $2"
exit 0
GETENT_MOCK
    chmod +x "$MOCK_BIN/getent"

    UFW_LOG="$BATS_TEST_TMPDIR/ufw_calls.log"
    export UFW_LOG
    cat > "$MOCK_BIN/ufw" <<'UFW_MOCK'
#!/bin/bash
echo "$*" >> "$UFW_LOG"
if [[ "$1" == "status" ]]; then
    echo "Status: active"
fi
exit 0
UFW_MOCK
    chmod +x "$MOCK_BIN/ufw"

    IPTABLES_LOG="$BATS_TEST_TMPDIR/iptables_calls.log"
    export IPTABLES_LOG
    cat > "$MOCK_BIN/iptables" <<'IPTABLES_MOCK'
#!/bin/bash
echo "$*" >> "$IPTABLES_LOG"
# -C (check) returns 1 the first time so script inserts; record it.
if [[ "$1" == "-C" ]]; then
    exit 1
fi
exit 0
IPTABLES_MOCK
    chmod +x "$MOCK_BIN/iptables"

    SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl_calls.log"
    export SYSTEMCTL_LOG
    create_call_log_mock "systemctl" "$SYSTEMCTL_LOG"

    create_call_log_mock "apt-get" "$BATS_TEST_TMPDIR/apt_calls.log"

    # systemd-run must NOT be on PATH (forces non-detached path). The script
    # uses `command -v systemd-run` so simply omitting the mock is enough,
    # but --no-detach also disables it; we pass --no-detach in every run.

    # ── patch the script ────────────────────────────────────────────────────
    # 1. Bypass the EUID 0 check (we run as a normal user).
    # 2. Redirect the hardcoded /usr/local/sbin path used in install_refresh_unit.
    PATCHED_SCRIPT="$BATS_TEST_TMPDIR/configure-observability-egress-patched.sh"
    sed \
        -e 's|if \[\[ "\$EUID" -ne 0 \]\]|if false|' \
        -e "s|/usr/local/sbin/observability-egress-refresh|$SBIN_DIR/observability-egress-refresh|g" \
        -e "s|/etc/ufw/before.rules|$UFW_BEFORE_RULES|g" \
        "$SCRIPT" > "$PATCHED_SCRIPT"
    chmod +x "$PATCHED_SCRIPT"
}

teardown() {
    teardown_mocks
}

# Helper: invoke the patched script with --no-detach and the OBS_EGRESS_DETACHED
# env var already set, so neither branch tries to re-exec via systemd-run.
run_script() {
    OBS_EGRESS_DETACHED=1 run bash "$PATCHED_SCRIPT" --no-detach "$@"
}

# ── argument validation ─────────────────────────────────────────────────────

@test "configure-observability-egress: exits 1 when --provider is missing" {
    run_script
    [ "$status" -eq 1 ]
    [[ "$output" == *"Missing --provider"* ]]
}

@test "configure-observability-egress: exits 1 when egress file not found" {
    run_script --provider=nonexistent
    [ "$status" -eq 1 ]
    [[ "$output" == *"Egress FQDN list not found"* ]]
}

@test "configure-observability-egress: accepts --provider= equals syntax" {
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
}

# ── file selection (runtime overrides template) ─────────────────────────────

@test "configure-observability-egress: uses template egress file when no runtime override" {
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
    # getent was called for both FQDNs from the template
    grep -q "ahostsv4 example-api.example.com" "$GETENT_LOG"
    grep -q "ahostsv4 other-api.example.com" "$GETENT_LOG"
}

@test "configure-observability-egress: runtime egress file overrides template" {
    cat > "$OBS_ETC_DIR/newrelic.egress" <<'EOF'
runtime-host.example.com
EOF
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
    grep -q "ahostsv4 runtime-host.example.com" "$GETENT_LOG"
    # Template FQDNs should NOT have been queried
    ! grep -q "ahostsv4 example-api.example.com" "$GETENT_LOG"
}

# ── ipset operations ────────────────────────────────────────────────────────

@test "configure-observability-egress: creates ipset with hash:ip family inet" {
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
    grep -q "create $IPSET_NAME hash:ip family inet timeout 0" "$IPSET_LOG"
}

@test "configure-observability-egress: adds resolved IPv4 addresses to ipset" {
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
    grep -q "add $IPSET_NAME 203.0.113.10 -exist" "$IPSET_LOG"
}

@test "configure-observability-egress: skips IPv6 addresses (ipset is family inet)" {
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
    # The mock getent emits 2001:db8::1; the script must NOT add it.
    ! grep -q "2001:db8" "$IPSET_LOG"
}

@test "configure-observability-egress: --force flushes existing ipset" {
    # Make ipset list succeed so the script thinks it already exists.
    cat > "$MOCK_BIN/ipset" <<'IPSET_MOCK'
#!/bin/bash
echo "$*" >> "$IPSET_LOG"
case "$1" in
    list) exit 0 ;;
    *)    exit 0 ;;
esac
IPSET_MOCK
    chmod +x "$MOCK_BIN/ipset"
    run_script --provider=newrelic --force
    [ "$status" -eq 0 ]
    grep -q "flush $IPSET_NAME" "$IPSET_LOG"
}

@test "configure-observability-egress: without --force, existing ipset is not flushed" {
    cat > "$MOCK_BIN/ipset" <<'IPSET_MOCK'
#!/bin/bash
echo "$*" >> "$IPSET_LOG"
case "$1" in
    list) exit 0 ;;
    *)    exit 0 ;;
esac
IPSET_MOCK
    chmod +x "$MOCK_BIN/ipset"
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
    ! grep -q "flush" "$IPSET_LOG"
}

@test "configure-observability-egress: ignores blank lines and comment-only lines in egress file" {
    cat > "$OBS_ETC_DIR/newrelic.egress" <<'EOF'
# just a comment

# another comment
real.example.com
EOF
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
    grep -q "ahostsv4 real.example.com" "$GETENT_LOG"
    # Only one FQDN should have been resolved
    [ "$(grep -c "ahostsv4" "$GETENT_LOG")" -eq 1 ]
}

# ── ufw before.rules patching ───────────────────────────────────────────────

@test "configure-observability-egress: injects iptables rule into before.rules" {
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
    assert_file_contains "$UFW_BEFORE_RULES" "ufw-before-output"
    assert_file_contains "$UFW_BEFORE_RULES" "--match-set $IPSET_NAME dst"
    assert_file_contains "$UFW_BEFORE_RULES" "--dport 443"
    assert_file_contains "$UFW_BEFORE_RULES" "dockerHosting:observability-egress"
}

@test "configure-observability-egress: inserts the rule before COMMIT in *filter block" {
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
    # The rule line must appear before the COMMIT line.
    rule_line=$(grep -n "match-set $IPSET_NAME" "$UFW_BEFORE_RULES" | head -1 | cut -d: -f1)
    commit_line=$(grep -n "^COMMIT" "$UFW_BEFORE_RULES" | head -1 | cut -d: -f1)
    [ -n "$rule_line" ]
    [ -n "$commit_line" ]
    [ "$rule_line" -lt "$commit_line" ]
}

@test "configure-observability-egress: re-running does not duplicate the ufw rule (idempotent)" {
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
    count=$(grep -c "dockerHosting:observability-egress" "$UFW_BEFORE_RULES")
    [ "$count" -eq 1 ]
}

@test "configure-observability-egress: warns and skips when before.rules does not exist" {
    rm -f "$UFW_BEFORE_RULES"
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
    [[ "$output" == *"before.rules"* ]]
    [[ "$output" == *"skipping"* ]]
}

@test "configure-observability-egress: warns and skips when ufw is not installed" {
    rm -f "$MOCK_BIN/ufw"
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
    [[ "$output" == *"ufw not installed"* ]]
}

@test "configure-observability-egress: inserts live iptables rule when ufw is active" {
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
    grep -q -- "-I ufw-before-output" "$IPTABLES_LOG"
    grep -q "match-set $IPSET_NAME dst" "$IPTABLES_LOG"
}

@test "configure-observability-egress: does not insert live iptables rule when ufw is inactive" {
    cat > "$MOCK_BIN/ufw" <<'UFW_MOCK'
#!/bin/bash
echo "$*" >> "$UFW_LOG"
if [[ "$1" == "status" ]]; then
    echo "Status: inactive"
fi
exit 0
UFW_MOCK
    chmod +x "$MOCK_BIN/ufw"
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
    # iptables -I should not be invoked
    if [[ -f "$IPTABLES_LOG" ]]; then
        ! grep -q -- "-I ufw-before-output" "$IPTABLES_LOG"
    fi
}

# ── refresh unit installation ───────────────────────────────────────────────

@test "configure-observability-egress: writes refresh script to /usr/local/sbin" {
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
    assert_file_exists "$SBIN_DIR/observability-egress-refresh"
    # Refresh script is marked executable
    [ -x "$SBIN_DIR/observability-egress-refresh" ]
}

@test "configure-observability-egress: refresh script uses atomic ipset swap" {
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
    assert_file_contains "$SBIN_DIR/observability-egress-refresh" "ipset swap"
    assert_file_contains "$SBIN_DIR/observability-egress-refresh" "ipset destroy"
}

@test "configure-observability-egress: writes refresh service unit" {
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
    local svc="$OBS_SYSTEMD_DIR/observability-egress-refresh.service"
    assert_file_exists "$svc"
    assert_file_contains "$svc" "Type=oneshot"
    assert_file_contains "$svc" "After=network-online.target"
    assert_file_contains "$svc" "ExecStart=$SBIN_DIR/observability-egress-refresh"
}

@test "configure-observability-egress: writes refresh timer with boot + daily schedule" {
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
    local tmr="$OBS_SYSTEMD_DIR/observability-egress-refresh.timer"
    assert_file_exists "$tmr"
    assert_file_contains "$tmr" "OnBootSec=2min"
    assert_file_contains "$tmr" "OnUnitActiveSec=24h"
    assert_file_contains "$tmr" "Persistent=true"
    assert_file_contains "$tmr" "WantedBy=timers.target"
}

@test "configure-observability-egress: reloads systemd and enables the timer" {
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
    grep -q "daemon-reload" "$SYSTEMCTL_LOG"
    grep -q "enable --now observability-egress-refresh.timer" "$SYSTEMCTL_LOG"
}

# ── EUID enforcement (verified via unpatched script) ────────────────────────

@test "configure-observability-egress: refuses to run as non-root" {
    # Use the unpatched script so the EUID check is active.
    OBS_EGRESS_DETACHED=1 run bash "$SCRIPT" --no-detach --provider=newrelic
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be run as root"* ]]
}

# ── output / completion message ─────────────────────────────────────────────

@test "configure-observability-egress: prints completion message naming the provider" {
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
    [[ "$output" == *"Egress allowlist configured for provider 'newrelic'"* ]]
}

@test "configure-observability-egress: reports ipset entry count summary" {
    run_script --provider=newrelic
    [ "$status" -eq 0 ]
    [[ "$output" == *"entries from"* ]]
    [[ "$output" == *"FQDNs"* ]]
}
