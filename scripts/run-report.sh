#!/bin/bash
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#############################################
# dockerHosting Audit Report
#
# Passive posture audit of the host. Emits a Markdown log and a JSON
# sidecar under /var/log/dockerHosting/audit-reports/ aligned with:
#   NIST SP 800-115 §3.1 documentation review
#   NIST SP 800-115 §3.2 log review
#   NIST SP 800-115 §3.3 ruleset review
#   NIST SP 800-115 §4.1 target identification
#   NIST SP 800-115 §4.4 vulnerability scanning
#
# Read-only: this script does not mutate system or container state.
#
# Usage: sudo ./run-report.sh
#############################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Log functions (terminal output)
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log_info() { echo -e "${GREEN}[INFO]${NC}  [$(_ts)] $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  [$(_ts)] $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} [$(_ts)] $1"; }

# Overridable for tests
REPORT_DIR="${DOCKERHOSTING_REPORT_DIR:-/var/log/dockerHosting/audit-reports}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Runtime globals
HOSTNAME_SHORT=""
REPORT_TS=""
MD_FILE=""
JSON_FILE=""
JSON_FIRST_KEY=true

# Print a coloured horizontal rule above each section heading
_rule() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
}

# Escape stdin as a JSON string literal (including surrounding quotes).
# Pure-bash ${var//x/y} is O(n²); Trivy JSON bodies are multi-MB and would
# pin a CPU for minutes. python3's json.dumps does it in linear time.
_json_escape() {
    python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))'
}

# Append a section to Markdown, JSON, and terminal output.
# Usage: emit_section <num> <title> <summary> <body>
emit_section() {
    local num="$1" title="$2" summary="$3" body="$4"
    _rule
    log_info "§${num} ${title}: ${summary}"
    {
        echo
        echo "## ${num}. ${title}"
        echo
        echo "_Summary: ${summary}_"
        echo
        echo "${body}"
    } >> "$MD_FILE"
    local prefix=","
    if [ "$JSON_FIRST_KEY" = true ]; then
        prefix=""
        JSON_FIRST_KEY=false
    fi
    local b_esc t_esc s_esc
    b_esc=$(printf '%s' "$body" | _json_escape)
    t_esc=$(printf '%s' "$title" | _json_escape)
    s_esc=$(printf '%s' "$summary" | _json_escape)
    printf '%s\n  "section_%s": {"title": %s, "summary": %s, "body": %s}' \
        "$prefix" "$num" "$t_esc" "$s_esc" "$b_esc" >> "$JSON_FILE"
}

# §1: host identity (hostnamectl, uname, chronyc, uptime) — §3.1
section_host_identity() {
    local body summary
    body=$(_capture_host_identity)
    summary="$(hostname) / kernel $(uname -r)"
    emit_section "1" "Host identity" "$summary" "$body"
}

_capture_host_identity() {
    echo "### hostnamectl"
    echo '```'
    hostnamectl 2> /dev/null || echo "(hostnamectl unavailable)"
    echo '```'
    echo
    echo "### uname -a"
    echo '```'
    uname -a
    echo '```'
    echo
    echo "### chronyc tracking"
    echo '```'
    chronyc tracking 2> /dev/null || echo "(chronyc unavailable)"
    echo '```'
    echo
    echo "### uptime"
    uptime -p 2> /dev/null || echo "(uptime unavailable)"
}

# §2: patch level (apt upgradable, unattended-upgrades log, kernel) — §3.2
section_patch_level() {
    local body summary upgradable
    upgradable=$(apt list --upgradable 2> /dev/null | grep -cv '^Listing' || true)
    body=$(_capture_patch_level)
    summary="${upgradable} upgradable package(s); running kernel $(uname -r)"
    emit_section "2" "Patch level" "$summary" "$body"
}

