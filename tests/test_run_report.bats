#!/usr/bin/env bats
# Tests for scripts/run-report.sh — host audit report

load 'helpers/common'

SCRIPT="$REPO_ROOT/scripts/run-report.sh"

setup() {
    setup_mocks

    # Override the report output directory to a test-owned location
    export DOCKERHOSTING_REPORT_DIR="$BATS_TEST_TMPDIR/report"
    mkdir -p "$DOCKERHOSTING_REPORT_DIR"

    # EUID is a read-only bash builtin, so we cannot fake it. Build a wrapper
    # that strips the root-check block before sourcing the script body.
    export WRAPPED_SCRIPT="$BATS_TEST_TMPDIR/run-report-wrapped.sh"
    awk '
        /^    if \[ "\$EUID" -ne 0 \]; then$/ { skip=3; next }
        skip > 0 { skip--; next }
        { print }
    ' "$SCRIPT" > "$WRAPPED_SCRIPT"
    chmod +x "$WRAPPED_SCRIPT"

    # Stand in for every external command run-report.sh invokes
    create_mock_with_body hostnamectl 'echo "Static hostname: testhost"'
    create_mock_with_body uname 'echo "Linux testhost 6.1.0 #1 SMP x86_64 GNU/Linux"'
    create_mock_with_body chronyc 'echo "Stratum         : 2"'
    create_mock_with_body uptime 'echo "up 3 hours"'
    create_mock_with_body apt 'echo "Listing... Done"'
    create_mock_with_body dpkg 'echo " ii  linux-image-6.1.0  6.1.0-1"'
    create_mock_with_body tail 'cat'
    create_mock_with_body lsb_release 'echo "trixie"'
    create_mock_with_body debsecan 'echo "CVE-2024-0001 pkgX high urgency"'
    create_mock_with_body docker 'echo ""'
    create_mock_with_body ufw 'echo "Status: active"; echo "Default: deny (incoming), allow (outgoing)"; echo "22/tcp                     ALLOW       Anywhere"'
    create_mock_with_body ss 'printf "LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:((\"sshd\",pid=1,fd=3))\nLISTEN 0 128 0.0.0.0:9999 0.0.0.0:* users:((\"nc\",pid=2,fd=3))\n"'
    create_mock_with_body journalctl 'echo "no entries"'
    create_mock_with_body systemctl 'exit 3'
    create_mock_with_body fail2ban-client 'echo "Status for the jail: sshd"'
    create_mock_with_body aa-status 'echo "apparmor module is loaded."'
    create_mock_with_body sshd 'echo "permitrootlogin no"; echo "passwordauthentication no"; echo "maxauthtries 4"'
    create_mock_with_body apt-get 'exit 0'
    create_mock_with_body chown 'exit 0'
    create_mock_with_body chmod 'exit 0'
    create_mock_with_body logrotate 'exit 0'
    create_mock_with_body mkdir 'command /bin/mkdir "$@"'
}

teardown() {
    teardown_mocks
}

@test "run-report: rejects non-root invocation" {
    # The unwrapped script must refuse when EUID != 0
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "must be run as root" ]]
}

@test "run-report: produces a markdown log and a JSON sidecar" {
    run bash "$WRAPPED_SCRIPT"
    [ "$status" -eq 0 ]

    local log_count json_count
    log_count=$(find "$DOCKERHOSTING_REPORT_DIR" -maxdepth 1 -name 'audit-report-*.log' | wc -l | tr -d ' ')
    json_count=$(find "$DOCKERHOSTING_REPORT_DIR" -maxdepth 1 -name 'audit-report-*.log.json' | wc -l | tr -d ' ')
    [ "$log_count" -eq 1 ]
    [ "$json_count" -eq 1 ]
}

@test "run-report: markdown output contains expected section headings" {
    run bash "$WRAPPED_SCRIPT"
    [ "$status" -eq 0 ]

    local md
    md=$(find "$DOCKERHOSTING_REPORT_DIR" -maxdepth 1 -name 'audit-report-*.log' | head -1)
    [ -f "$md" ]

    assert_file_contains "$md" "# dockerHosting Audit Report"
    assert_file_contains "$md" "## 1. Host identity"
    assert_file_contains "$md" "## 5. UFW firewall state"
    assert_file_contains "$md" "## 6. Listen-vs-UFW delta"
    assert_file_contains "$md" "## 11. Observability — New Relic"
}

@test "run-report: JSON sidecar is valid JSON" {
    run bash "$WRAPPED_SCRIPT"
    [ "$status" -eq 0 ]

    local json
    json=$(find "$DOCKERHOSTING_REPORT_DIR" -maxdepth 1 -name 'audit-report-*.log.json' | head -1)
    [ -f "$json" ]

    if command -v python3 > /dev/null 2>&1; then
        run python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$json"
        [ "$status" -eq 0 ]
    else
        head -1 "$json" | grep -q '^{'
        tail -1 "$json" | grep -q '^}$'
    fi
}

@test "run-report: flags listening port without a matching UFW rule" {
    run bash "$WRAPPED_SCRIPT"
    [ "$status" -eq 0 ]
    local md
    md=$(find "$DOCKERHOSTING_REPORT_DIR" -maxdepth 1 -name 'audit-report-*.log' | head -1)
    # ss mock returns port 9999 with no UFW allow rule (only 22 is allowed)
    assert_file_contains "$md" "9999"
    assert_file_contains "$md" "[MEDIUM]"
}

@test "run-report: includes New Relic detection section" {
    run bash "$WRAPPED_SCRIPT"
    [ "$status" -eq 0 ]
    local md
    md=$(find "$DOCKERHOSTING_REPORT_DIR" -maxdepth 1 -name 'audit-report-*.log' | head -1)
    assert_file_contains "$md" "Host-level New Relic"
    assert_file_contains "$md" "Container-level New Relic"
}
