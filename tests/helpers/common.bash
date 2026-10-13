# Shared BATS test helpers for dockerHosting
# Load with: load '../helpers/common'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
TEMPLATES_DIR="$REPO_ROOT/templates"

# ── mock infrastructure ───────────────────────────────────────────────────────

# Creates a writable mock bin dir and prepends it to PATH so mock commands
# shadow real system commands for the duration of the test.
setup_mocks() {
    MOCK_BIN="$BATS_TEST_TMPDIR/mock_bin"
    mkdir -p "$MOCK_BIN"
    export PATH="$MOCK_BIN:$PATH"
}

teardown_mocks() {
    rm -rf "${MOCK_BIN:-}"
}

# create_mock NAME — exits 0, produces no output
create_mock() {
    local name="$1"
    printf '#!/bin/bash\nexit 0\n' > "$MOCK_BIN/$name"
    chmod +x "$MOCK_BIN/$name"
}

# create_mock_with_body NAME BODY — custom mock body (full bash script fragment)
create_mock_with_body() {
    local name="$1" body="$2"
    printf '#!/bin/bash\n%s\n' "$body" > "$MOCK_BIN/$name"
    chmod +x "$MOCK_BIN/$name"
}

# create_call_log_mock NAME LOGFILE — records all invocations to LOGFILE, exits 0
create_call_log_mock() {
    local name="$1" logfile="$2"
    printf '#!/bin/bash\necho "$*" >> "%s"\nexit 0\n' "$logfile" > "$MOCK_BIN/$name"
    chmod +x "$MOCK_BIN/$name"
}

# hide_command NAME [SCRIPT] — make NAME unresolvable, even where the host has a
# real binary: GitHub's Ubuntu runners ship /usr/sbin/ufw, so deleting a mock is
# not enough. PATH becomes MOCK_BIN followed by a symlink mirror of every other
# PATH directory with NAME left out; mocks created later in MOCK_BIN still win.
# Scripts that append the system directories to PATH themselves would find the
# real binary again, so that line is removed from SCRIPT (a patched test copy).
hide_command() {
    local name="$1" script="${2:-}" dir mirror i=0 new_path="$MOCK_BIN"
    local IFS=:
    for dir in $PATH; do
        [[ -d "$dir" && "$dir" != "$MOCK_BIN" ]] || continue
        mirror="$BATS_TEST_TMPDIR/hide_${name}_path/$((i++))"
        mkdir -p "$mirror"
        ln -s "$dir"/* "$mirror"/ 2>/dev/null || true
        rm -f "$mirror/$name"
        new_path+=":$mirror"
    done
    export PATH="$new_path"
    if [[ -n "$script" ]]; then
        sed -i.orig '/^export PATH=/d' "$script"
    fi
}

# file_mode FILE — octal permission bits, e.g. 600. GNU stat goes first: GNU
# reads `stat -f` as --file-system and prints filesystem details instead of
# failing, so the BSD form may only run where `stat -c` is rejected (macOS).
file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# ── path helpers ──────────────────────────────────────────────────────────────

# Sets up a minimal Traefik directory tree under BATS_TEST_TMPDIR
# and exports the env vars that override default paths in the scripts.
setup_traefik_dirs() {
    export TRAEFIK_DIR="$BATS_TEST_TMPDIR/traefik"
    export TRAEFIK_DYNAMIC_DIR="$TRAEFIK_DIR/dynamic"
    export TRAEFIK_CERTS_DIR="$TRAEFIK_DIR/certs"
    export TEMPLATE_DIR="$TEMPLATES_DIR"
    mkdir -p "$TRAEFIK_DYNAMIC_DIR" "$TRAEFIK_CERTS_DIR"
}

# Sets up a fake nginx sites-enabled dir and dockerhosting SSL dir
setup_nginx_dirs() {
    export NGINX_SITES_DIR="$BATS_TEST_TMPDIR/nginx-sites"
    export DOCKERHOSTING_SSL_DIR="$BATS_TEST_TMPDIR/ssl"
    export DEPLOYED_APPS_DIR="$BATS_TEST_TMPDIR/apps"
    mkdir -p "$NGINX_SITES_DIR" "$DOCKERHOSTING_SSL_DIR" "$DEPLOYED_APPS_DIR"
}

# ── file assertion helpers ────────────────────────────────────────────────────

# assert_file_exists FILE — fails with message if FILE does not exist
assert_file_exists() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "Expected file to exist: $file"
        return 1
    fi
}

# assert_file_contains FILE TEXT — fails with diff if TEXT not found in FILE
assert_file_contains() {
    local file="$1" text="$2"
    if ! grep -qF -- "$text" "$file" 2>/dev/null; then
        echo "Expected '$file' to contain: $text"
        echo "Actual content:"
        cat "$file" 2>/dev/null || echo "(file not found)"
        return 1
    fi
}

# refute_file_contains FILE TEXT — fails if TEXT IS found in FILE
refute_file_contains() {
    local file="$1" text="$2"
    if grep -qF -- "$text" "$file" 2>/dev/null; then
        echo "Expected '$file' NOT to contain: $text"
        echo "Actual content:"
        cat "$file"
        return 1
    fi
}

# ── nginx conf helpers ────────────────────────────────────────────────────────

# write_nginx_conf FILENAME SERVER_NAME PORT — writes a minimal nginx site conf
write_nginx_conf() {
    local filename="$1" server_name="$2" port="$3"
    cat > "$NGINX_SITES_DIR/$filename" <<EOF
server {
    listen 443 ssl;
    server_name $server_name;
    location / {
        proxy_pass http://127.0.0.1:$port;
    }
}
EOF
}

# write_nginx_conf_custom FILENAME CONTENT — writes arbitrary content
write_nginx_conf_custom() {
    local filename="$1" content="$2"
    printf '%s\n' "$content" > "$NGINX_SITES_DIR/$filename"
}
