#!/usr/bin/env bats
# Tests for scripts/run-report.sh — passive host audit report generator
#
# Characterization tests: capture current behavior so future changes
# can't silently drift the script's contract. Specifically pin down:
#   - audit reports land in /var/log/dockerHosting/audit-reports/
#     (overridable via DOCKERHOSTING_REPORT_DIR)
#   - JSON sidecar is well-formed JSON (validated with python3 json.load)
#   - JSON string fields escape via python3 json.dumps (not bash O(n²))
#   - root-only execution gate
#   - every section emits to both .log and .log.json
#   - missing external commands (docker, ufw, apt, etc) degrade gracefully
#
# All external commands are mocked. The script is patched to drop the
# EUID root check so it can run under bats.

load 'helpers/common'

SCRIPT="$SCRIPTS_DIR/run-report.sh"

setup() {
    setup_mocks

    # Isolate report output under the per-test tmpdir.
    export DOCKERHOSTING_REPORT_DIR="$BATS_TEST_TMPDIR/audit-reports"

    # ── mock every external command run-report.sh shells out to ──────────
    # Hostname/time
    create_mock_with_body "hostname" '
case "$1" in
    -s) echo "test-host" ;;
    *)  echo "test-host.example.com" ;;
esac
'
    create_mock_with_body "uname" '
case "$1" in
    -r) echo "6.1.0-test" ;;
    -a) echo "Linux test-host 6.1.0-test #1 SMP x86_64 GNU/Linux" ;;
    *)  echo "Linux" ;;
esac
'
    create_mock_with_body "hostnamectl" 'echo "Static hostname: test-host"'
    create_mock_with_body "chronyc" 'echo "Reference ID    : 0.0.0.0 (mock)"'
    create_mock_with_body "uptime" 'echo "up 1 hour, 23 minutes"'
    create_mock_with_body "uname" 'case "$1" in -r) echo 6.1.0-test ;; -a) echo "Linux test-host 6.1.0-test"  ;; *) echo Linux ;; esac'

    # apt / dpkg
    create_mock_with_body "apt" '
if [ "$1" = list ]; then
    echo "Listing..."
    echo "foo/stable 1.2.3 amd64 [upgradable]"
fi
'
    create_mock_with_body "apt-get" 'exit 0'
    create_mock_with_body "dpkg" '
if [ "$1" = -l ]; then
    echo "ii  linux-image-6.1.0-test  6.1.0-1  amd64"
fi
'

    # Distro / CVEs
    create_mock_with_body "lsb_release" 'echo trixie'
    create_mock_with_body "debsecan" 'echo "(no vulnerabilities)"'

    # Docker (no running containers by default — keeps tests deterministic)
    create_mock_with_body "docker" '
case "$1 $2" in
    "ps -q")        : ;;                # zero containers
    "ps --format")  : ;;                # zero containers
    "inspect -f")   echo "" ;;
    *)              : ;;
esac
exit 0
'

    # UFW / sockets
    create_mock_with_body "ufw" '
case "$2" in
    verbose)  echo "Status: active"; echo "Default: deny (incoming)" ;;
    numbered) echo "Status: active" ;;
    *)        echo "Status: active" ;;
esac
'
    create_mock_with_body "ss" 'echo ""'  # no listening sockets

    # journalctl / fail2ban
    create_mock_with_body "journalctl" 'exit 0'
    create_mock_with_body "fail2ban-client" 'echo "(jail not configured)"'

    # systemctl: mark fail2ban/newrelic/auditd inactive by default
    create_mock_with_body "systemctl" '
case "$*" in
    *"is-active --quiet"*) exit 1 ;;     # any service: inactive
    *"is-active"*)         echo inactive ;;
    *"list-unit-files"*)   echo "" ;;
    *)                     exit 0 ;;
esac
'

    # Hardening checks
    create_mock_with_body "aa-status" '
case "$1" in
    --summary) echo "apparmor module is loaded." ;;
    --enabled) exit 1 ;;                 # off by default
esac
'
    create_mock_with_body "sshd" '
if [ "$1" = -T ]; then
    echo "permitrootlogin no"
    echo "passwordauthentication no"
    echo "maxauthtries 3"
fi
'

    # Tail / find / sort / awk / grep / sed must remain the real system commands —
    # the test helpers below (_latest_md / _latest_json) pipe through `tail -n 1`,
    # so we cannot shadow it with a mock. journalctl is already mocked to exit 0,
    # so the script's `journalctl | tail` reads an empty stream.

    # Patch the script to drop the EUID root check so it runs under bats.
    PATCHED_SCRIPT="$BATS_TEST_TMPDIR/run-report-patched.sh"
    sed 's/if \[ "\$EUID" -ne 0 \]/if false/' "$SCRIPT" > "$PATCHED_SCRIPT"
    chmod +x "$PATCHED_SCRIPT"
}

