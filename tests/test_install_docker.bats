#!/usr/bin/env bats
# Tests for scripts/install-docker.sh
# Covers Docker installation, GPG verification, idempotency, and error handling.

load 'helpers/common'

setup() {
    setup_mocks

    # Mock all system commands used by install-docker.sh
    create_mock "apt-get"
    create_mock "curl"
    create_mock "install"
    create_mock "chmod"
    create_mock "dpkg"
    create_mock "tee"
    create_mock "systemctl"
    create_mock "usermod"
    create_mock "mkdir"
    create_mock "cat"
    create_mock "lsb_release"

    # Mock docker and docker compose to not exist by default
    create_mock_with_body "command" 'exit 1'

    # Create temp directories for simulated system paths
    export ETC_APT_KEYRINGS="$BATS_TEST_TMPDIR/etc/apt/keyrings"
    export ETC_APT_SOURCES="$BATS_TEST_TMPDIR/etc/apt/sources.list.d"
    export ETC_SYSTEMD="$BATS_TEST_TMPDIR/etc/systemd/system"
    mkdir -p "$ETC_APT_KEYRINGS" "$ETC_APT_SOURCES" "$ETC_SYSTEMD"

    # Track calls
    APT_LOG="$BATS_TEST_TMPDIR/apt.log"
    CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
    SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    USERMOD_LOG="$BATS_TEST_TMPDIR/usermod.log"
}

teardown() {
    teardown_mocks
}

# ── Idempotency: Docker already installed ─────────────────────────────────────

@test "install-docker: skips installation when Docker is already present and running" {
    # Mock docker command to exist and systemctl to show docker active
    create_mock_with_body "command" 'exit 0'
    create_mock_with_body "docker" 'echo "Docker version 24.0.0"; exit 0'
    create_mock_with_body "systemctl" '[[ "$*" == *"is-active"* ]] && exit 0 || exit 1'

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
    [[ "$output" == *"skipping"* ]]
}

@test "install-docker: reinstalls when --force flag is provided" {
    # Docker exists but --force should trigger reinstall
    create_mock_with_body "command" 'exit 0'
    create_mock_with_body "docker" 'echo "Docker version 24.0.0"; exit 0'
    create_mock_with_body "systemctl" 'exit 0'
    create_call_log_mock "apt-get" "$APT_LOG"

    run bash "$SCRIPTS_DIR/install-docker.sh" --force
    [ "$status" -eq 0 ]
    [ -f "$APT_LOG" ]
    grep -q "update" "$APT_LOG"
}

# ── GPG key download and verification ─────────────────────────────────────────

@test "install-docker: downloads Docker GPG key with curl" {
    create_call_log_mock "curl" "$CURL_LOG"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [ -f "$CURL_LOG" ]
    grep -q "https://download.docker.com/linux/debian/gpg" "$CURL_LOG"
}

@test "install-docker: creates /etc/apt/keyrings directory with correct permissions" {
    local install_log="$BATS_TEST_TMPDIR/install.log"
    create_call_log_mock "install" "$install_log"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [ -f "$install_log" ]
    grep -q "\-m 0755 \-d" "$install_log"
    grep -q "/etc/apt/keyrings" "$install_log"
}

@test "install-docker: sets GPG key file to readable by all" {
    local chmod_log="$BATS_TEST_TMPDIR/chmod.log"
    create_call_log_mock "chmod" "$chmod_log"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [ -f "$chmod_log" ]
    grep -q "a+r /etc/apt/keyrings/docker.asc" "$chmod_log"
}

@test "install-docker: fails when curl cannot download GPG key" {
    create_mock_with_body "curl" 'exit 1'

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -ne 0 ]
}

# ── Docker repository addition ────────────────────────────────────────────────

@test "install-docker: adds Docker repository to apt sources" {
    create_call_log_mock "tee" "$BATS_TEST_TMPDIR/tee.log"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [ -f "$BATS_TEST_TMPDIR/tee.log" ]
    grep -q "/etc/apt/sources.list.d/docker.list" "$BATS_TEST_TMPDIR/tee.log"
}

@test "install-docker: repository source includes correct architecture" {
    create_mock_with_body "dpkg" 'echo "amd64"'
    create_mock_with_body "tee" 'cat; exit 0'

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"arch=amd64"* ]] || [[ "$output" == *"arch=$(dpkg --print-architecture)"* ]]
}

@test "install-docker: repository source includes signed-by keyring" {
    create_mock_with_body "tee" 'cat; exit 0'

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"signed-by=/etc/apt/keyrings/docker.asc"* ]]
}

# ── Package installation ──────────────────────────────────────────────────────

