#!/usr/bin/env bats
# Tests for scripts/configure-firewall.sh
# Verifies UFW firewall configuration: deny-by-default, egress allow-list, and rule ordering.

load '../helpers/common'

SCRIPT="$SCRIPTS_DIR/configure-firewall.sh"

setup() {
    setup_mocks
    UFW_LOG="$BATS_TEST_TMPDIR/ufw_calls.log"
    UFW_STATUS_OUTPUT="$BATS_TEST_TMPDIR/ufw_status.txt"
    
    # Default: UFW not yet active (first run)
    printf "Status: inactive\n" > "$UFW_STATUS_OUTPUT"
    
    # Mock ufw command to log all calls and simulate behaviour
    create_mock_with_body "ufw" "$(cat <<'MOCK_BODY'
echo "$*" >> "$UFW_LOG"
case "$*" in
    status|"status verbose")
        cat "$UFW_STATUS_OUTPUT"
        ;;
    --force*enable)
        printf "Status: active\n" > "$UFW_STATUS_OUTPUT"
        ;;
esac
exit 0
MOCK_BODY
    )"
    
    # Mock apt-get (in case script tries to install ufw)
    create_call_log_mock "apt-get" "$BATS_TEST_TMPDIR/apt_calls.log"
    
    export UFW_LOG UFW_STATUS_OUTPUT
}

teardown() {
    teardown_mocks
}

# ── basic execution ───────────────────────────────────────────────────────────

@test "configure-firewall: exits 0 on successful configuration" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "configure-firewall: runs without errors when ufw command exists" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Firewall configuration complete"* ]]
}

# ── default deny policies ─────────────────────────────────────────────────────

@test "configure-firewall: sets default deny incoming policy" {
    bash "$SCRIPT"
    grep -q "default deny incoming" "$UFW_LOG"
}

@test "configure-firewall: sets default deny outgoing policy (egress allow-list)" {
    bash "$SCRIPT"
    grep -q "default deny outgoing" "$UFW_LOG"
}

@test "configure-firewall: sets default deny forward policy" {
    bash "$SCRIPT"
    grep -q "default deny forward" "$UFW_LOG"
}

@test "configure-firewall: disables UFW before configuration" {
    bash "$SCRIPT"
    grep -q "^--force disable" "$UFW_LOG"
}

# ── inbound rules ─────────────────────────────────────────────────────────────

@test "configure-firewall: allows SSH port 22 inbound" {
    bash "$SCRIPT"
    grep -q "allow in 22/tcp" "$UFW_LOG"
}

@test "configure-firewall: allows HTTP port 80 inbound" {
    bash "$SCRIPT"
    grep -q "allow in 80/tcp" "$UFW_LOG"
}

@test "configure-firewall: allows HTTPS port 443 inbound" {
    bash "$SCRIPT"
    grep -q "allow in 443/tcp" "$UFW_LOG"
}

@test "configure-firewall: allows Docker bridge networks 172.16.0.0/12 inbound" {
    bash "$SCRIPT"
    grep -q "allow in from 172.16.0.0/12" "$UFW_LOG"
}

@test "configure-firewall: allows Docker bridge networks 192.168.0.0/16 inbound" {
    bash "$SCRIPT"
    grep -q "allow in from 192.168.0.0/16" "$UFW_LOG"
}

# ── egress allow-list (outbound) ──────────────────────────────────────────────

@test "configure-firewall: allows DNS port 53 UDP outbound" {
    bash "$SCRIPT"
    grep -q "allow out 53/udp" "$UFW_LOG"
}

@test "configure-firewall: allows DNS port 53 TCP outbound (zone transfers)" {
    bash "$SCRIPT"
    grep -q "allow out 53/tcp" "$UFW_LOG"
}

@test "configure-firewall: allows DNS-over-TLS port 853 outbound" {
    bash "$SCRIPT"
    grep -q "allow out 853/tcp" "$UFW_LOG"
}

