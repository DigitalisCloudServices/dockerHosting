#!/usr/bin/env bats
# Tests for templates/observability/newrelic.nri-mysql-docker.sh
#
# The New Relic agent runs on the host network, and its docker discovery finds
# no IP for a container attached only to user-defined networks. The wrapper
# resolves the container's IP on a named network from the Docker API on every
# run, reads the password from a file, and execs nri-mysql.

load 'helpers/common'

WRAPPER="$TEMPLATES_DIR/observability/newrelic.nri-mysql-docker.sh"

setup() {
    setup_mocks

    # Docker API answer for GET /containers/<name>/json, trimmed to the parts
    # the wrapper reads. The container sits on two networks; the top-level
    # IPAddress is empty, as it is for user-defined networks.
    export DOCKER_JSON="$BATS_TEST_TMPDIR/container.json"
    printf '%s' '{"Name":"/site-mariadb-primary-1","NetworkSettings":{"IPAddress":"","Networks":{"site_net_db_admin":{"IPAMConfig":{},"Gateway":"10.99.7.1","IPAddress":"10.99.7.2"},"site_net_db_cluster":{"IPAMConfig":null,"Gateway":"10.99.4.1","IPAddress":"10.99.4.3"}}}}' > "$DOCKER_JSON"
    create_mock_with_body curl 'echo "$*" >> "$BATS_TEST_TMPDIR/curl.log"; cat "$DOCKER_JSON"'

    # Stand-in for nri-mysql: report what it was started with.
    export NRI_MYSQL="$MOCK_BIN/nri-mysql"
    create_mock_with_body nri-mysql 'echo "HOSTNAME=$HOSTNAME PASSWORD=$PASSWORD USERNAME=$USERNAME"'

    export MARIADB_PASSWORD_FILE="$BATS_TEST_TMPDIR/password"
    printf 's3cret' > "$MARIADB_PASSWORD_FILE"
    export MARIADB_CONTAINER=site-mariadb-primary-1
    export MARIADB_NETWORK=site_net_db_cluster
    export USERNAME=newrelic
}

teardown() {
    teardown_mocks
}

@test "nri-mysql-docker: connects to the container's IP on the named network" {
    run sh "$WRAPPER"
    [ "$status" -eq 0 ]
    [ "$output" = "HOSTNAME=10.99.4.3 PASSWORD=s3cret USERNAME=newrelic" ]
}

@test "nri-mysql-docker: another network on the same container picks its own IP" {
    MARIADB_NETWORK=site_net_db_admin run sh "$WRAPPER"
    [ "$status" -eq 0 ]
    [ "${output%% *}" = "HOSTNAME=10.99.7.2" ]
}

@test "nri-mysql-docker: asks the Docker socket about the named container" {
    sh "$WRAPPER"
    assert_file_contains "$BATS_TEST_TMPDIR/curl.log" '--unix-socket /var/run/docker.sock'
    assert_file_contains "$BATS_TEST_TMPDIR/curl.log" '/containers/site-mariadb-primary-1/json'
}

@test "nri-mysql-docker: fails and names the cause when the container is not on the network" {
    MARIADB_NETWORK=site_net_elsewhere run sh "$WRAPPER"
    [ "$status" -ne 0 ]
    [ "$(grep -c 'no IP for site-mariadb-primary-1 on site_net_elsewhere' <<< "$output")" -eq 1 ]
    [ "$(grep -c 'HOSTNAME=' <<< "$output")" -eq 0 ]
}

@test "nri-mysql-docker: fails when Docker does not know the container" {
    create_mock_with_body curl 'exit 22'
    run sh "$WRAPPER"
    [ "$status" -ne 0 ]
    [ "$(grep -c 'no IP for site-mariadb-primary-1' <<< "$output")" -eq 1 ]
}
