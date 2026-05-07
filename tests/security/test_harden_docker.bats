#!/usr/bin/env bats
# Tests for scripts/harden-docker.sh (Docker daemon hardening)

load '../helpers/common'

setup() {
    setup_mocks

    # Override file paths for isolation
    export DOCKER_DAEMON_JSON="$BATS_TEST_TMPDIR/daemon.json"
    export DOCKER_DIR="$BATS_TEST_TMPDIR/docker"
    export SUBUID_FILE="$BATS_TEST_TMPDIR/subuid"
    export SUBGID_FILE="$BATS_TEST_TMPDIR/subgid"
    
    mkdir -p "$DOCKER_DIR"
    
    # Mock system commands
    create_mock "systemctl"
    create_mock "useradd"
    create_mock "id"  # default: dockremap user doesn't exist (exit 1)
    create_mock "date"
    
    # Mock sudo to just execute the command (script auto-elevates)
    create_mock_with_body "sudo" 'shift; exec "$@"'
    
    # Patch the script to use our overridden paths
    HARDEN_DOCKER_SCRIPT="$BATS_TEST_TMPDIR/harden-docker-patched.sh"
    sed \
        -e "s|/etc/docker/daemon.json|$DOCKER_DAEMON_JSON|g" \
        -e "s|/etc/subuid|$SUBUID_FILE|g" \
        -e "s|/etc/subgid|$SUBGID_FILE|g" \
        -e 's/if \[ "$EUID" -ne 0 \]/if false/' \
        "$SCRIPTS_DIR/harden-docker.sh" > "$HARDEN_DOCKER_SCRIPT"
    chmod +x "$HARDEN_DOCKER_SCRIPT"
}

teardown() {
    teardown_mocks
}

# ── daemon.json generation with correct structure ────────────────────────────

@test "harden-docker: creates daemon.json with valid JSON structure" {
    run bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    [ "$status" -eq 0 ]
    
    # Validate JSON syntax
    run python3 -m json.tool "$DOCKER_DAEMON_JSON"
    [ "$status" -eq 0 ]
}

@test "harden-docker: daemon.json contains all required security fields" {
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    
    assert_file_exists "$DOCKER_DAEMON_JSON"
    assert_file_contains "$DOCKER_DAEMON_JSON" '"log-driver"'
    assert_file_contains "$DOCKER_DAEMON_JSON" '"log-opts"'
    assert_file_contains "$DOCKER_DAEMON_JSON" '"icc"'
    assert_file_contains "$DOCKER_DAEMON_JSON" '"userland-proxy"'
    assert_file_contains "$DOCKER_DAEMON_JSON" '"live-restore"'
    assert_file_contains "$DOCKER_DAEMON_JSON" '"default-ulimits"'
    assert_file_contains "$DOCKER_DAEMON_JSON" '"storage-driver"'
}

@test "harden-docker: daemon.json uses overlay2 storage driver" {
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    assert_file_contains "$DOCKER_DAEMON_JSON" '"storage-driver": "overlay2"'
}

@test "harden-docker: daemon.json enables buildkit feature" {
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    assert_file_contains "$DOCKER_DAEMON_JSON" '"buildkit": true'
}

@test "harden-docker: daemon.json sets metrics address to localhost only" {
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    assert_file_contains "$DOCKER_DAEMON_JSON" '"metrics-addr": "127.0.0.1:9323"'
}

# ── icc=false configuration ───────────────────────────────────────────────────

@test "harden-docker: sets icc to false (disables inter-container communication)" {
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    assert_file_contains "$DOCKER_DAEMON_JSON" '"icc": false'
}

@test "harden-docker: disables userland-proxy for performance" {
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    assert_file_contains "$DOCKER_DAEMON_JSON" '"userland-proxy": false'
}

# ── log-driver and log-opts settings ──────────────────────────────────────────

@test "harden-docker: configures json-file log driver" {
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    assert_file_contains "$DOCKER_DAEMON_JSON" '"log-driver": "json-file"'
}

@test "harden-docker: sets log rotation max-size to 10m" {
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    assert_file_contains "$DOCKER_DAEMON_JSON" '"max-size": "10m"'
}

@test "harden-docker: sets log rotation max-file to 3" {
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    assert_file_contains "$DOCKER_DAEMON_JSON" '"max-file": "3"'
}

@test "harden-docker: includes production label in log-opts" {
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    assert_file_contains "$DOCKER_DAEMON_JSON" '"labels": "production"'
}

# ── userns-remap configuration (optional) ─────────────────────────────────────

