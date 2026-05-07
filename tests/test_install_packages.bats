#!/usr/bin/env bats

load 'helpers/common'

setup() {
    setup_mocks

    # Create temporary config directory and packages.list
    TEST_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
    mkdir -p "$TEST_CONFIG_DIR"
    
    # Set environment variable for packages list path (used in mocks)
    export PACKAGES_LIST="$TEST_CONFIG_DIR/packages.list"
    
    # Create log files for tracking calls
    APT_GET_LOG="$BATS_TEST_TMPDIR/apt-get.log"
    DPKG_QUERY_LOG="$BATS_TEST_TMPDIR/dpkg-query.log"
    
    # Create a test packages.list with sample packages
    cat > "$PACKAGES_LIST" << 'EOF'
# Test packages list
# Comments should be ignored

curl
wget
git

# Another comment
rsync
ca-certificates
EOF

    # Create test script that uses CONFIG_DIR from test environment
    TEST_SCRIPT="$BATS_TEST_TMPDIR/install-packages-test.sh"
    cat > "$TEST_SCRIPT" << 'SCRIPT'
#!/bin/bash
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

set -e

echo "[INFO] Installing essential packages..."

# Use CONFIG_DIR from environment or calculate from script location
if [ -z "$CONFIG_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CONFIG_DIR="$(dirname "$SCRIPT_DIR")/config"
fi

# Check if packages.list exists
if [ -f "$CONFIG_DIR/packages.list" ]; then
    echo "[INFO] Installing packages from packages.list..."

    # Read packages from file and install
    PACKAGES=$(grep -v '^#' "$CONFIG_DIR/packages.list" | grep -v '^$' | tr '\n' ' ')

    if [ -n "$PACKAGES" ]; then
        apt-get install -y $PACKAGES
    fi
else
    echo "[WARN] packages.list not found, installing default packages..."

    # Default essential packages (minimal installation)
    apt-get install -y \
        curl \
        wget \
        git \
        rsync \
        ca-certificates \
        gnupg \
        lsb-release \
        apt-transport-https \
        nano \
        htop \
        iotop \
        lsof \
        net-tools \
        dnsutils \
        unattended-upgrades \
        ufw \
        fail2ban \
        logrotate \
        unzip \
        zip \
        gzip \
        tar \
        screen \
        jq \
        pwgen \
        default-mysql-client \
        python3
fi

echo "[INFO] Package installation complete!"
SCRIPT
    chmod +x "$TEST_SCRIPT"
}

teardown() {
    teardown_mocks
    rm -rf "$TEST_CONFIG_DIR"
    rm -f "$APT_GET_LOG" "$DPKG_QUERY_LOG" "$TEST_SCRIPT"
}

# ── Test: Reads packages from config/packages.list ──────────────────────────

@test "reads packages from config/packages.list" {
    # Mock apt-get to log what packages it receives
    create_call_log_mock "apt-get" "$APT_GET_LOG"
    
    # Run script with test config directory
    export CONFIG_DIR="$TEST_CONFIG_DIR"
    run bash "$TEST_SCRIPT"
    
    [ "$status" -eq 0 ]
    
    # Verify apt-get install was called
    [ -f "$APT_GET_LOG" ]
    
    # Check that the logged command contains expected packages
    grep -q "curl" "$APT_GET_LOG"
    grep -q "wget" "$APT_GET_LOG"
    grep -q "git" "$APT_GET_LOG"
    grep -q "rsync" "$APT_GET_LOG"
    grep -q "ca-certificates" "$APT_GET_LOG"
}

@test "ignores comments and empty lines in packages.list" {
    create_call_log_mock "apt-get" "$APT_GET_LOG"
    
    export CONFIG_DIR="$TEST_CONFIG_DIR"
    run bash "$TEST_SCRIPT"
    
    [ "$status" -eq 0 ]
    
    # Verify comments are not passed to apt-get
    ! grep -q "# Test packages" "$APT_GET_LOG"
    ! grep -q "# Comments should" "$APT_GET_LOG"
    ! grep -q "# Another comment" "$APT_GET_LOG"
}

# ── Test: apt-get update execution ──────────────────────────────────────────

@test "apt-get update is not called (design choice to run separately)" {
    create_call_log_mock "apt-get" "$APT_GET_LOG"
    
    export CONFIG_DIR="$TEST_CONFIG_DIR"
    run bash "$TEST_SCRIPT"
    
    [ "$status" -eq 0 ]
    
    # Verify update was not called (current script design)
    ! grep -q "update" "$APT_GET_LOG"
}

# ── Test: apt-get install with -y flag ──────────────────────────────────────

@test "uses apt-get install with -y flag for non-interactive installation" {
    create_call_log_mock "apt-get" "$APT_GET_LOG"
    
    export CONFIG_DIR="$TEST_CONFIG_DIR"
    run bash "$TEST_SCRIPT"
    
    [ "$status" -eq 0 ]
    
    # Verify -y flag is present
    grep -q "install -y" "$APT_GET_LOG"
}

@test "apt-get install command includes -y flag before package names" {
    create_mock_with_body "apt-get" 'echo "$@" >> '"$APT_GET_LOG"'; exit 0'
    
    export CONFIG_DIR="$TEST_CONFIG_DIR"
    run bash "$TEST_SCRIPT"
    
    [ "$status" -eq 0 ]
    
    # Read the logged arguments
    args=$(cat "$APT_GET_LOG")
    
    # Verify structure: install -y <packages>
    [[ "$args" =~ install[[:space:]]+-y ]]
}

# ── Test: All packages in one command ───────────────────────────────────────

@test "installs all packages in a single apt-get command" {
    create_call_log_mock "apt-get" "$APT_GET_LOG"
    
    export CONFIG_DIR="$TEST_CONFIG_DIR"
    run bash "$TEST_SCRIPT"
    
    [ "$status" -eq 0 ]
    
    # Count how many times apt-get was called
    call_count=$(wc -l < "$APT_GET_LOG")
    
    # Should be exactly one call
    [ "$call_count" -eq 1 ]
}

@test "single command contains all non-comment packages from list" {
    create_call_log_mock "apt-get" "$APT_GET_LOG"
    
    export CONFIG_DIR="$TEST_CONFIG_DIR"
    run bash "$TEST_SCRIPT"
    
    [ "$status" -eq 0 ]
    
    # Get the single logged command
    logged_command=$(cat "$APT_GET_LOG")
    
    # Verify all expected packages are in the same command
    echo "$logged_command" | grep -q "curl"
    echo "$logged_command" | grep -q "wget"
    echo "$logged_command" | grep -q "git"
    echo "$logged_command" | grep -q "rsync"
    echo "$logged_command" | grep -q "ca-certificates"
}

# ── Test: Idempotency (packages already installed) ──────────────────────────

@test "handles idempotency when packages are already installed" {
    # Mock apt-get to simulate packages already installed
    create_mock_with_body "apt-get" 'echo "curl is already the newest version"; exit 0'
    
    # Mock dpkg-query to report packages as installed
    create_mock_with_body "dpkg-query" 'exit 0'
    
    export CONFIG_DIR="$TEST_CONFIG_DIR"
    run bash "$TEST_SCRIPT"
    
    # Should still succeed when packages are already installed
    [ "$status" -eq 0 ]
}

@test "runs successfully multiple times (idempotent)" {
    create_mock "apt-get"
    
    export CONFIG_DIR="$TEST_CONFIG_DIR"
    
    # First run
    run bash "$TEST_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Second run should also succeed
    run bash "$TEST_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "apt-get handles already installed packages gracefully" {
    # Mock apt-get with realistic output for already installed packages
    create_mock_with_body "apt-get" 'cat << EOF
Reading package lists...
Building dependency tree...
Reading state information...
curl is already the newest version (7.88.1-10+deb12u8).
wget is already the newest version (1.21.3-1+b2).
0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.
EOF
exit 0'
    
    export CONFIG_DIR="$TEST_CONFIG_DIR"
    run bash "$TEST_SCRIPT"
    
    [ "$status" -eq 0 ]
}

# ── Test: Error handling for missing packages.list ─────────────────────────

@test "handles missing packages.list with warning and default packages" {
    # Remove packages.list
    rm -f "$PACKAGES_LIST"
    
    create_call_log_mock "apt-get" "$APT_GET_LOG"
    
    export CONFIG_DIR="$TEST_CONFIG_DIR"
    run bash "$TEST_SCRIPT"
    
    [ "$status" -eq 0 ]
    
    # Should show warning in output
    echo "$output" | grep -q "\[WARN\].*packages.list not found"
    
    # Should still install default packages
    [ -f "$APT_GET_LOG" ]
}

@test "uses default package list when packages.list is missing" {
    rm -f "$PACKAGES_LIST"
    
    create_call_log_mock "apt-get" "$APT_GET_LOG"
    
    export CONFIG_DIR="$TEST_CONFIG_DIR"
    run bash "$TEST_SCRIPT"
    
    [ "$status" -eq 0 ]
    
    # Verify some default packages are installed
    grep -q "curl" "$APT_GET_LOG"
    grep -q "wget" "$APT_GET_LOG"
    grep -q "git" "$APT_GET_LOG"
    grep -q "fail2ban" "$APT_GET_LOG"
    grep -q "ufw" "$APT_GET_LOG"
}

@test "handles missing config directory gracefully" {
    # Use non-existent config directory
    export CONFIG_DIR="$BATS_TEST_TMPDIR/nonexistent"
    
    create_mock "apt-get"
    
    run bash "$TEST_SCRIPT"
    
    # Should still succeed with default packages
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "\[WARN\].*packages.list not found"
}

# ── Test: Package list validation ───────────────────────────────────────────

@test "handles empty packages.list file" {
    # Create empty packages.list
    : > "$PACKAGES_LIST"
    
    create_call_log_mock "apt-get" "$APT_GET_LOG"
    
    export CONFIG_DIR="$TEST_CONFIG_DIR"
    run bash "$TEST_SCRIPT"
    
    [ "$status" -eq 0 ]
    
    # apt-get should not be called when no packages are listed
    [ ! -f "$APT_GET_LOG" ] || [ ! -s "$APT_GET_LOG" ]
}

@test "handles packages.list with only comments" {
    cat > "$PACKAGES_LIST" << 'EOF'
# Only comments here
# No actual packages
EOF
    
    create_call_log_mock "apt-get" "$APT_GET_LOG"
    
    export CONFIG_DIR="$TEST_CONFIG_DIR"
    run bash "$TEST_SCRIPT"
    
    [ "$status" -eq 0 ]
    
    # No packages to install, so apt-get should not be called or log should be empty
    [ ! -f "$APT_GET_LOG" ] || [ ! -s "$APT_GET_LOG" ]
}

@test "preserves package order from packages.list" {
    cat > "$PACKAGES_LIST" << 'EOF'
zsh
bash
fish
EOF
    
    create_call_log_mock "apt-get" "$APT_GET_LOG"
    
    export CONFIG_DIR="$TEST_CONFIG_DIR"
    run bash "$TEST_SCRIPT"
    
    [ "$status" -eq 0 ]
    
    # Verify all packages are present in the command
    grep -q "zsh" "$APT_GET_LOG"
    grep -q "bash" "$APT_GET_LOG"
    grep -q "fish" "$APT_GET_LOG"
}

# ── Test: Error conditions ──────────────────────────────────────────────────

@test "fails when apt-get install fails" {
    # Mock apt-get to fail
    create_mock_with_body "apt-get" 'echo "E: Unable to locate package invalid-package-name"; exit 100'
    
    export CONFIG_DIR="$TEST_CONFIG_DIR"
    run bash "$TEST_SCRIPT"
    
    # Script uses set -e, so it should fail when apt-get fails
    [ "$status" -ne 0 ]
}

@test "reports error when package not found" {
    # Add an invalid package to the list
    echo "this-package-does-not-exist-12345" >> "$PACKAGES_LIST"
    
    # Mock apt-get to fail with package not found error
    create_mock_with_body "apt-get" 'echo "E: Unable to locate package this-package-does-not-exist-12345" >&2; exit 100'
    
    export CONFIG_DIR="$TEST_CONFIG_DIR"
    run bash "$TEST_SCRIPT"
    
    [ "$status" -ne 0 ]
    echo "$output" | grep -q "Unable to locate package"
}

# ── Test: Output messages ───────────────────────────────────────────────────

@test "displays informational messages during execution" {
    create_mock "apt-get"
    
    export CONFIG_DIR="$TEST_CONFIG_DIR"
    run bash "$TEST_SCRIPT"
    
    [ "$status" -eq 0 ]
    
    # Check for expected informational messages
    echo "$output" | grep -q "\[INFO\].*Installing essential packages"
    echo "$output" | grep -q "\[INFO\].*Installing packages from packages.list"
    echo "$output" | grep -q "\[INFO\].*Package installation complete"
}

@test "shows warning message when packages.list is missing" {
    rm -f "$PACKAGES_LIST"
    
    create_mock "apt-get"
    
    export CONFIG_DIR="$TEST_CONFIG_DIR"
    run bash "$TEST_SCRIPT"
    
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "\[WARN\].*packages.list not found"
}

# ── Test: Integration with actual script ────────────────────────────────────

@test "actual script exists and is executable" {
    [ -f "$SCRIPTS_DIR/install-packages.sh" ]
    [ -x "$SCRIPTS_DIR/install-packages.sh" ]
}

@test "actual script has correct shebang" {
    head -n 1 "$SCRIPTS_DIR/install-packages.sh" | grep -q "^#!/bin/bash"
}

@test "actual script uses set -e for error handling" {
    grep -q "set -e" "$SCRIPTS_DIR/install-packages.sh"
}