_capture_patch_level() {
    echo "### Upgradable packages"
    echo '```'
    apt list --upgradable 2> /dev/null || echo "(apt unavailable)"
    echo '```'
    echo
    echo "### Unattended-upgrades log (tail 20)"
    echo '```'
    tail -n 20 /var/log/unattended-upgrades/unattended-upgrades.log 2> /dev/null ||
        echo "(no unattended-upgrades log)"
    echo '```'
    echo
    echo "### Kernel running vs installed"
    echo '- running: '"$(uname -r)"
    echo '- installed:'
    echo '```'
    dpkg -l 'linux-image-*' 2> /dev/null | awk '/^ii/ {print "  " $2 " " $3}' ||
        echo "(dpkg unavailable)"
    echo '```'
}

# §3: host CVEs via debsecan — §4.4
section_host_cves() {
    _ensure_debsecan
    local suite body summary report high medium
    suite=$(lsb_release -cs 2> /dev/null || echo "stable")
    report=$(debsecan --suite "$suite" --format report 2> /dev/null ||
        echo "(debsecan unavailable)")
    high=$(echo "$report" | grep -ciE 'high urgency' || true)
    medium=$(echo "$report" | grep -ciE 'medium urgency' || true)
    body=$(printf '### debsecan --suite %s\n```\n%s\n```\n' "$suite" "$report")
    summary="${high} high, ${medium} medium urgency CVE(s)"
    emit_section "3" "Host CVEs" "$summary" "$body"
}

# Install debsecan via apt-get if not already present (idempotent, silent).
_ensure_debsecan() {
    command -v debsecan > /dev/null 2>&1 && return 0
    log_info "Installing debsecan (required for §3 host CVE scan)..."
    apt-get install -y -qq debsecan > /dev/null 2>&1 || true
}

# §4: container image CVEs (Trivy, via scan-image.sh --json) — §4.4
section_container_cves() {
    local body summary images crit high
    images=$(docker ps --format '{{.Image}}' 2> /dev/null | sort -u)
    if [ -z "$images" ]; then
        emit_section "4" "Container image CVEs" "no running containers" \
            "(no running containers — nothing to scan)"
        return 0
    fi
    body=$(_scan_running_images "$images")
    crit=$(echo "$body" | grep -ciE '"Severity":[[:space:]]*"CRITICAL"' || true)
    high=$(echo "$body" | grep -ciE '"Severity":[[:space:]]*"HIGH"' || true)
    summary="${crit} CRITICAL, ${high} HIGH findings across running images"
    emit_section "4" "Container image CVEs" "$summary" "$body"
}

_scan_running_images() {
    local images="$1" image
    echo "### Trivy scan of running container images"
    while IFS= read -r image; do
        [ -z "$image" ] && continue
        echo
        echo "#### ${image}"
        echo '```json'
        bash "$SCRIPT_DIR/scan-image.sh" --json --no-fail \
            --severity CRITICAL,HIGH "$image" 2> /dev/null ||
            echo "(scan failed)"
        echo '```'
    done <<< "$images"
}

# §5: UFW firewall state — §3.3 ruleset review
section_ufw_state() {
    local body summary
    body=$(_capture_ufw_state)
    summary=$(_ufw_default_summary)
    emit_section "5" "UFW firewall state" "$summary" "$body"
}

_capture_ufw_state() {
    echo "### ufw status verbose"
    echo '```'
    ufw status verbose 2> /dev/null || echo "(ufw unavailable)"
    echo '```'
    echo
    echo "### ufw status numbered"
    echo '```'
    ufw status numbered 2> /dev/null || echo "(ufw unavailable)"
    echo '```'
}

_ufw_default_summary() {
    local out def
    out=$(ufw status verbose 2> /dev/null) || {
        echo "ufw unavailable"
        return
    }
    def=$(echo "$out" | grep -E '^Default:' | head -1 | sed 's/^Default: //')
    echo "default policy [${def:-unknown}]"
}