teardown() {
    teardown_mocks
}

# Helper: locate the .log and .log.json the script produced.
_latest_md() {
    find "$DOCKERHOSTING_REPORT_DIR" -name 'audit-report-*.log' -not -name '*.json' | sort | tail -n 1
}
_latest_json() {
    find "$DOCKERHOSTING_REPORT_DIR" -name 'audit-report-*.log.json' | sort | tail -n 1
}

# ── basic execution ──────────────────────────────────────────────────────────

@test "run-report: exits 0 on success" {
    run bash "$PATCHED_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "run-report: prints Report complete on success" {
    run bash "$PATCHED_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Report complete"* ]]
}

@test "run-report: prints JSON sidecar path on success" {
    run bash "$PATCHED_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"JSON sidecar"* ]]
}

# ── root-only execution gate ─────────────────────────────────────────────────

@test "run-report: refuses to run as non-root (EUID != 0)" {
    # Unpatched script: EUID is non-zero under bats, so it must abort.
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be run as root"* ]]
}

# ── output location: /var/log/dockerHosting/audit-reports/ ───────────────────

@test "run-report: default REPORT_DIR is /var/log/dockerHosting/audit-reports" {
    # Inspect the script directly — characterization of the default.
    run grep -E '^REPORT_DIR=' "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/var/log/dockerHosting/audit-reports"* ]]
}

@test "run-report: creates REPORT_DIR if missing" {
    [ ! -d "$DOCKERHOSTING_REPORT_DIR" ]
    bash "$PATCHED_SCRIPT"
    [ -d "$DOCKERHOSTING_REPORT_DIR" ]
}

@test "run-report: writes audit-report-<host>-<ts>.log under REPORT_DIR" {
    bash "$PATCHED_SCRIPT"
    local md
    md=$(_latest_md)
    [ -n "$md" ]
    [ -f "$md" ]
    # filename pattern: audit-report-<host>-<UTC-stamp>.log
    [[ "$(basename "$md")" =~ ^audit-report-test-host-[0-9]{8}T[0-9]{6}Z\.log$ ]]
}

@test "run-report: writes JSON sidecar alongside the .log" {
    bash "$PATCHED_SCRIPT"
    local json
    json=$(_latest_json)
    [ -n "$json" ]
    [ -f "$json" ]
    [[ "$(basename "$json")" =~ ^audit-report-test-host-[0-9]{8}T[0-9]{6}Z\.log\.json$ ]]
}

@test "run-report: report paths live under the audit-reports/ subdirectory" {
    bash "$PATCHED_SCRIPT"
    local md
    md=$(_latest_md)
    [[ "$md" == *"/audit-reports/"* ]]
}

# ── Markdown report content ──────────────────────────────────────────────────

@test "run-report: Markdown report has the header" {
    bash "$PATCHED_SCRIPT"
    assert_file_contains "$(_latest_md)" "# dockerHosting Audit Report"
}

@test "run-report: Markdown report cites NIST SP 800-115" {
    bash "$PATCHED_SCRIPT"
    assert_file_contains "$(_latest_md)" "NIST SP 800-115"
}

@test "run-report: Markdown report includes the host line" {
    bash "$PATCHED_SCRIPT"
    assert_file_contains "$(_latest_md)" "- Host: test-host"
}

# ── every numbered section is emitted to Markdown ────────────────────────────

@test "run-report: emits section 1 Host identity" {
    bash "$PATCHED_SCRIPT"
    assert_file_contains "$(_latest_md)" "## 1. Host identity"
}

@test "run-report: emits section 2 Patch level" {
    bash "$PATCHED_SCRIPT"
    assert_file_contains "$(_latest_md)" "## 2. Patch level"
}

@test "run-report: emits section 3 Host CVEs" {
    bash "$PATCHED_SCRIPT"
    assert_file_contains "$(_latest_md)" "## 3. Host CVEs"
}

@test "run-report: emits section 4 Container image CVEs" {
    bash "$PATCHED_SCRIPT"
    assert_file_contains "$(_latest_md)" "## 4. Container image CVEs"
}

@test "run-report: emits section 5 UFW firewall state" {
    bash "$PATCHED_SCRIPT"
    assert_file_contains "$(_latest_md)" "## 5. UFW firewall state"
}