@test "install-docker: installs prerequisite packages" {
    create_call_log_mock "apt-get" "$APT_LOG"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [ -f "$APT_LOG" ]
    grep -q "ca-certificates" "$APT_LOG"
    grep -q "curl" "$APT_LOG"
    grep -q "gnupg" "$APT_LOG"
    grep -q "lsb-release" "$APT_LOG"
}

@test "install-docker: installs docker-ce package" {
    create_call_log_mock "apt-get" "$APT_LOG"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [ -f "$APT_LOG" ]
    grep -q "docker-ce" "$APT_LOG"
}

@test "install-docker: installs docker-ce-cli package" {
    create_call_log_mock "apt-get" "$APT_LOG"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [ -f "$APT_LOG" ]
    grep -q "docker-ce-cli" "$APT_LOG"
}

@test "install-docker: installs containerd.io package" {
    create_call_log_mock "apt-get" "$APT_LOG"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [ -f "$APT_LOG" ]
    grep -q "containerd.io" "$APT_LOG"
}

@test "install-docker: installs docker-buildx-plugin" {
    create_call_log_mock "apt-get" "$APT_LOG"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [ -f "$APT_LOG" ]
    grep -q "docker-buildx-plugin" "$APT_LOG"
}

@test "install-docker: installs docker-compose-plugin" {
    create_call_log_mock "apt-get" "$APT_LOG"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [ -f "$APT_LOG" ]
    grep -q "docker-compose-plugin" "$APT_LOG"
}

@test "install-docker: runs apt-get update before installing packages" {
    create_call_log_mock "apt-get" "$APT_LOG"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [ -f "$APT_LOG" ]
    # First apt-get call should be update
    head -n 1 "$APT_LOG" | grep -q "update"
}

@test "install-docker: runs apt-get update after adding Docker repository" {
    create_call_log_mock "apt-get" "$APT_LOG"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [ -f "$APT_LOG" ]
    # Should have multiple update calls
    [ "$(grep -c "update" "$APT_LOG")" -ge 2 ]
}

@test "install-docker: fails when apt-get fails to install packages" {
    create_mock_with_body "apt-get" '
        if [[ "$*" == *"docker-ce"* ]]; then
            echo "E: Unable to locate package docker-ce" >&2
            exit 100
        fi
        exit 0
    '

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -ne 0 ]
}

# ── Docker Compose handling ───────────────────────────────────────────────────

@test "install-docker: removes old docker-compose package if present" {
    create_mock_with_body "dpkg" '
        if [[ "$*" == *"-l"* ]]; then
            echo "ii  docker-compose  1.29.2-1  all  old compose"
            exit 0
        fi
    '
    create_call_log_mock "apt-get" "$APT_LOG"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [ -f "$APT_LOG" ]
    grep -q "remove.*docker-compose" "$APT_LOG"
}

@test "install-docker: does not attempt to remove docker-compose if not installed" {
    create_mock_with_body "dpkg" 'exit 0'
    create_call_log_mock "apt-get" "$APT_LOG"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [ -f "$APT_LOG" ]
    ! grep -q "remove.*docker-compose" "$APT_LOG"
}

# ── Systemd resource limits ───────────────────────────────────────────────────

@test "install-docker: creates docker.service.d override directory" {
    local mkdir_log="$BATS_TEST_TMPDIR/mkdir.log"
    create_call_log_mock "mkdir" "$mkdir_log"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [ -f "$mkdir_log" ]
    grep -q "/etc/systemd/system/docker.service.d" "$mkdir_log"
}

@test "install-docker: creates containerd.service.d override directory" {
    local mkdir_log="$BATS_TEST_TMPDIR/mkdir.log"
    create_call_log_mock "mkdir" "$mkdir_log"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [ -f "$mkdir_log" ]
    grep -q "/etc/systemd/system/containerd.service.d" "$mkdir_log"
}

@test "install-docker: sets CPU and IO weight to 20 for docker service" {
    local cat_log="$BATS_TEST_TMPDIR/cat.log"
    create_call_log_mock "cat" "$cat_log"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CPUWeight=20"* ]]
    [[ "$output" == *"IOWeight=20"* ]]
}

@test "install-docker: runs systemctl daemon-reload after creating overrides" {
    create_call_log_mock "systemctl" "$SYSTEMCTL_LOG"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [ -f "$SYSTEMCTL_LOG" ]
    grep -q "daemon-reload" "$SYSTEMCTL_LOG"
}

# ── Docker service management ─────────────────────────────────────────────────

@test "install-docker: starts docker service" {
    create_call_log_mock "systemctl" "$SYSTEMCTL_LOG"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [ -f "$SYSTEMCTL_LOG" ]
    grep -q "start docker" "$SYSTEMCTL_LOG"
}