@test "harden-docker: includes userns-remap when user answers yes" {
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "y"
    assert_file_contains "$DOCKER_DAEMON_JSON" '"userns-remap": "default"'
}

@test "harden-docker: omits userns-remap when user answers no" {
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    refute_file_contains "$DOCKER_DAEMON_JSON" '"userns-remap"'
}

@test "harden-docker: creates dockremap user when userns-remap enabled" {
    # Mock id to indicate dockremap doesn't exist
    create_mock_with_body "id" 'exit 1'
    
    # Log useradd calls
    local useradd_log="$BATS_TEST_TMPDIR/useradd.log"
    create_call_log_mock "useradd" "$useradd_log"
    
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "y"
    
    assert_file_exists "$useradd_log"
    assert_file_contains "$useradd_log" "dockremap"
    assert_file_contains "$useradd_log" "/usr/sbin/nologin"
}

@test "harden-docker: skips creating dockremap user if already exists" {
    # Mock id to indicate dockremap exists
    create_mock_with_body "id" 'exit 0'
    
    local useradd_log="$BATS_TEST_TMPDIR/useradd.log"
    create_call_log_mock "useradd" "$useradd_log"
    
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "y"
    
    # useradd should not be called
    [ ! -f "$useradd_log" ]
}

@test "harden-docker: adds dockremap to subuid when userns-remap enabled" {
    touch "$SUBUID_FILE"
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "y"
    
    assert_file_exists "$SUBUID_FILE"
    assert_file_contains "$SUBUID_FILE" "dockremap:100000:65536"
}

@test "harden-docker: adds dockremap to subgid when userns-remap enabled" {
    touch "$SUBGID_FILE"
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "y"
    
    assert_file_exists "$SUBGID_FILE"
    assert_file_contains "$SUBGID_FILE" "dockremap:100000:65536"
}

@test "harden-docker: skips duplicate subuid entry if already present" {
    echo "dockremap:100000:65536" > "$SUBUID_FILE"
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "y"
    
    # Count occurrences (should be exactly 1)
    local count
    count=$(grep -c "dockremap:100000:65536" "$SUBUID_FILE")
    [ "$count" -eq 1 ]
}

@test "harden-docker: skips duplicate subgid entry if already present" {
    echo "dockremap:100000:65536" > "$SUBGID_FILE"
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "y"
    
    local count
    count=$(grep -c "dockremap:100000:65536" "$SUBGID_FILE")
    [ "$count" -eq 1 ]
}

@test "harden-docker: does not create dockremap entries when userns-remap disabled" {
    touch "$SUBUID_FILE" "$SUBGID_FILE"
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    
    refute_file_contains "$SUBUID_FILE" "dockremap"
    refute_file_contains "$SUBGID_FILE" "dockremap"
}

# ── idempotency (safe to re-run) ──────────────────────────────────────────────

@test "harden-docker: skips hardening if already configured (no --force)" {
    # First run with --force to create config
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    
    # Second run without --force should skip
    run bash "$HARDEN_DOCKER_SCRIPT" <<< "n"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already hardened"* ]]
    [[ "$output" == *"--force to reconfigure"* ]]
}

@test "harden-docker: detects existing hardening by icc=false marker" {
    # Create pre-hardened daemon.json
    cat > "$DOCKER_DAEMON_JSON" <<'EOF'
{
  "icc": false,
  "log-driver": "json-file"
}
EOF
    
    run bash "$HARDEN_DOCKER_SCRIPT" <<< "n"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already hardened"* ]]
}

@test "harden-docker: proceeds if daemon.json missing (first run)" {
    run bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    [ "$status" -eq 0 ]
    [[ "$output" != *"already hardened"* ]]
    assert_file_exists "$DOCKER_DAEMON_JSON"
}

# ── --force flag to reconfigure ──────────────────────────────────────────────

@test "harden-docker: --force bypasses idempotency check" {
    # First run
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    
    # Second run with --force should proceed, not skip
    run bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    [ "$status" -eq 0 ]
    [[ "$output" != *"already hardened"* ]]
    [[ "$output" == *"Hardening Docker daemon"* ]]
}

@test "harden-docker: --force can switch from non-userns to userns config" {
    # First run without userns-remap
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    refute_file_contains "$DOCKER_DAEMON_JSON" '"userns-remap"'
    
    # Second run with --force and yes to userns
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "y"
    assert_file_contains "$DOCKER_DAEMON_JSON" '"userns-remap": "default"'
}