@test "run-report: emits section 6 Listen-vs-UFW delta" {
    bash "$PATCHED_SCRIPT"
    assert_file_contains "$(_latest_md)" "## 6. Listen-vs-UFW delta"
}

@test "run-report: emits section 7 Running containers" {
    bash "$PATCHED_SCRIPT"
    assert_file_contains "$(_latest_md)" "## 7. Running containers"
}

@test "run-report: emits section 8 Traefik dynamic routes" {
    bash "$PATCHED_SCRIPT"
    assert_file_contains "$(_latest_md)" "## 8. Traefik dynamic routes"
}

@test "run-report: emits section 9 Failed authentication" {
    bash "$PATCHED_SCRIPT"
    assert_file_contains "$(_latest_md)" "## 9. Failed authentication (24h)"
}

@test "run-report: emits section 10 Hardening posture" {
    bash "$PATCHED_SCRIPT"
    assert_file_contains "$(_latest_md)" "## 10. Hardening posture"
}

@test "run-report: emits section 11 Observability" {
    bash "$PATCHED_SCRIPT"
    assert_file_contains "$(_latest_md)" "## 11. Observability"
}

# ── JSON sidecar well-formedness ─────────────────────────────────────────────

@test "run-report: JSON sidecar parses as valid JSON" {
    bash "$PATCHED_SCRIPT"
    run python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$(_latest_json)"
    [ "$status" -eq 0 ]
}

@test "run-report: JSON sidecar has host and generated_utc keys" {
    bash "$PATCHED_SCRIPT"
    run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert "host" in d, "missing host"
assert "generated_utc" in d, "missing generated_utc"
assert d["host"] == "test-host", d["host"]
' "$(_latest_json)"
    [ "$status" -eq 0 ]
}

@test "run-report: JSON sidecar contains all 11 numbered sections" {
    bash "$PATCHED_SCRIPT"
    run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for n in (1,2,3,4,5,6,7,8,9,10,11):
    k = "section_%d" % n
    assert k in d, "missing " + k
    assert "title" in d[k]
    assert "summary" in d[k]
    assert "body" in d[k]
' "$(_latest_json)"
    [ "$status" -eq 0 ]
}

@test "run-report: JSON section bodies are strings (json.dumps-escaped)" {
    bash "$PATCHED_SCRIPT"
    run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for k, v in d.items():
    if not k.startswith("section_"): continue
    assert isinstance(v["body"], str), k
    assert isinstance(v["title"], str), k
    assert isinstance(v["summary"], str), k
' "$(_latest_json)"
    [ "$status" -eq 0 ]
}

# ── _json_escape uses python3 json.dumps (commit 6fea571) ────────────────────

@test "run-report: _json_escape implementation invokes python3 json.dumps" {
    # Characterize the source: must use python3 json.dumps, not bash ${//}.
    run grep -E "json\.dumps" "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"json.dumps"* ]]
}

@test "run-report: _json_escape correctly escapes embedded quotes and backslashes" {
    # Make a section body contain characters that would break naive bash escape.
    # Use docker mock to inject a payload with quotes, backslashes, newlines.
    create_mock_with_body "docker" '
case "$1 $2" in
    "ps --format")
        # one running container with a tricky name
        if [ "$3" = "{{.Image}}" ]; then
            echo "img:latest"
        elif [ "$3" = "{{.Names}}" ]; then
            printf "tricky\\n"
        fi
        ;;
    "ps -q") echo "abc123" ;;
    "inspect -f")
        # body containing quote, backslash, newline
        printf "value\\\"with\\\\backslash\\nand newline"
        ;;
esac
exit 0
'
    # scan-image.sh should also be mocked since docker ps now lists images
    mkdir -p "$BATS_TEST_TMPDIR/fakescripts"
    bash "$PATCHED_SCRIPT"

    # The JSON must still parse — that's the whole point of json.dumps.
    run python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$(_latest_json)"
    [ "$status" -eq 0 ]
}

# ── degradation when external tools are missing ──────────────────────────────

@test "run-report: succeeds when docker is unavailable" {
    rm -f "$MOCK_BIN/docker"
    run bash "$PATCHED_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "run-report: succeeds when ufw is unavailable" {
    rm -f "$MOCK_BIN/ufw"
    run bash "$PATCHED_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "run-report: succeeds when chronyc is unavailable" {
    rm -f "$MOCK_BIN/chronyc"
    run bash "$PATCHED_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "run-report: succeeds when aa-status is unavailable" {
    rm -f "$MOCK_BIN/aa-status"
    run bash "$PATCHED_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "run-report: succeeds when sshd is unavailable" {
    rm -f "$MOCK_BIN/sshd"
    run bash "$PATCHED_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "run-report: succeeds when journalctl is unavailable" {
    rm -f "$MOCK_BIN/journalctl"
    run bash "$PATCHED_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "run-report: succeeds when debsecan is unavailable" {
    rm -f "$MOCK_BIN/debsecan"
    run bash "$PATCHED_SCRIPT"
    [ "$status" -eq 0 ]
}