# §6: listen-vs-UFW delta (passive substitute for nmap target ID) — §4.1
section_listen_ufw_delta() {
    local body summary deltas
    body=$(_capture_listen_delta)
    deltas=$(echo "$body" | grep -c '^\[MEDIUM\]' || true)
    summary="${deltas} exposed port(s) without a matching UFW allow rule"
    emit_section "6" "Listen-vs-UFW delta" "$summary" "$body"
}

_capture_listen_delta() {
    local ufw_ports
    ufw_ports=$(_extract_ufw_ports)
    echo "### Listening sockets (ss -tlnp)"
    echo '```'
    ss -tlnp -H 2> /dev/null || echo "(ss unavailable)"
    echo '```'
    echo
    echo "### Deltas (wildcard-bound port with no matching UFW allow rule)"
    ss -tlnp -H 2> /dev/null | _format_deltas "$ufw_ports"
}

# Extract numeric port allow rules from `ufw status`, one per line.
_extract_ufw_ports() {
    ufw status 2> /dev/null |
        awk '/ALLOW/ {split($1, a, "/"); print a[1]}' |
        grep -E '^[0-9]+$' |
        sort -u
}

_format_deltas() {
    local allowed="$1" port bind
    while read -r _state _recvq _sendq addr_port _peer _proc; do
        [ -z "${addr_port:-}" ] && continue
        port="${addr_port##*:}"
        bind="${addr_port%:*}"
        _is_wildcard_bind "$bind" || continue
        if ! echo "$allowed" | grep -qE "^${port}$"; then
            echo "[MEDIUM] port ${port} bound on ${bind} but no UFW allow rule"
        fi
    done
}

# Return 0 if the bind address is a wildcard (any-IPv4 or any-IPv6 form).
_is_wildcard_bind() {
    case "$1" in
        0.0.0.0 | '*' | '::' | '[::]' | '0') return 0 ;;
        *) return 1 ;;
    esac
}

# §7: running containers (docker ps + per-container inspect)
section_containers() {
    local body summary count
    count=$(docker ps -q 2> /dev/null | wc -l | tr -d ' ' || echo 0)
    body=$(_capture_containers)
    summary="${count} running container(s)"
    emit_section "7" "Running containers" "$summary" "$body"
}

_capture_containers() {
    echo "### docker ps"
    echo '```'
    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2> /dev/null ||
        echo "(docker unavailable)"
    echo '```'
    echo
    echo "### Per-container inspect"
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        echo
        echo "#### ${name}"
        echo '```'
        _inspect_container "$name"
        echo '```'
    done < <(docker ps --format '{{.Names}}' 2> /dev/null)
}

_inspect_container() {
    local n="$1"
    printf 'Restart: %s\n' "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$n" 2> /dev/null)"
    printf 'User:    %s\n' "$(docker inspect -f '{{.Config.User}}' "$n" 2> /dev/null)"
    printf 'CapAdd:  %s\n' "$(docker inspect -f '{{.HostConfig.CapAdd}}' "$n" 2> /dev/null)"
    printf 'Exposed: %s\n' "$(docker inspect -f '{{json .Config.ExposedPorts}}' "$n" 2> /dev/null)"
    printf 'Ports:   %s\n' "$(docker inspect -f '{{json .NetworkSettings.Ports}}' "$n" 2> /dev/null)"
    printf 'Mounts:  %s\n' \
        "$(docker inspect -f '{{range .Mounts}}{{.Source}}->{{.Destination}} ({{.Mode}}) {{end}}' "$n" 2> /dev/null)"
}

# §8: Traefik dynamic routes summary
section_traefik_routes() {
    local body summary count dir=/etc/traefik/dynamic
    if [ ! -d "$dir" ]; then
        emit_section "8" "Traefik dynamic routes" "no $dir directory" "(skipped)"
        return 0
    fi
    count=$(find "$dir" -type f \( -name '*.yml' -o -name '*.yaml' \) 2> /dev/null | wc -l | tr -d ' ')
    body=$(_capture_traefik_routes "$dir")
    summary="${count} dynamic config file(s)"
    emit_section "8" "Traefik dynamic routes" "$summary" "$body"
}

