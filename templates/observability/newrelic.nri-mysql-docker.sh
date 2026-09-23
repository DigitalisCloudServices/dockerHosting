#!/bin/sh
# nri-mysql for a MySQL/MariaDB container on a Docker-internal network.
# Managed by dockerHosting — do not edit by hand.
#
# The agent runs on the host network and can reach a container's bridge IP,
# but its docker discovery finds no IP for a container attached only to
# user-defined networks, and those IPs change when a container is recreated.
# So resolve the IP on MARIADB_NETWORK from the Docker API on every run.
#
# A site's integration config (integrations.d/<site>-mysql.yml) runs it as
#   exec: [/bin/sh, /etc/newrelic-infra/bin/nri-mysql-docker.sh]
# with, besides nri-mysql's own settings (USERNAME, PORT, ENABLE_TLS, ...):
#   MARIADB_CONTAINER      container name
#   MARIADB_NETWORK        Docker network to take its IP from
#   MARIADB_PASSWORD_FILE  file under /etc/newrelic-infra/secrets.d holding
#                          the password, so it stays out of the config
set -eu

NRI_MYSQL="${NRI_MYSQL:-/var/db/newrelic-infra/newrelic-integrations/bin/nri-mysql}"

# The API answers on one line; take the first IPAddress after the network's key.
ip=$(curl -sf --unix-socket /var/run/docker.sock \
    "http://docker/v1.44/containers/${MARIADB_CONTAINER}/json" |
    sed -n "s/.*\"${MARIADB_NETWORK}\":{//p" |
    grep -o '"IPAddress":"[0-9][0-9.]*"' | head -n 1 | cut -d '"' -f 4) || true
if [ -z "$ip" ]; then
    echo "no IP for ${MARIADB_CONTAINER} on ${MARIADB_NETWORK}" >&2
    exit 1
fi

HOSTNAME=$ip
PASSWORD=$(cat "$MARIADB_PASSWORD_FILE")
export HOSTNAME PASSWORD
exec "$NRI_MYSQL"
