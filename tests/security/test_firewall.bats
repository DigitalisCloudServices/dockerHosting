#!/usr/bin/env bats
# Tests for scripts/configure-firewall.sh
# Characterization tests covering:
#   - argument parsing (--force, --no-detach, --reset)
#   - SSH-first rule ordering on cold start
#   - tcp_loose conntrack safeguard on cold enable
#   - --reset path (ufw reset + dockerHosting marker stripping)
#   - idempotency when ufw is already active
#   - error paths (ufw missing, ufw failure)

load '../helpers/common'

setup() {
    setup_mocks

    # Capture all ufw invocations to a log so tests can assert ordering.
    UFW_LOG="$BATS_TEST_TMPDIR/ufw_calls.log"
    UFW_STATE="$BATS_TEST_TMPDIR/ufw_state"   # "inactive" or "active"
    echo "inactive" > "$UFW_STATE"

    # Default ufw mock: logs every invocation; honors STATE for `status`.
    # Logs are written as one line per call: "<argv>"
    # Direct heredoc-to-file avoids quote-escape mangling that $(cat <<HEREDOC) introduces.
    cat > "$MOCK_BIN/ufw" <<UFW_MOCK
#!/bin/bash
echo "\$*" >> "$UFW_LOG"
case "\$1" in
  status)
    state=\$(cat "$UFW_STATE" 2>/dev/null || echo inactive)
    if [[ "\$state" == "active" ]]; then
        echo "Status: active"
    else
        echo "Status: inactive"
    fi
    ;;
  --force)
    if [[ "\$2" == "enable" ]]; then
        echo "active" > "$UFW_STATE"
    elif [[ "\$2" == "reset" ]]; then
        echo "inactive" > "$UFW_STATE"
    fi
    ;;
esac
exit 0
UFW_MOCK
    chmod +x "$MOCK_BIN/ufw"

    # Mocks for system tools the script may invoke.
    create_mock "apt-get"
    create_mock "modprobe"

    # Override sensitive paths so we don't touch /etc or /proc on the host.
    export FAKE_UFW_DIR="$BATS_TEST_TMPDIR/ufw"
    export FAKE_PROC_TCP_LOOSE="$BATS_TEST_TMPDIR/nf_conntrack_tcp_loose"
    mkdir -p "$FAKE_UFW_DIR"

    # Patch the script:
    #   - rewrite /etc/ufw/* paths to FAKE_UFW_DIR
    #   - rewrite /proc/sys/net/netfilter/nf_conntrack_tcp_loose to FAKE_PROC_TCP_LOOSE
    FW_SCRIPT="$BATS_TEST_TMPDIR/configure-firewall-patched.sh"
    sed \
        -e "s|/etc/ufw/before.rules|$FAKE_UFW_DIR/before.rules|g" \
        -e "s|/etc/ufw/before6.rules|$FAKE_UFW_DIR/before6.rules|g" \
        -e "s|/proc/sys/net/netfilter/nf_conntrack_tcp_loose|$FAKE_PROC_TCP_LOOSE|g" \
        "$SCRIPTS_DIR/configure-firewall.sh" > "$FW_SCRIPT"
    chmod +x "$FW_SCRIPT"

    export UFW_LOG UFW_STATE
}

teardown() {
    teardown_mocks
}

# ── helpers ──────────────────────────────────────────────────────────────────

# Returns the line number of the first ufw call matching the given fixed text.
# Echoes "" if not found.
ufw_call_line() {
    local needle="$1"
    grep -nF -- "$needle" "$UFW_LOG" 2>/dev/null | head -n1 | cut -d: -f1
}

# Always invoke the patched script with --no-detach so we never try to
# re-exec under systemd-run during tests.
run_fw() {
    run bash "$FW_SCRIPT" --no-detach "$@"
}

# ── argument parsing ─────────────────────────────────────────────────────────

@test "configure-firewall: exits 0 on a clean cold-start configuration" {
    run_fw
    [ "$status" -eq 0 ]
}

@test "configure-firewall: --no-detach skips systemd-run re-exec" {
    # If --no-detach is honored, systemd-run is never invoked.
    create_call_log_mock "systemd-run" "$BATS_TEST_TMPDIR/systemd-run.log"
    run_fw
    [ "$status" -eq 0 ]
    [ ! -f "$BATS_TEST_TMPDIR/systemd-run.log" ]
}

@test "configure-firewall: unknown flags are ignored (no failure)" {
    run_fw --bogus-flag
    [ "$status" -eq 0 ]
}

