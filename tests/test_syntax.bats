#!/usr/bin/env bats
# Bash syntax check for every shell script in the repository.
# Uses `bash -n` which parses without executing.
# Catches: unmatched brackets, unclosed strings, bad redirections, etc.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

_syntax_check() {
    local script="$1"
    run bash -n "$REPO_ROOT/$script"
    if [ "$status" -ne 0 ]; then
        echo "Syntax error in $script:"
        echo "$output"
    fi
    [ "$status" -eq 0 ]
}

# ── root scripts ──────────────────────────────────────────────────────────────

@test "syntax: setup.sh" {
    _syntax_check "setup.sh"
}

@test "syntax: deploy-site.sh" {
    _syntax_check "deploy-site.sh"
}

# ── Traefik scripts ───────────────────────────────────────────────────────────

@test "syntax: scripts/install-traefik.sh" {
    _syntax_check "scripts/install-traefik.sh"
}

@test "syntax: scripts/add-traefik-site.sh" {
    _syntax_check "scripts/add-traefik-site.sh"
}

@test "syntax: scripts/remove-traefik-site.sh" {
    _syntax_check "scripts/remove-traefik-site.sh"
}

# ── install scripts ───────────────────────────────────────────────────────────

@test "syntax: scripts/install-docker.sh" {
    _syntax_check "scripts/install-docker.sh"
}

@test "syntax: scripts/install-nginx.sh" {
    _syntax_check "scripts/install-nginx.sh"
}

@test "syntax: scripts/install-packages.sh" {
    _syntax_check "scripts/install-packages.sh"
}

# ── hardening scripts ─────────────────────────────────────────────────────────

@test "syntax: scripts/harden-docker.sh" {
    _syntax_check "scripts/harden-docker.sh"
}

@test "syntax: scripts/harden-kernel.sh" {
    _syntax_check "scripts/harden-kernel.sh"
}

@test "syntax: scripts/harden-shared-memory.sh" {
    _syntax_check "scripts/harden-shared-memory.sh"
}

@test "syntax: scripts/harden-ssh.sh" {
    _syntax_check "scripts/harden-ssh.sh"
}

@test "syntax: scripts/harden-bootloader.sh" {
    _syntax_check "scripts/harden-bootloader.sh"
}

@test "syntax: scripts/harden-usb.sh" {
    _syntax_check "scripts/harden-usb.sh"
}

@test "syntax: scripts/harden-compose.sh" {
    _syntax_check "scripts/harden-compose.sh"
}

# ── setup scripts ─────────────────────────────────────────────────────────────

@test "syntax: scripts/setup-aide.sh" {
    _syntax_check "scripts/setup-aide.sh"
}

@test "syntax: scripts/setup-audit.sh" {
    _syntax_check "scripts/setup-audit.sh"
}

@test "syntax: scripts/setup-auto-updates.sh" {
    _syntax_check "scripts/setup-auto-updates.sh"
}

@test "syntax: scripts/setup-docker-network.sh" {
    _syntax_check "scripts/setup-docker-network.sh"
}

@test "syntax: scripts/setup-docker-permissions.sh" {
    _syntax_check "scripts/setup-docker-permissions.sh"
}

@test "syntax: scripts/setup-email.sh" {
    _syntax_check "scripts/setup-email.sh"
}

@test "syntax: scripts/setup-fail2ban-enhanced.sh" {
    _syntax_check "scripts/setup-fail2ban-enhanced.sh"
}

@test "syntax: scripts/setup-logrotate.sh" {
    _syntax_check "scripts/setup-logrotate.sh"
}

@test "syntax: scripts/setup-pam-policy.sh" {
    _syntax_check "scripts/setup-pam-policy.sh"
}

@test "syntax: scripts/setup-ssl.sh" {
    _syntax_check "scripts/setup-ssl.sh"
}

@test "syntax: scripts/setup-users.sh" {
    _syntax_check "scripts/setup-users.sh"
}

@test "syntax: scripts/setup-ntp.sh" {
    _syntax_check "scripts/setup-ntp.sh"
}

@test "syntax: scripts/setup-apparmor.sh" {
    _syntax_check "scripts/setup-apparmor.sh"
}

@test "syntax: scripts/setup-ssh-mfa.sh" {
    _syntax_check "scripts/setup-ssh-mfa.sh"
}

@test "syntax: scripts/setup-secret-scan.sh" {
    _syntax_check "scripts/setup-secret-scan.sh"
}

# ── configure / utility scripts ───────────────────────────────────────────────

@test "syntax: scripts/configure-firewall.sh" {
    _syntax_check "scripts/configure-firewall.sh"
}

@test "syntax: scripts/configure-nginx-site.sh" {
    _syntax_check "scripts/configure-nginx-site.sh"
}

@test "syntax: scripts/configure-site.sh" {
    _syntax_check "scripts/configure-site.sh"
}

@test "syntax: scripts/cleanup-packages.sh" {
    _syntax_check "scripts/cleanup-packages.sh"
}

@test "syntax: scripts/recover-docker.sh" {
    _syntax_check "scripts/recover-docker.sh"
}

@test "syntax: scripts/scan-image.sh" {
    _syntax_check "scripts/scan-image.sh"
}