_capture_traefik_routes() {
    local dir="$1" f
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        echo
        echo "#### ${f}"
        echo '```yaml'
        cat "$f" 2> /dev/null || echo "(unreadable)"
        echo '```'
    done < <(find "$dir" -type f \( -name '*.yml' -o -name '*.yaml' \) 2> /dev/null | sort)
}

# §9: failed authentication in last 24h — §3.2 log review
section_failed_auth() {
    local body summary fails
    fails=$(journalctl -u ssh --since='24 hours ago' -p err --no-pager 2> /dev/null |
        wc -l | tr -d ' ' || echo 0)
    body=$(_capture_failed_auth)
    summary="${fails} SSH error line(s) in last 24h"
    emit_section "9" "Failed authentication (24h)" "$summary" "$body"
}

_capture_failed_auth() {
    echo "### journalctl -u ssh --since='24 hours ago' -p err (tail 50)"
    echo '```'
    journalctl -u ssh --since='24 hours ago' -p err --no-pager 2> /dev/null |
        tail -n 50 || echo "(journalctl unavailable)"
    echo '```'
    echo
    echo "### fail2ban-client status sshd"
    echo '```'
    if systemctl is-active --quiet fail2ban 2> /dev/null; then
        fail2ban-client status sshd 2> /dev/null || echo "(jail not configured)"
    else
        echo "(fail2ban not active)"
    fi
    echo '```'
}

# §11: observability — detect New Relic at host and container level
section_newrelic() {
    local body summary
    body=$(_capture_newrelic)
    summary=$(_newrelic_summary)
    emit_section "11" "Observability — New Relic" "$summary" "$body"
}

_newrelic_host_state() {
    if systemctl is-active --quiet newrelic-infra 2> /dev/null; then
        echo "active"
    elif systemctl list-unit-files 2> /dev/null | grep -q '^newrelic-infra'; then
        echo "installed-inactive"
    elif command -v newrelic-infra > /dev/null 2>&1 ||
        [ -f /etc/newrelic-infra.yml ] ||
        [ -f /etc/newrelic-infra/newrelic-infra.yml ]; then
        echo "binary-or-config-present"
    else
        echo "absent"
    fi
}

_newrelic_container_count() {
    command -v docker > /dev/null 2>&1 || {
        echo 0
        return
    }
    docker ps --format '{{.Image}} {{.Names}}' 2> /dev/null |
        grep -ciE '(^|/)newrelic|new-?relic' || true
}

_capture_newrelic() {
    local host_state container_count
    host_state=$(_newrelic_host_state)
    container_count=$(_newrelic_container_count)
    echo "### Host-level New Relic"
    echo "- state: ${host_state}"
    echo "- /etc/newrelic-infra.yml: $([ -f /etc/newrelic-infra.yml ] && echo present || echo absent)"
    echo
    echo "### Container-level New Relic"
    echo "- containers matching newrelic image: ${container_count}"
    if [ "$container_count" -gt 0 ] && command -v docker > /dev/null 2>&1; then
        echo '```'
        docker ps --format '{{.Names}} {{.Image}}' 2> /dev/null |
            grep -iE 'newrelic|new-?relic' || true
        echo '```'
    fi
}

_newrelic_summary() {
    local host_state container_count
    host_state=$(_newrelic_host_state)
    container_count=$(_newrelic_container_count)
    echo "host=${host_state}, containers=${container_count}"
}

# §10: hardening posture (AppArmor, SSH config, auditd) — §3.3 ruleset review
section_hardening_posture() {
    local body summary
    body=$(_capture_hardening)
    summary=$(_hardening_summary)
    emit_section "10" "Hardening posture" "$summary" "$body"
}