@test "configure-firewall: --reset implies --force (reapplies even when active)" {
    # Pre-mark ufw active. Without --force, the script would early-exit.
    echo "active" > "$UFW_STATE"
    run_fw --reset
    [ "$status" -eq 0 ]
    # Reset must have actually run.
    [ -n "$(ufw_call_line '--force reset')" ]
}

# ── idempotency ──────────────────────────────────────────────────────────────

@test "configure-firewall: skips reconfiguration when ufw already active and no --force" {
    echo "active" > "$UFW_STATE"
    run_fw
    [ "$status" -eq 0 ]
    [[ "$output" == *"already active"* ]]
    [[ "$output" == *"skipping"* ]]
    # No allow rules should have been added.
    [ -z "$(ufw_call_line 'allow in 22/tcp')" ]
}

@test "configure-firewall: --force re-applies rules even when ufw is active" {
    echo "active" > "$UFW_STATE"
    run_fw --force
    [ "$status" -eq 0 ]
    [[ "$output" != *"skipping"* ]]
    [ -n "$(ufw_call_line 'allow in 22/tcp')" ]
}

@test "configure-firewall: active ufw with --force does NOT call enable (no cycle)" {
    echo "active" > "$UFW_STATE"
    run_fw --force
    [ "$status" -eq 0 ]
    # We must never trigger a disable→enable cycle on an already-running ufw.
    [ -z "$(ufw_call_line '--force enable')" ]
    [[ "$output" == *"no disable/enable cycle"* ]]
}

# ── SSH-first ordering on cold start ─────────────────────────────────────────

@test "configure-firewall: cold start enables ufw exactly once at the end" {
    run_fw
    [ "$status" -eq 0 ]
    # Exactly one enable call.
    local n
    n=$(grep -cF -- '--force enable' "$UFW_LOG" || true)
    [ "$n" -eq 1 ]
}

@test "configure-firewall: SSH allow precedes default-deny on cold start" {
    run_fw
    local ssh_line deny_in_line
    ssh_line=$(ufw_call_line 'allow in 22/tcp')
    deny_in_line=$(ufw_call_line 'default deny incoming')
    [ -n "$ssh_line" ]
    [ -n "$deny_in_line" ]
    [ "$ssh_line" -lt "$deny_in_line" ]
}

@test "configure-firewall: SSH allow precedes ufw enable on cold start" {
    run_fw
    local ssh_line enable_line
    ssh_line=$(ufw_call_line 'allow in 22/tcp')
    enable_line=$(ufw_call_line '--force enable')
    [ -n "$ssh_line" ]
    [ -n "$enable_line" ]
    [ "$ssh_line" -lt "$enable_line" ]
}

@test "configure-firewall: SSH is the FIRST allow rule applied" {
    run_fw
    # First line of the log that contains "allow" should be the SSH rule.
    local first_allow
    first_allow=$(grep -F 'allow' "$UFW_LOG" | head -n1)
    [[ "$first_allow" == *"allow in 22/tcp"* ]]
}

# ── inbound rules ────────────────────────────────────────────────────────────

@test "configure-firewall: allows HTTP (80/tcp) inbound" {
    run_fw
    [ -n "$(ufw_call_line 'allow in 80/tcp')" ]
}

@test "configure-firewall: allows HTTPS (443/tcp) inbound" {
    run_fw
    [ -n "$(ufw_call_line 'allow in 443/tcp')" ]
}

@test "configure-firewall: allows docker bridge 172.16.0.0/12 inbound" {
    run_fw
    [ -n "$(ufw_call_line 'allow in from 172.16.0.0/12')" ]
}

@test "configure-firewall: allows private 192.168.0.0/16 inbound" {
    run_fw
    [ -n "$(ufw_call_line 'allow in from 192.168.0.0/16')" ]
}

# ── outbound rules ───────────────────────────────────────────────────────────

@test "configure-firewall: allows DNS UDP outbound" {
    run_fw
    [ -n "$(ufw_call_line 'allow out 53/udp')" ]
}

@test "configure-firewall: allows DNS TCP outbound" {
    run_fw
    [ -n "$(ufw_call_line 'allow out 53/tcp')" ]
}

@test "configure-firewall: allows DNS over TLS (853/tcp) outbound" {
    run_fw
    [ -n "$(ufw_call_line 'allow out 853/tcp')" ]
}

@test "configure-firewall: allows HTTP (80/tcp) outbound" {
    run_fw
    [ -n "$(ufw_call_line 'allow out 80/tcp')" ]
}

@test "configure-firewall: allows HTTPS (443/tcp) outbound" {
    run_fw
    [ -n "$(ufw_call_line 'allow out 443/tcp')" ]
}

