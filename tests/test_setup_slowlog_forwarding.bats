#!/usr/bin/env bats
# Tests for scripts/setup-slowlog-forwarding.sh and the config templates it
# renders (newrelic.slowlog.{conf,logrotate}.template, newrelic.slowlog.parsers.conf).
# The filter itself is covered by test_slowlog_forwarder.bats.

load 'helpers/common'

SCRIPT="$SCRIPTS_DIR/setup-slowlog-forwarding.sh"
PARSERS="$TEMPLATES_DIR/observability/newrelic.slowlog.parsers.conf"
FIXTURE="$REPO_ROOT/tests/fixtures/mariadb-11.8-slow.log"

setup() {
    setup_mocks
    export OBS_OPT_DIR="$BATS_TEST_TMPDIR/opt/observability"
    export LOGROTATE_DIR="$BATS_TEST_TMPDIR/etc/logrotate.d"
    export TEMPLATE_DIR="$TEMPLATES_DIR"
    PIPELINES_DIR="$OBS_OPT_DIR/newrelic/fluent-bit/pipelines"
    mkdir -p "$PIPELINES_DIR" "$LOGROTATE_DIR"

    export SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    create_call_log_mock systemctl "$SYSTEMCTL_LOG"
    # Every docker call is logged. docker inspect -f <template> <container>
    # answers as if /var/lib/mysql is a named volume on the host; docker restart
    # fails when MOCK_RESTART_FAILS is set.
    create_mock_with_body docker 'echo "$*" >> "$BATS_TEST_TMPDIR/docker.log"
case "$1" in
    restart) [ -z "${MOCK_RESTART_FAILS:-}" ] || exit 1; echo "$2" ;;
    *) printf "%s" "${MOCK_DATADIR-/var/lib/docker/volumes/mysite_dbdata/_data}" ;;
esac'
    DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
}

teardown() {
    teardown_mocks
}

@test "slowlog setup: renders the pipeline and rotation for a discovered log" {
    run bash "$SCRIPT" mysite primary=mysite-mariadb-primary-1
    [ "$status" -eq 0 ]

    assert_file_contains "$BATS_TEST_TMPDIR/docker.log" 'inspect'
    assert_file_contains "$BATS_TEST_TMPDIR/docker.log" 'mysite-mariadb-primary-1'

    conf="$PIPELINES_DIR/mysite-primary-slowlog.conf"
    assert_file_contains "$conf" 'Path              /host/var/lib/docker/volumes/mysite_dbdata/_data/*slow*.log'
    assert_file_contains "$conf" 'Tag               mariadb.slowlog.mysite.primary'
    assert_file_contains "$conf" 'Multiline.Parser  mariadb-slowlog'
    assert_file_contains "$conf" 'script            /fluent-bit/etc/mariadb-slowlog.lua'
    assert_file_contains "$conf" 'call              slowlog_clean'
    assert_file_contains "$conf" 'Record            site mysite'
    assert_file_contains "$conf" 'Record            server primary'
    assert_file_contains "$conf" 'Skip_Long_Lines   On'
    assert_file_contains "$conf" 'Mem_Buf_Limit     8M'
    assert_file_contains "$conf" 'DB                /var/lib/fluent-bit/mariadb-slowlog-mysite-primary.db'
    ! grep -q '{{' "$conf" "$LOGROTATE_DIR/mysite-primary-slowlog"
    # Only the pipeline: the agent's logging.d is gone.
    [ "$(ls "$PIPELINES_DIR")" = "mysite-primary-slowlog.conf" ]
    [ ! -e "$OBS_OPT_DIR/newrelic/logging.d" ]

    rot="$LOGROTATE_DIR/mysite-primary-slowlog"
    assert_file_contains "$rot" '/var/lib/docker/volumes/mysite_dbdata/_data/*slow*.log {'
    assert_file_contains "$rot" 'maxsize 100M'
    assert_file_contains "$rot" 'copytruncate'
    assert_file_contains "$rot" 'rotate 3'

    # The forwarder is restarted, the agent is not.
    assert_file_contains "$DOCKER_LOG" 'restart newrelic-fluent-bit'
    [ ! -f "$SYSTEMCTL_LOG" ]
}