@test "install-docker: enables docker service" {
    create_call_log_mock "systemctl" "$SYSTEMCTL_LOG"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [ -f "$SYSTEMCTL_LOG" ]
    grep -q "enable docker" "$SYSTEMCTL_LOG"
}

@test "install-docker: restarts docker service after configuration" {
    create_call_log_mock "systemctl" "$SYSTEMCTL_LOG"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [ -f "$SYSTEMCTL_LOG" ]
    grep -q "restart docker" "$SYSTEMCTL_LOG"
}

@test "install-docker: service operations occur in correct order" {
    create_call_log_mock "systemctl" "$SYSTEMCTL_LOG"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [ -f "$SYSTEMCTL_LOG" ]
    
    # daemon-reload should come before start
    local reload_line start_line
    reload_line=$(grep -n "daemon-reload" "$SYSTEMCTL_LOG" | head -n1 | cut -d: -f1)
    start_line=$(grep -n "start docker" "$SYSTEMCTL_LOG" | head -n1 | cut -d: -f1)
    [ "$reload_line" -lt "$start_line" ]
}

# ── User addition to docker group ─────────────────────────────────────────────

@test "install-docker: adds SUDO_USER to docker group when present" {
    export SUDO_USER="testuser"
    create_call_log_mock "usermod" "$USERMOD_LOG"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [ -f "$USERMOD_LOG" ]
    grep -q "\-aG docker testuser" "$USERMOD_LOG"
}

@test "install-docker: does not run usermod when SUDO_USER is not set" {
    unset SUDO_USER
    create_call_log_mock "usermod" "$USERMOD_LOG"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    ! [ -f "$USERMOD_LOG" ]
}

@test "install-docker: does not run usermod when SUDO_USER is empty" {
    export SUDO_USER=""
    create_call_log_mock "usermod" "$USERMOD_LOG"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    ! [ -f "$USERMOD_LOG" ]
}

@test "install-docker: prints confirmation message when user is added to docker group" {
    export SUDO_USER="testuser"
    create_mock "usermod"

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Added testuser to docker group"* ]]
}

# ── Error handling ────────────────────────────────────────────────────────────

@test "install-docker: fails fast with set -e on any command failure" {
    # Verify script uses set -e
    run grep -q "^set -e" "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
}

@test "install-docker: exits non-zero when curl fails" {
    create_mock_with_body "curl" 'echo "curl: error" >&2; exit 7'

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -ne 0 ]
}

@test "install-docker: exits non-zero when systemctl start fails" {
    create_mock_with_body "systemctl" '
        if [[ "$*" == *"start docker"* ]]; then
            echo "Failed to start docker.service" >&2
            exit 1
        fi
        exit 0
    '

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -ne 0 ]
}

@test "install-docker: exits non-zero when systemctl enable fails" {
    create_mock_with_body "systemctl" '
        if [[ "$*" == *"enable docker"* ]]; then
            echo "Failed to enable docker.service" >&2
            exit 1
        fi
        exit 0
    '

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -ne 0 ]
}

@test "install-docker: exits non-zero when usermod fails" {
    export SUDO_USER="testuser"
    create_mock_with_body "usermod" 'echo "usermod: user not found" >&2; exit 6'

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -ne 0 ]
}

# ── Installation verification ─────────────────────────────────────────────────

@test "install-docker: prints Docker installation complete message" {
    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Docker installation complete"* ]]
}

@test "install-docker: runs docker --version after installation" {
    create_mock_with_body "docker" '
        if [[ "$*" == "--version" ]]; then
            echo "Docker version 24.0.7, build afdd53b"
            exit 0
        fi
        exit 1
    '

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Docker version"* ]]
}

@test "install-docker: runs docker compose version after installation" {
    create_mock_with_body "docker" '
        if [[ "$*" == "compose version" ]]; then
            echo "Docker Compose version v2.23.3"
            exit 0
        elif [[ "$*" == "--version" ]]; then
            echo "Docker version 24.0.7, build afdd53b"
            exit 0
        fi
        exit 1
    '

    run bash "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Docker Compose version"* ]]
}

# ── PATH configuration ────────────────────────────────────────────────────────

@test "install-docker: exports PATH with standard system directories" {
    run grep -q 'export PATH=' "$SCRIPTS_DIR/install-docker.sh"
    [ "$status" -eq 0 ]
}

@test "install-docker: PATH includes /usr/local/sbin and /usr/sbin" {
    local path_line
    path_line=$(grep 'export PATH=' "$SCRIPTS_DIR/install-docker.sh")
    [[ "$path_line" == *"/usr/local/sbin"* ]]
    [[ "$path_line" == *"/usr/sbin"* ]]
}