@test "configure-firewall: allows HTTP port 80 outbound (apt updates)" {
    bash "$SCRIPT"
    grep -q "allow out 80/tcp" "$UFW_LOG"
}

@test "configure-firewall: allows HTTPS port 443 outbound (Docker pulls, Let's Encrypt)" {
    bash "$SCRIPT"
    grep -q "allow out 443/tcp" "$UFW_LOG"
}

@test "configure-firewall: allows NTP port 123 UDP outbound (chrony)" {
    bash "$SCRIPT"
    grep -q "allow out 123/udp" "$UFW_LOG"
}

@test "configure-firewall: allows SMTP submission port 587 outbound (email notifications)" {
    bash "$SCRIPT"
    grep -q "allow out 587/tcp" "$UFW_LOG"
}

@test "configure-firewall: allows loopback interface outbound" {
    bash "$SCRIPT"
    grep -q "allow out on lo" "$UFW_LOG"
}

# ── UFW enable ────────────────────────────────────────────────────────────────

@test "configure-firewall: enables UFW after configuration" {
    bash "$SCRIPT"
    grep -q "^--force enable" "$UFW_LOG"
}

@test "configure-firewall: shows verbose status after configuration" {
    bash "$SCRIPT"
    # Check that status verbose is called after enable
    local enable_line disable_line status_line
    enable_line=$(grep -n "^--force enable" "$UFW_LOG" | tail -1 | cut -d: -f1)
    disable_line=$(grep -n "^--force disable" "$UFW_LOG" | head -1 | cut -d: -f1)
    status_line=$(grep -n "^status verbose" "$UFW_LOG" | tail -1 | cut -d: -f1)
    
    [ -n "$enable_line" ] && [ -n "$status_line" ]
    [ "$status_line" -gt "$enable_line" ]
}

# ── rule ordering ─────────────────────────────────────────────────────────────

@test "configure-firewall: default policies set before allow rules" {
    bash "$SCRIPT"
    local deny_line allow_line
    deny_line=$(grep -n "default deny incoming" "$UFW_LOG" | head -1 | cut -d: -f1)
    allow_line=$(grep -n "allow in 22/tcp" "$UFW_LOG" | head -1 | cut -d: -f1)
    
    [ -n "$deny_line" ] && [ -n "$allow_line" ]
    [ "$deny_line" -lt "$allow_line" ]
}

@test "configure-firewall: UFW disabled before setting default policies" {
    bash "$SCRIPT"
    local disable_line deny_line
    disable_line=$(grep -n "^--force disable" "$UFW_LOG" | head -1 | cut -d: -f1)
    deny_line=$(grep -n "default deny incoming" "$UFW_LOG" | head -1 | cut -d: -f1)
    
    [ -n "$disable_line" ] && [ -n "$deny_line" ]
    [ "$disable_line" -lt "$deny_line" ]
}

@test "configure-firewall: inbound rules configured before outbound rules" {
    bash "$SCRIPT"
    local inbound_line outbound_line
    inbound_line=$(grep -n "allow in 22/tcp" "$UFW_LOG" | head -1 | cut -d: -f1)
    outbound_line=$(grep -n "allow out 53/udp" "$UFW_LOG" | head -1 | cut -d: -f1)
    
    [ -n "$inbound_line" ] && [ -n "$outbound_line" ]
    [ "$inbound_line" -lt "$outbound_line" ]
}

@test "configure-firewall: all rules configured before enabling UFW" {
    bash "$SCRIPT"
    local last_rule enable_line
    last_rule=$(grep -n "allow out on lo" "$UFW_LOG" | head -1 | cut -d: -f1)
    enable_line=$(grep -n "^--force enable" "$UFW_LOG" | head -1 | cut -d: -f1)
    
    [ -n "$last_rule" ] && [ -n "$enable_line" ]
    [ "$last_rule" -lt "$enable_line" ]
}

# ── idempotency ───────────────────────────────────────────────────────────────