@test "slowlog setup: the discovery glob matches the primary and replica log names but not a rotated copy" {
    run python3 -c "
import fnmatch
for n in ('slow_queries.log', 'slow-queries.log', 'db1-slow.log'):
    assert fnmatch.fnmatch(n, '*slow*.log'), n
for n in ('slow_queries.log.1', 'slow_queries.log.2.gz', 'ib_buffer_pool'):
    assert not fnmatch.fnmatch(n, '*slow*.log'), n
"
    [ "$status" -eq 0 ]
}

@test "slowlog setup: an explicit path skips discovery" {
    run bash "$SCRIPT" mysite primary=mysite-mariadb-primary-1=/srv/db/slow-queries.log
    [ "$status" -eq 0 ]
    run grep -c inspect "$DOCKER_LOG"
    [ "$output" = "0" ]
    assert_file_contains "$PIPELINES_DIR/mysite-primary-slowlog.conf" 'Path              /host/srv/db/slow-queries.log'
    assert_file_contains "$LOGROTATE_DIR/mysite-primary-slowlog" '/srv/db/slow-queries.log {'
}

@test "slowlog setup: several servers of one site get their own files, tags and a single restart" {
    run bash "$SCRIPT" mysite primary=db-p=/srv/p/slow_queries.log replica-1=db-r1=/srv/r1/slow-queries.log
    [ "$status" -eq 0 ]
    assert_file_contains "$PIPELINES_DIR/mysite-primary-slowlog.conf" 'Record            server primary'
    assert_file_contains "$PIPELINES_DIR/mysite-primary-slowlog.conf" '/host/srv/p/slow_queries.log'
    assert_file_contains "$PIPELINES_DIR/mysite-replica-1-slowlog.conf" 'Record            server replica-1'
    assert_file_contains "$PIPELINES_DIR/mysite-replica-1-slowlog.conf" 'Tag               mariadb.slowlog.mysite.replica-1'
    assert_file_contains "$PIPELINES_DIR/mysite-replica-1-slowlog.conf" '/host/srv/r1/slow-queries.log'
    assert_file_exists "$LOGROTATE_DIR/mysite-replica-1-slowlog"
    [ "$(grep -c 'restart newrelic-fluent-bit' "$DOCKER_LOG")" -eq 1 ]
}

@test "slowlog setup: a second run changes nothing and does not restart the forwarder" {
    bash "$SCRIPT" mysite primary=mysite-mariadb-primary-1
    rm -f "$DOCKER_LOG"
    run bash "$SCRIPT" mysite primary=mysite-mariadb-primary-1
    [ "$status" -eq 0 ]
    [[ "$output" == *"already up to date"* ]]
    run grep -c restart "$DOCKER_LOG"
    [ "$output" = "0" ]
}

@test "slowlog setup: a changed path rewrites and restarts" {
    bash "$SCRIPT" mysite primary=mysite-mariadb-primary-1
    rm -f "$DOCKER_LOG"
    run bash "$SCRIPT" mysite primary=mysite-mariadb-primary-1=/srv/db/other-slow.log
    [ "$status" -eq 0 ]
    assert_file_contains "$DOCKER_LOG" 'restart newrelic-fluent-bit'
}

@test "slowlog setup: fails loudly when the forwarder cannot be restarted" {
    MOCK_RESTART_FAILS=1 run bash "$SCRIPT" mysite primary=c=/srv/a/slow.log
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not restart newrelic-fluent-bit"* ]]
}

