#!/bin/bash
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#############################################
# Secret Scanning Pre-commit Hook (gitleaks)
#
# Installs gitleaks and wires it as a git pre-commit hook so that
# commits containing secrets (API keys, passwords, tokens, private keys)
# are blocked before they reach the repository.
#
# Installs globally to /usr/local/bin/gitleaks and installs the hook
# into the git repository at the given path (or current directory).
#
# Idempotent — safe to re-run. Use --force to reinstall gitleaks.
#
# Usage:
#   setup-secret-scan.sh [<git-repo-path>] [--force]
#
# Examples:
#   setup-secret-scan.sh                          # installs in current dir
#   setup-secret-scan.sh /opt/apps/mysite         # installs in that repo
#   setup-secret-scan.sh /opt/apps/mysite --force # reinstall gitleaks binary
#
# Based on: NIS2 supply chain security, ISO 27001 A.8.24
#############################################

set -euo pipefail

REPO_PATH="${PWD}"
FORCE=false

for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        -*)      echo "[ERROR] Unknown option: $arg"; exit 1 ;;
        *)       REPO_PATH="$arg" ;;
    esac
done

# Install gitleaks binary
install_gitleaks() {
    if command -v gitleaks &>/dev/null && [[ "$FORCE" != true ]]; then
        echo "[INFO] gitleaks already installed: $(gitleaks version 2>/dev/null || echo 'unknown version')"
        return
    fi

    echo "[INFO] Installing gitleaks..."

    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64)  arch="x64" ;;
        aarch64) arch="arm64" ;;
        *)       echo "[ERROR] Unsupported architecture: $arch"; exit 1 ;;
    esac

    local version
    version="$(curl -fsSL https://api.github.com/repos/gitleaks/gitleaks/releases/latest \
        | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')"

    if [[ -z "$version" ]]; then
        echo "[ERROR] Could not determine latest gitleaks version"
        exit 1
    fi

    local tarball="gitleaks_${version}_linux_${arch}.tar.gz"
    local url="https://github.com/gitleaks/gitleaks/releases/download/v${version}/${tarball}"
    local checksum_url="https://github.com/gitleaks/gitleaks/releases/download/v${version}/gitleaks_${version}_checksums.txt"

    local tmpdir
    tmpdir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" EXIT

    curl -fsSL "$url" -o "${tmpdir}/${tarball}"
    curl -fsSL "$checksum_url" -o "${tmpdir}/checksums.txt"

    # Verify checksum
    (cd "$tmpdir" && grep "$tarball" checksums.txt | sha256sum -c -)

    tar -xzf "${tmpdir}/${tarball}" -C "$tmpdir" gitleaks
    install -m 0755 "${tmpdir}/gitleaks" /usr/local/bin/gitleaks

    echo "[INFO] gitleaks installed: $(gitleaks version 2>/dev/null)"
}

# Write the pre-commit hook
install_hook() {
    local repo="$1"

    if [[ ! -d "$repo/.git" ]]; then
        echo "[ERROR] Not a git repository: $repo"
        exit 1
    fi

    local hook_file="$repo/.git/hooks/pre-commit"
    local hooks_dir="$repo/.git/hooks"

    mkdir -p "$hooks_dir"

    # If a pre-commit hook already exists and isn't ours, prepend rather than overwrite
    if [[ -f "$hook_file" ]] && ! grep -q "gitleaks" "$hook_file"; then
        echo "[INFO] Existing pre-commit hook found — prepending gitleaks check..."
        local existing
        existing="$(cat "$hook_file")"
        cat > "$hook_file" << HOOK
#!/bin/bash
# gitleaks secret scan (prepended by setup-secret-scan.sh)
gitleaks protect --staged --redact -q
EXIT_CODE=\$?
if [ \$EXIT_CODE -ne 0 ]; then
    echo "[ERROR] gitleaks detected secrets in staged files. Commit blocked."
    echo "[INFO]  Run 'gitleaks protect --staged' to see details."
    exit \$EXIT_CODE
fi

${existing}
HOOK
    else
        cat > "$hook_file" << 'HOOK'
#!/bin/bash
# gitleaks secret scan pre-commit hook
# Installed by setup-secret-scan.sh (NIS2 supply chain / ISO 27001 A.8.24)

gitleaks protect --staged --redact -q
EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
    echo "[ERROR] gitleaks detected secrets in staged files. Commit blocked."
    echo "[INFO]  Run 'gitleaks protect --staged' to see details (without --redact)."
    echo "[INFO]  To bypass in an emergency: git commit --no-verify (use sparingly)"
    exit $EXIT_CODE
fi
HOOK
    fi

    chmod +x "$hook_file"
    echo "[INFO] Pre-commit hook installed: $hook_file"
}

# Write a .gitleaks.toml allowlist config if one does not exist
install_config() {
    local repo="$1"
    local config_file="$repo/.gitleaks.toml"

    if [[ -f "$config_file" ]]; then
        echo "[INFO] .gitleaks.toml already exists — skipping config creation."
        return
    fi

    cat > "$config_file" << 'TOML'
# gitleaks configuration
# https://github.com/gitleaks/gitleaks#configuration

title = "dockerHosting secret scan"

[extend]
# Use the default gitleaks ruleset as the base
useDefault = true

# Add allowlist entries here for known false positives, e.g.:
# [[rules.allowlist]]
# description = "Example placeholder values in templates"
# regexes = ['\{\{[A-Z_]+\}\}']

[[rules.allowlist]]
description = "Template placeholder values"
regexes = ['\{\{[A-Z_]+\}\}', 'YOUR_.*_HERE', 'REPLACE_ME']
TOML

    echo "[INFO] Created .gitleaks.toml: $config_file"
    echo "[INFO] Commit this file to your repository to share the config with the team."
}

install_gitleaks

if [[ -d "$REPO_PATH/.git" ]]; then
    install_hook "$REPO_PATH"
    install_config "$REPO_PATH"
    echo ""
    echo "[INFO] Secret scanning pre-commit hook active."
    echo "[INFO] Test with: cd $REPO_PATH && gitleaks protect --staged"
else
    echo "[WARN] $REPO_PATH is not a git repository — skipping hook installation."
    echo "[INFO] gitleaks is installed globally at /usr/local/bin/gitleaks"
    echo "[INFO] Run this script from within a git repository to install the hook."
fi