@test "configure-firewall: allows NTP (123/udp) outbound" {
    run_fw
    [ -n "$(ufw_call_line 'allow out 123/udp')" ]
}

@test "configure-firewall: allows SMTP submission (587/tcp) outbound" {
    run_fw
    [ -n "$(ufw_call_line 'allow out 587/tcp')" ]
}

@test "configure-firewall: allows loopback (allow out on lo)" {
    run_fw
    [ -n "$(ufw_call_line 'allow out on lo')" ]
}

# ── default policies ─────────────────────────────────────────────────────────

@test "configure-firewall: sets default deny incoming" {
    run_fw
    [ -n "$(ufw_call_line 'default deny incoming')" ]
}

@test "configure-firewall: sets default deny outgoing" {
    run_fw
    [ -n "$(ufw_call_line 'default deny outgoing')" ]
}

@test "configure-firewall: sets default deny forward" {
    run_fw
    [ -n "$(ufw_call_line 'default deny forward')" ]
}

@test "configure-firewall: applies default policies AFTER allow rules" {
    run_fw
    # The last `allow` call must come before the first `default deny`.
    local last_allow first_deny
    last_allow=$(grep -nF 'allow' "$UFW_LOG" | tail -n1 | cut -d: -f1)
    first_deny=$(grep -nF 'default deny' "$UFW_LOG" | head -n1 | cut -d: -f1)
    [ -n "$last_allow" ]
    [ -n "$first_deny" ]
    [ "$last_allow" -lt "$first_deny" ]
}

# ── tcp_loose conntrack safeguard ────────────────────────────────────────────

@test "configure-firewall: sets nf_conntrack_tcp_loose=1 on cold start if writable" {
    # Make the fake proc file exist and writable.
    : > "$FAKE_PROC_TCP_LOOSE"
    run_fw
    [ "$status" -eq 0 ]
    # The file should now contain "1".
    run cat "$FAKE_PROC_TCP_LOOSE"
    [ "$status" -eq 0 ]
    [[ "$output" == "1" ]]
}

@test "configure-firewall: announces tcp_loose adjustment when writable" {
    : > "$FAKE_PROC_TCP_LOOSE"
    run_fw
    [[ "$output" == *"nf_conntrack_tcp_loose=1"* ]]
}

@test "configure-firewall: skips tcp_loose write silently if not writable" {
    # Do NOT create the proc file; the [[ -w ... ]] guard should skip.
    [ ! -e "$FAKE_PROC_TCP_LOOSE" ]
    run_fw
    [ "$status" -eq 0 ]
    [[ "$output" != *"nf_conntrack_tcp_loose=1"* ]]
}

@test "configure-firewall: attempts to modprobe nf_conntrack on cold start" {
    local modprobe_log="$BATS_TEST_TMPDIR/modprobe.log"
    create_call_log_mock "modprobe" "$modprobe_log"
    run_fw
    [ "$status" -eq 0 ]
    assert_file_exists "$modprobe_log"
    assert_file_contains "$modprobe_log" "nf_conntrack"
}

@test "configure-firewall: does NOT touch tcp_loose when ufw is already active" {
    echo "active" > "$UFW_STATE"
    : > "$FAKE_PROC_TCP_LOOSE"
    run_fw --force
    [ "$status" -eq 0 ]
    # The cold-start branch is skipped on an active ufw; tcp_loose stays empty.
    run cat "$FAKE_PROC_TCP_LOOSE"
    [[ "$output" == "" ]]
}

# ── --reset path ─────────────────────────────────────────────────────────────

@test "configure-firewall: --reset invokes 'ufw --force reset'" {
    run_fw --reset
    [ "$status" -eq 0 ]
    [ -n "$(ufw_call_line '--force reset')" ]
}

@test "configure-firewall: --reset reset precedes SSH allow rule" {
    run_fw --reset
    local reset_line ssh_line
    reset_line=$(ufw_call_line '--force reset')
    ssh_line=$(ufw_call_line 'allow in 22/tcp')
    [ -n "$reset_line" ]
    [ -n "$ssh_line" ]
    [ "$reset_line" -lt "$ssh_line" ]
}

@test "configure-firewall: --reset still ends with a single enable call" {
    run_fw --reset
    [ "$status" -eq 0 ]
    local n
    n=$(grep -cF -- '--force enable' "$UFW_LOG" || true)
    [ "$n" -eq 1 ]
}

@test "configure-firewall: --reset announces backup notice" {
    run_fw --reset
    [[ "$output" == *"Resetting UFW"* ]]
    [[ "$output" == *"backed up"* ]]
}

