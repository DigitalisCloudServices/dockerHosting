#!/bin/bash
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#############################################
# Forward a site's MariaDB slow query logs to New Relic
#
# Usage: setup-slowlog-forwarding.sh <site_name> <server>=<container>[=<host_slowlog_path>] ...
#
#   setup-slowlog-forwarding.sh mysite \
#       primary=mysite-mariadb-primary-1 replica-1=mysite-mariadb-replica-1-1
#
# One <server> argument per database server of the site. <server> is the label
# every forwarded entry carries in its `server` attribute.
#
# The log forwarder that install-observability.sh runs beside the New Relic agent
# (the newrelic-fluent-bit container) tails each log and ships it to New Relic. A
# Lua filter parses each entry and replaces every literal in the statement with ?,
# so no personal data leaves the host.
#
# <host_slowlog_path> is the log's path on the host and may hold a glob. Left out,
# it is discovered: the host source of the container's /var/lib/mysql mount plus
# /*slow*.log, which matches slow_queries.log, slow-queries.log and MariaDB's
# default <hostname>-slow.log, and not a rotated copy (.log.1, .log.2.gz). Pass
# the path when a data directory holds more than one such file.
#
# Writes, per server, then restarts the forwarder once if anything changed:
#   /opt/observability/newrelic/fluent-bit/pipelines/<site>-<server>-slowlog.conf   Fluent Bit pipeline
#   /etc/logrotate.d/<site>-<server>-slowlog                                         size-capped rotation
#
# Needs install-observability.sh --provider=newrelic to have run first: that
# installs the forwarder, and the filter and parser files the pipelines point at.
#############################################

set -euo pipefail

OBS_OPT_DIR="${OBS_OPT_DIR:-/opt/observability}"
LOGROTATE_DIR="${LOGROTATE_DIR:-/etc/logrotate.d}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${TEMPLATE_DIR:-$(dirname "$SCRIPT_DIR")/templates}"
OBS_TEMPLATE_DIR="$TEMPLATE_DIR/observability"
PIPELINES_DIR="$OBS_OPT_DIR/newrelic/fluent-bit/pipelines"
FORWARDER=newrelic-fluent-bit

SITE="${1:-}"
shift || true
USAGE="Usage: $0 <site_name> <server>=<container>[=<host_slowlog_path>] ..."

die() {
    echo "[ERROR] $1" >&2
    exit 1
}

changed=false

# render <template> <destination>: substitute the placeholders, install the
# result, and note whether it differs from what was there. Uses SERVER and
# SLOWLOG from setup_server.
render() {
    local src="$OBS_TEMPLATE_DIR/$1" dst="$2" tmp
    [[ -f "$src" ]] || die "Missing template: $src"
    tmp=$(mktemp)
    sed -e "s|{{SITE}}|$SITE|g" -e "s|{{SERVER}}|$SERVER|g" -e "s|{{SLOWLOG_PATH}}|$SLOWLOG|g" "$src" > "$tmp"
    if ! cmp -s "$tmp" "$dst" 2> /dev/null; then
        install -m 644 "$tmp" "$dst"
        changed=true
        echo "[INFO] Wrote $dst"
    fi
    rm -f "$tmp"
}

# setup_server <server>=<container>[=<path>]: validate one server argument and
# render its two files.
setup_server() {
    local spec="$1" container datadir
    [[ "$spec" == *=* ]] || die "Invalid server argument '$spec' ($USAGE)"
    SERVER="${spec%%=*}"
    container="${spec#*=}"
    SLOWLOG=""
    if [[ "$container" == *=* ]]; then
        SLOWLOG="${container#*=}"
        container="${container%%=*}"
    fi
    [[ "$SERVER" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "Invalid server name '$SERVER' (lowercase letters, digits, - and _)"
    [[ "$container" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "Invalid container name '$container'"

    if [[ -z "$SLOWLOG" ]]; then
        datadir=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/mysql"}}{{.Source}}{{end}}{{end}}' "$container" 2> /dev/null || true)
        [[ -n "$datadir" ]] || die "Container '$container' has no /var/lib/mysql mount to find the slow log in; pass the host path"
        SLOWLOG="$datadir/*slow*.log"
    fi
    # The path is substituted into config files, so it is limited to path
    # characters and glob wildcards.
    [[ "$SLOWLOG" =~ ^/[A-Za-z0-9_./*?-]+$ ]] || die "Invalid slow log path '$SLOWLOG'"

    render newrelic.slowlog.conf.template "$PIPELINES_DIR/$SITE-$SERVER-slowlog.conf"
    render newrelic.slowlog.logrotate.template "$LOGROTATE_DIR/$SITE-$SERVER-slowlog"
}

[[ -n "$SITE" && $# -gt 0 ]] || die "$USAGE"
[[ "$SITE" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "Invalid site name '$SITE' (lowercase letters, digits, - and _)"
[[ -d "$PIPELINES_DIR" ]] || die "$PIPELINES_DIR not found - run install-observability.sh --provider=newrelic first"

for spec in "$@"; do
    setup_server "$spec"
done

if [[ "$changed" == true ]]; then
    # Fluent Bit reads its pipelines only at start. The agent is not restarted.
    docker restart "$FORWARDER" > /dev/null || die "Could not restart $FORWARDER - check: docker logs $FORWARDER"
    echo "[INFO] Restarted $FORWARDER to load the pipeline"
else
    echo "[INFO] Slow log forwarding for $SITE already up to date"
fi