# ── auto-install of debsecan ─────────────────────────────────────────────────

@test "run-report: attempts apt-get install of debsecan when missing" {
    rm -f "$MOCK_BIN/debsecan"
    local apt_log="$BATS_TEST_TMPDIR/apt_get.log"
    create_call_log_mock "apt-get" "$apt_log"

    bash "$PATCHED_SCRIPT"

    assert_file_exists "$apt_log"
    assert_file_contains "$apt_log" "debsecan"
}

@test "run-report: does NOT install debsecan when already on PATH" {
    local apt_log="$BATS_TEST_TMPDIR/apt_get.log"
    create_call_log_mock "apt-get" "$apt_log"

    bash "$PATCHED_SCRIPT"

    [ ! -s "$apt_log" ] || ! grep -q "debsecan" "$apt_log"
}

# ── traefik section path-skipping ────────────────────────────────────────────

@test "run-report: section 8 reports 'no /etc/traefik/dynamic directory' on hosts without it" {
    # /etc/traefik/dynamic almost certainly doesn't exist in test env.
    if [ -d /etc/traefik/dynamic ]; then skip "real /etc/traefik/dynamic present"; fi
    bash "$PATCHED_SCRIPT"
    assert_file_contains "$(_latest_md)" "no /etc/traefik/dynamic"
}

# ── containers section with zero running containers ──────────────────────────

@test "run-report: section 4 reports no running containers when docker ps is empty" {
    bash "$PATCHED_SCRIPT"
    assert_file_contains "$(_latest_md)" "no running containers"
}

@test "run-report: section 7 summary says '0 running container(s)' when none" {
    bash "$PATCHED_SCRIPT"
    assert_file_contains "$(_latest_md)" "0 running container(s)"
}

# ── observability / New Relic section ────────────────────────────────────────

@test "run-report: section 11 reports host=absent when New Relic not installed" {
    bash "$PATCHED_SCRIPT"
    assert_file_contains "$(_latest_md)" "host=absent"
}

@test "run-report: section 11 reports containers=0 when no New Relic containers" {
    bash "$PATCHED_SCRIPT"
    assert_file_contains "$(_latest_md)" "containers=0"
}

# ── permissions / chmod on output ────────────────────────────────────────────

@test "run-report: chmods report files to 0640 (best effort)" {
    bash "$PATCHED_SCRIPT"
    local md
    md=$(_latest_md)
    [ -f "$md" ]
    # Just sanity-check perms reflect what chmod 0640 produces on a regular file.
    # We can't always assert 640 exactly (umask, FS), so we assert *not* world-writable.
    local perms
    perms=$(stat -f '%Lp' "$md" 2>/dev/null || stat -c '%a' "$md" 2>/dev/null)
    [ -n "$perms" ]
    # No world-write bit (bit 2).
    [ $((perms & 2)) -eq 0 ]
}

# ── characterization: section_*  list matches _run_sections call list ────────

@test "run-report: _run_sections invokes all 11 section_* functions" {
    # Extract calls between _run_sections opening and closing brace.
    run bash -c "awk '/^_run_sections\\(\\)/{flag=1} flag{print} /^}/ && flag{flag=0}' '$SCRIPT' | grep -cE '^[[:space:]]+section_'"
    [ "$status" -eq 0 ]
    [ "$output" -eq 11 ]
}

# ── characterization: section_host_cves still calls _ensure_debsecan ─────────

@test "run-report: section_host_cves invokes _ensure_debsecan" {
    run grep -A1 'section_host_cves()' "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"_ensure_debsecan"* ]]
}

# ── logrotate config: created when /etc/logrotate.d is writable ──────────────

@test "run-report: _ensure_logrotate config block references audit-reports path" {
    run grep -E '/var/log/dockerHosting/audit-reports' "$SCRIPT"
    [ "$status" -eq 0 ]
    # Should appear at least twice: REPORT_DIR default + logrotate config (.log + .log.json lines)
    [ "$(grep -c '/var/log/dockerHosting/audit-reports' "$SCRIPT")" -ge 2 ]
}