@test "configure-firewall: without --reset, no reset call is made" {
    run_fw
    [ "$status" -eq 0 ]
    [ -z "$(ufw_call_line '--force reset')" ]
}

# ── orphan dockerHosting marker stripping (before.rules) ─────────────────────

@test "configure-firewall: --reset strips dockerHosting markers from before.rules" {
    # Script uses GNU `sed -i` (no arg). macOS BSD-sed requires `sed -i ''`,
    # so this fails locally on macOS but passes in CI (Linux/GNU sed).
    [[ "$OSTYPE" == darwin* ]] && skip "GNU sed -i required (script uses GNU syntax); passes on Linux CI"
    cat > "$FAKE_UFW_DIR/before.rules" <<'EOF'
*filter
# dockerHosting:obs_egress_ips
-A ufw-before-output -m set --match-set obs_egress_ips dst -j ACCEPT
# unrelated rule
-A ufw-before-output -j RETURN
COMMIT
EOF
    run_fw --reset
    [ "$status" -eq 0 ]
    refute_file_contains "$FAKE_UFW_DIR/before.rules" "dockerHosting:"
    # Unrelated content must survive.
    assert_file_contains "$FAKE_UFW_DIR/before.rules" "unrelated rule"
    assert_file_contains "$FAKE_UFW_DIR/before.rules" "COMMIT"
    [[ "$output" == *"Stripping dockerHosting markers"* ]]
}

@test "configure-firewall: --reset strips dockerHosting markers from before6.rules" {
    [[ "$OSTYPE" == darwin* ]] && skip "GNU sed -i required (script uses GNU syntax); passes on Linux CI"
    cat > "$FAKE_UFW_DIR/before6.rules" <<'EOF'
*filter
# dockerHosting:obs_egress_ips_v6
-A ufw6-before-output -j ACCEPT
COMMIT
EOF
    run_fw --reset
    [ "$status" -eq 0 ]
    refute_file_contains "$FAKE_UFW_DIR/before6.rules" "dockerHosting:"
    assert_file_contains "$FAKE_UFW_DIR/before6.rules" "COMMIT"
}

@test "configure-firewall: --reset leaves before.rules untouched when no marker present" {
    cat > "$FAKE_UFW_DIR/before.rules" <<'EOF'
*filter
-A ufw-before-output -j RETURN
COMMIT
EOF
    cp "$FAKE_UFW_DIR/before.rules" "$BATS_TEST_TMPDIR/before.rules.orig"
    run_fw --reset
    [ "$status" -eq 0 ]
    run diff -q "$FAKE_UFW_DIR/before.rules" "$BATS_TEST_TMPDIR/before.rules.orig"
    [ "$status" -eq 0 ]
}

@test "configure-firewall: --reset is a no-op for marker stripping when files don't exist" {
    [ ! -f "$FAKE_UFW_DIR/before.rules" ]
    [ ! -f "$FAKE_UFW_DIR/before6.rules" ]
    run_fw --reset
    [ "$status" -eq 0 ]
}

@test "configure-firewall: WITHOUT --reset, dockerHosting markers are NOT stripped" {
    cat > "$FAKE_UFW_DIR/before.rules" <<'EOF'
# dockerHosting:obs_egress_ips
-A something -j ACCEPT
EOF
    run_fw
    [ "$status" -eq 0 ]
    # Marker must still be there — reset is the only path that touches it.
    assert_file_contains "$FAKE_UFW_DIR/before.rules" "dockerHosting:"
}

# ── ufw missing / install path ───────────────────────────────────────────────

@test "configure-firewall: installs ufw via apt-get when not present" {
    # Remove ufw mock so `command -v ufw` fails initially. Our apt-get mock
    # will create the ufw mock to simulate a successful install.
    rm -f "$MOCK_BIN/ufw"

    local apt_log="$BATS_TEST_TMPDIR/apt.log"
    cat > "$MOCK_BIN/apt-get" <<APT_MOCK
#!/bin/bash
echo "\$*" >> "$apt_log"
if [[ "\$*" == *"install -y ufw"* ]]; then
    cat > "$MOCK_BIN/ufw" <<'UFW_EOF'
#!/bin/bash
echo "\$*" >> "${UFW_LOG}"
case "\$1" in
  status) echo "Status: inactive" ;;
esac
exit 0
UFW_EOF
    chmod +x "$MOCK_BIN/ufw"
fi
exit 0
APT_MOCK
    chmod +x "$MOCK_BIN/apt-get"

    run_fw
    [ "$status" -eq 0 ]
    assert_file_exists "$apt_log"
    assert_file_contains "$apt_log" "install -y ufw"
    [[ "$output" == *"Installing UFW"* ]]
}