@test "configure-firewall: skips configuration when UFW already active (no --force)" {
    # Simulate UFW already active
    printf "Status: active\n" > "$UFW_STATUS_OUTPUT"
    
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already configured and active"* ]]
    [[ "$output" == *"skipping"* ]]
}

@test "configure-firewall: does not modify rules when already active (no --force)" {
    # Simulate UFW already active
    printf "Status: active\n" > "$UFW_STATUS_OUTPUT"
    
    bash "$SCRIPT"
    
    # Should only check status, not configure
    ! grep -q "default deny incoming" "$UFW_LOG"
    ! grep -q "allow in 22/tcp" "$UFW_LOG"
}

@test "configure-firewall: reconfigures when --force flag provided" {
    # Simulate UFW already active
    printf "Status: active\n" > "$UFW_STATUS_OUTPUT"
    
    run bash "$SCRIPT" --force
    [ "$status" -eq 0 ]
    
    # Should reconfigure despite being active
    grep -q "default deny incoming" "$UFW_LOG"
    grep -q "allow in 22/tcp" "$UFW_LOG"
}

@test "configure-firewall: --force flag bypasses idempotency check" {
    printf "Status: active\n" > "$UFW_STATUS_OUTPUT"
    
    run bash "$SCRIPT" --force
    [ "$status" -eq 0 ]
    [[ "$output" != *"skipping"* ]]
}

@test "configure-firewall: runs on first invocation (UFW inactive)" {
    # Default state: UFW inactive
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    
    # Should configure
    grep -q "default deny incoming" "$UFW_LOG"
    grep -q "allow in 22/tcp" "$UFW_LOG"
}

# ── security validation ───────────────────────────────────────────────────────

@test "configure-firewall: does not allow unrestricted outbound (no 'allow out' without port)" {
    bash "$SCRIPT"
    ! grep -E "^allow out$" "$UFW_LOG"
}

@test "configure-firewall: does not allow unrestricted inbound (no 'allow in' without port)" {
    bash "$SCRIPT"
    ! grep -E "^allow in$" "$UFW_LOG"
}

@test "configure-firewall: SSH uses TCP protocol (not UDP)" {
    bash "$SCRIPT"
    grep -q "allow in 22/tcp" "$UFW_LOG"
    ! grep -q "allow in 22/udp" "$UFW_LOG"
}

@test "configure-firewall: NTP uses UDP protocol (standard)" {
    bash "$SCRIPT"
    grep -q "allow out 123/udp" "$UFW_LOG"
}

@test "configure-firewall: DNS-over-TLS uses TCP port 853" {
    bash "$SCRIPT"
    grep -q "allow out 853/tcp" "$UFW_LOG"
}

# ── complete rule set verification ───────────────────────────────────────────

@test "configure-firewall: configures exactly 3 default deny policies" {
    bash "$SCRIPT"
    local count
    count=$(grep -c "default deny" "$UFW_LOG")
    [ "$count" -eq 3 ]
}

@test "configure-firewall: configures exactly 5 inbound allow rules (incl. Docker nets)" {
    bash "$SCRIPT"
    # 22, 80, 443, 172.16.0.0/12, 192.168.0.0/16
    local count
    count=$(grep -c "allow in" "$UFW_LOG")
    [ "$count" -eq 5 ]
}

@test "configure-firewall: configures exactly 8 outbound allow rules" {
    bash "$SCRIPT"
    # 53/udp, 53/tcp, 853/tcp, 80/tcp, 443/tcp, 123/udp, 587/tcp, loopback
    local count
    count=$(grep -c "allow out" "$UFW_LOG")
    [ "$count" -eq 8 ]
}

@test "configure-firewall: disables UFW exactly once" {
    bash "$SCRIPT"
    local count
    count=$(grep -c "^--force disable" "$UFW_LOG")
    [ "$count" -eq 1 ]
}

@test "configure-firewall: enables UFW exactly once" {
    bash "$SCRIPT"
    local count
    count=$(grep -c "^--force enable" "$UFW_LOG")
    [ "$count" -eq 1 ]
}