@test "slowlog setup: two sites keep separate configs" {
    bash "$SCRIPT" alpha primary=alpha-db=/srv/a/slow.log
    bash "$SCRIPT" beta primary=beta-db=/srv/b/slow.log
    assert_file_contains "$PIPELINES_DIR/alpha-primary-slowlog.conf" '/host/srv/a/slow.log'
    assert_file_contains "$PIPELINES_DIR/beta-primary-slowlog.conf" '/host/srv/b/slow.log'
}

@test "slowlog setup: usage error when arguments are missing" {
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
    run bash "$SCRIPT" mysite
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "slowlog setup: rejects a server argument without a container" {
    run bash "$SCRIPT" mysite primary
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid server argument"* ]]
}

@test "slowlog setup: rejects a site, server or container name that is not a plain name" {
    run bash "$SCRIPT" 'My Site' primary=c
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid site name"* ]]
    run bash "$SCRIPT" mysite 'Prim ary=c'
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid server name"* ]]
    run bash "$SCRIPT" mysite 'primary=c|x'
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid container name"* ]]
}

@test "slowlog setup: rejects a path with characters that could escape the config" {
    run bash "$SCRIPT" mysite 'primary=c=/srv/a|b'
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid slow log path"* ]]
    run bash "$SCRIPT" mysite 'primary=c=relative/slow.log'
    [ "$status" -eq 1 ]
}

@test "slowlog setup: stops when the forwarder is not installed" {
    rmdir "$PIPELINES_DIR"
    run bash "$SCRIPT" mysite primary=c=/srv/a/slow.log
    [ "$status" -eq 1 ]
    [[ "$output" == *"install-observability.sh --provider=newrelic first"* ]]
}

@test "slowlog setup: stops when the container has no data mount to look in" {
    MOCK_DATADIR='' run bash "$SCRIPT" mysite primary=mysite-mariadb-primary-1
    [ "$status" -eq 1 ]
    [[ "$output" == *"no /var/lib/mysql mount"* ]]
}

@test "slowlog setup: stops when docker cannot inspect the container" {
    create_mock_with_body docker 'exit 1'
    run bash "$SCRIPT" mysite primary=missing-container
    [ "$status" -eq 1 ]
    [[ "$output" == *"no /var/lib/mysql mount"* ]]
}

@test "slowlog setup: stops when a template is missing" {
    export TEMPLATE_DIR="$BATS_TEST_TMPDIR/empty"
    mkdir -p "$TEMPLATE_DIR/observability"
    run bash "$SCRIPT" mysite primary=c=/srv/a/slow.log
    [ "$status" -eq 1 ]
    [[ "$output" == *"Missing template"* ]]
}

# ── the multiline parser rules ───────────────────────────────────────────────

@test "slowlog parser: a record starts at each User@Host line and takes every other line" {
    # Fluent Bit evaluates the rules in Onigmo; Python's re agrees on these
    # patterns (literal prefix, one negative lookahead).
    run python3 - "$PARSERS" "$FIXTURE" <<'PY'
import re, sys
rules = {}
for line in open(sys.argv[1]):
    m = re.match(r'\s*rule\s+"(\w+)"\s+"/(.*)/"\s+"(\w+)"', line)
    if m:
        rules[m.group(1)] = (re.compile(m.group(2)), m.group(3))
start, nxt = rules["start_state"]
cont, loop = rules[nxt]
assert loop == nxt, "the continuation state must continue itself"
starts = other = 0
for line in open(sys.argv[2]).read().split("\n")[:-1]:
    if start.match(line):
        assert not cont.match(line), line
        starts += 1
    else:
        assert cont.match(line), line
        other += 1
print(starts, other)
PY
    [ "$status" -eq 0 ]
    # 7 entries in the fixture.
    [ "${output%% *}" = "7" ]
}

@test "slowlog parser: is a named multiline parser with a flush timeout" {
    assert_file_contains "$PARSERS" 'name          mariadb-slowlog'
    assert_file_contains "$PARSERS" 'type          regex'
    assert_file_contains "$PARSERS" 'flush_timeout 2000'
}