# ── error / failure paths ────────────────────────────────────────────────────

@test "configure-firewall: propagates failure when 'ufw enable' fails" {
    # Mock ufw to fail on enable, succeed otherwise.
    cat > "$MOCK_BIN/ufw" <<UFW_MOCK
#!/bin/bash
echo "\$*" >> "$UFW_LOG"
case "\$1" in
  status) echo "Status: inactive" ;;
  --force)
    if [[ "\$2" == "enable" ]]; then
        echo "ERROR: enable failed" >&2
        exit 1
    fi
    ;;
esac
exit 0
UFW_MOCK
    chmod +x "$MOCK_BIN/ufw"
    run_fw
    [ "$status" -ne 0 ]
}

@test "configure-firewall: propagates failure when 'ufw allow' fails (set -e)" {
    cat > "$MOCK_BIN/ufw" <<UFW_MOCK
#!/bin/bash
echo "\$*" >> "$UFW_LOG"
case "\$1" in
  status) echo "Status: inactive" ;;
  allow) exit 1 ;;
esac
exit 0
UFW_MOCK
    chmod +x "$MOCK_BIN/ufw"
    run_fw
    [ "$status" -ne 0 ]
}

@test "configure-firewall: propagates failure when 'ufw --force reset' fails" {
    cat > "$MOCK_BIN/ufw" <<UFW_MOCK
#!/bin/bash
echo "\$*" >> "$UFW_LOG"
case "\$1" in
  status) echo "Status: inactive" ;;
  --force)
    if [[ "\$2" == "reset" ]]; then
        exit 1
    fi
    ;;
esac
exit 0
UFW_MOCK
    chmod +x "$MOCK_BIN/ufw"
    run_fw --reset
    [ "$status" -ne 0 ]
}

# ── informational / summary output ───────────────────────────────────────────

@test "configure-firewall: prints completion banner on success" {
    run_fw
    [ "$status" -eq 0 ]
    [[ "$output" == *"Firewall configuration complete"* ]]
}

@test "configure-firewall: prints default-rule summary on success" {
    run_fw
    [[ "$output" == *"Default rules configured"* ]]
    [[ "$output" == *"Inbound:"* ]]
    [[ "$output" == *"Outbound:"* ]]
}

@test "configure-firewall: cold-start path announces 'Enabling UFW firewall'" {
    run_fw
    [[ "$output" == *"Enabling UFW firewall"* ]]
    [[ "$output" == *"cold start"* ]]
}

@test "configure-firewall: ensures SSH allow rule is announced" {
    run_fw
    [[ "$output" == *"SSH inbound allow rule"* ]]
}

# ── final status verification ────────────────────────────────────────────────

@test "configure-firewall: calls 'ufw status verbose' at end of cold start" {
    run_fw
    [ "$status" -eq 0 ]
    [ -n "$(ufw_call_line 'status verbose')" ]
}

@test "configure-firewall: complete cold-start workflow applies all expected rules" {
    run_fw
    [ "$status" -eq 0 ]

    # All inbound allow rules.
    [ -n "$(ufw_call_line 'allow in 22/tcp')" ]
    [ -n "$(ufw_call_line 'allow in 80/tcp')" ]
    [ -n "$(ufw_call_line 'allow in 443/tcp')" ]
    [ -n "$(ufw_call_line 'allow in from 172.16.0.0/12')" ]
    [ -n "$(ufw_call_line 'allow in from 192.168.0.0/16')" ]

    # All outbound allow rules.
    [ -n "$(ufw_call_line 'allow out 53/udp')" ]
    [ -n "$(ufw_call_line 'allow out 53/tcp')" ]
    [ -n "$(ufw_call_line 'allow out 853/tcp')" ]
    [ -n "$(ufw_call_line 'allow out 80/tcp')" ]
    [ -n "$(ufw_call_line 'allow out 443/tcp')" ]
    [ -n "$(ufw_call_line 'allow out 123/udp')" ]
    [ -n "$(ufw_call_line 'allow out 587/tcp')" ]
    [ -n "$(ufw_call_line 'allow out on lo')" ]

    # All default-deny policies.
    [ -n "$(ufw_call_line 'default deny incoming')" ]
    [ -n "$(ufw_call_line 'default deny outgoing')" ]
    [ -n "$(ufw_call_line 'default deny forward')" ]

    # Single enable.
    local n
    n=$(grep -cF -- '--force enable' "$UFW_LOG" || true)
    [ "$n" -eq 1 ]
}