_capture_hardening() {
    echo "### AppArmor (aa-status --summary)"
    echo '```'
    aa-status --summary 2> /dev/null || echo "(aa-status unavailable)"
    echo '```'
    echo
    echo "### SSH effective config"
    echo '```'
    sshd -T 2> /dev/null | grep -iE 'permitrootlogin|passwordauthentication|maxauthtries' ||
        echo "(sshd -T unavailable)"
    echo '```'
    echo
    echo "### auditd"
    echo '```'
    systemctl is-active auditd 2> /dev/null || echo "auditd: inactive"
    if [ -f /etc/audit/rules.d/99-security.rules ]; then
        echo "/etc/audit/rules.d/99-security.rules: present"
    else
        echo "/etc/audit/rules.d/99-security.rules: missing"
    fi
    echo '```'
}

_hardening_summary() {
    local aa ssh_pwd
    if aa-status --enabled > /dev/null 2>&1; then
        aa="AppArmor:on"
    else
        aa="AppArmor:off"
    fi
    ssh_pwd=$(sshd -T 2> /dev/null | awk '/^passwordauthentication/ {print "ssh-pwd:"$2; exit}')
    echo "${aa}, ${ssh_pwd:-ssh-pwd:unknown}"
}

# Ensure /etc/logrotate.d/dockerHosting-audit exists (writable host only).
_ensure_logrotate() {
    local conf=/etc/logrotate.d/dockerHosting-audit
    [ -f "$conf" ] && return 0
    [ -w /etc/logrotate.d ] || return 0
    cat > "$conf" << 'EOF'
/var/log/dockerHosting/audit-reports/*.log
/var/log/dockerHosting/audit-reports/*.log.json {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
}
EOF
    chmod 644 "$conf" 2> /dev/null || true
}

# Initialise report output files and JSON envelope.
_init_outputs() {
    HOSTNAME_SHORT=$(hostname -s 2> /dev/null || hostname || echo "unknown")
    REPORT_TS=$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "$REPORT_DIR"
    chmod 0750 "$REPORT_DIR" 2> /dev/null || true
    MD_FILE="${REPORT_DIR}/audit-report-${HOSTNAME_SHORT}-${REPORT_TS}.log"
    JSON_FILE="${MD_FILE}.json"
    {
        echo "# dockerHosting Audit Report"
        echo
        echo "- Host: ${HOSTNAME_SHORT}"
        echo "- Generated: $(_ts)"
        echo "- Scope: passive (read-only)"
        echo "- NIST SP 800-115 §§3.1, 3.2, 3.3, 4.1, 4.4"
    } > "$MD_FILE"
    printf '{\n  "host": "%s",\n  "generated_utc": "%s"' \
        "$HOSTNAME_SHORT" "$(_ts)" > "$JSON_FILE"
    JSON_FIRST_KEY=false
}

# Finalise output files: close JSON, set perms/ownership.
_finalize_outputs() {
    echo "" >> "$JSON_FILE"
    echo "}" >> "$JSON_FILE"
    chown root:adm "$MD_FILE" "$JSON_FILE" 2> /dev/null || true
    chmod 0640 "$MD_FILE" "$JSON_FILE"
}

# Run every section in order. New sections must be added here AND defined above.
_run_sections() {
    section_host_identity
    section_patch_level
    section_host_cves
    section_container_cves
    section_ufw_state
    section_listen_ufw_delta
    section_containers
    section_traefik_routes
    section_failed_auth
    section_hardening_posture
    section_newrelic
}

# Top-level orchestrator: enforce root, init outputs, run every section, finalise.
main() {
    if [ "$EUID" -ne 0 ]; then
        log_error "run-report.sh must be run as root (or with sudo)"
        exit 1
    fi
    _init_outputs
    log_info "Audit report — ${HOSTNAME_SHORT} @ $(_ts)"
    log_info "Markdown: ${MD_FILE}"
    log_info "JSON:     ${JSON_FILE}"
    _run_sections
    _finalize_outputs
    _ensure_logrotate
    echo
    _rule
    log_info "Report complete: ${MD_FILE}"
    log_info "JSON sidecar:    ${JSON_FILE}"
}

main "$@"