@test "harden-docker: --force can switch from userns to non-userns config" {
    # First run with userns-remap
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "y"
    assert_file_contains "$DOCKER_DAEMON_JSON" '"userns-remap": "default"'
    
    # Second run with --force and no to userns
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    refute_file_contains "$DOCKER_DAEMON_JSON" '"userns-remap"'
}

# ── daemon.json backup ────────────────────────────────────────────────────────

@test "harden-docker: backs up existing daemon.json before modification" {
    # Create existing daemon.json
    cat > "$DOCKER_DAEMON_JSON" <<'EOF'
{
  "log-driver": "syslog"
}
EOF
    
    # Mock date to return predictable timestamp
    create_mock_with_body "date" 'echo "20250507-120000"'
    
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    
    # Check backup exists
    assert_file_exists "${DOCKER_DAEMON_JSON}.backup.20250507-120000"
    assert_file_contains "${DOCKER_DAEMON_JSON}.backup.20250507-120000" '"log-driver": "syslog"'
}

@test "harden-docker: does not fail if daemon.json doesn't exist (first run)" {
    [ ! -f "$DOCKER_DAEMON_JSON" ]
    
    run bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    [ "$status" -eq 0 ]
    assert_file_exists "$DOCKER_DAEMON_JSON"
}

# ── Docker service restart logic ──────────────────────────────────────────────

@test "harden-docker: restarts Docker service after configuration" {
    local systemctl_log="$BATS_TEST_TMPDIR/systemctl.log"
    create_call_log_mock "systemctl" "$systemctl_log"
    
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    
    assert_file_exists "$systemctl_log"
    assert_file_contains "$systemctl_log" "restart docker"
}

@test "harden-docker: creates minimal fallback config if hardened restart fails" {
    # Mock systemctl to fail on first call, succeed on second
    create_mock_with_body "systemctl" '
if [ ! -f "$BATS_TEST_TMPDIR/restart_attempt" ]; then
    touch "$BATS_TEST_TMPDIR/restart_attempt"
    exit 1
else
    exit 0
fi
'
    
    # Mock journalctl to prevent errors
    create_mock "journalctl"
    
    run bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    [ "$status" -eq 0 ]
    [[ "$output" == *"fallback"* ]]
    
    # Check fallback config doesn't have hardening features
    refute_file_contains "$DOCKER_DAEMON_JSON" '"icc": false'
    assert_file_contains "$DOCKER_DAEMON_JSON" '"live-restore": true'
}

@test "harden-docker: exits with error if even fallback config fails" {
    # Mock systemctl to always fail
    create_mock_with_body "systemctl" 'exit 1'
    create_mock "journalctl"
    
    run bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Even minimal configuration failed"* ]]
}

@test "harden-docker: shows journalctl logs when fallback config fails" {
    create_mock_with_body "systemctl" 'exit 1'
    
    local journalctl_log="$BATS_TEST_TMPDIR/journalctl.log"
    create_call_log_mock "journalctl" "$journalctl_log"
    
    run bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    [ "$status" -eq 1 ]
    
    assert_file_exists "$journalctl_log"
    assert_file_contains "$journalctl_log" "docker.service"
}

# ── resource limits ───────────────────────────────────────────────────────────

@test "harden-docker: configures nofile ulimit to 64000" {
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    assert_file_contains "$DOCKER_DAEMON_JSON" '"Hard": 64000'
    assert_file_contains "$DOCKER_DAEMON_JSON" '"Soft": 64000'
}

@test "harden-docker: sets default shared memory size to 64M" {
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    assert_file_contains "$DOCKER_DAEMON_JSON" '"default-shm-size": "64M"'
}

@test "harden-docker: uses systemd cgroup driver" {
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    assert_file_contains "$DOCKER_DAEMON_JSON" '"exec-opts": ["native.cgroupdriver=systemd"]'
}

# ── security configuration ────────────────────────────────────────────────────

@test "harden-docker: disables SELinux (compatibility with non-SELinux systems)" {
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    assert_file_contains "$DOCKER_DAEMON_JSON" '"selinux-enabled": false'
}

@test "harden-docker: disables experimental features" {
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    assert_file_contains "$DOCKER_DAEMON_JSON" '"experimental": false'
}

@test "harden-docker: disables debug mode" {
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    assert_file_contains "$DOCKER_DAEMON_JSON" '"debug": false'
}

@test "harden-docker: enables live-restore for container persistence" {
    bash "$HARDEN_DOCKER_SCRIPT" --force <<< "n"
    assert_file_contains "$DOCKER_DAEMON_JSON" '"live-restore": true'
}
