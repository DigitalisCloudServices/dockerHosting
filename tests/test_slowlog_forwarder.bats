#!/usr/bin/env bats
# Tests for the MariaDB slow-log filter, templates/observability/newrelic.slowlog.lua.
#
# The filter is the real file, run under LuaJIT (the Lua inside Fluent Bit) by
# tests/helpers/slowlog_run.lua. Fluent Bit itself is not run: the helper cuts
# the log into records the way the mariadb-slowlog multiline parser does, so the
# parser rules (templates/observability/newrelic.slowlog.parsers.conf) are
# covered by the config checks in test_setup_slowlog_forwarding.bats instead.

load 'helpers/common'

FILTER="$TEMPLATES_DIR/observability/newrelic.slowlog.lua"
RUNNER="$REPO_ROOT/tests/helpers/slowlog_run.lua"
FIXTURE="$REPO_ROOT/tests/fixtures/mariadb-11.8-slow.log"

setup() {
    LUA_BIN="$(command -v luajit || command -v lua5.1 || command -v lua || true)"
    [ -n "$LUA_BIN" ] || { echo "luajit (or lua) is required for the slow-log filter tests" >&2; return 1; }
}

# norm SQL: the filter's normalised text for SQL.
norm() {
    printf '%s' "$1" | "$LUA_BIN" "$RUNNER" "$FILTER" normalise
}

@test "slow_log_forwarder_strips_literals: no name or email from a real MariaDB 11.8 log reaches the output" {
    run "$LUA_BIN" "$RUNNER" "$FILTER" file "$FIXTURE"
    [ "$status" -eq 0 ]
    # The fixture really holds them (log_slow_verbosity=query_plan,explain entries).
    grep -q 'Jane Example' "$FIXTURE"
    grep -q 'jane.example@example.com' "$FIXTURE"
    for leak in 'Jane' 'Example' 'jane.example' 'example.com' 'example.org' 'Pat' 'Bloggs' 'Brien' '4a6f65'; do
        ! grep -qi "$leak" <<< "$output"
    done
    # The raw entry is not forwarded, and no explain or header text rides along.
    ! grep -q '^log=' <<< "$output"
    ! grep -q 'explain' <<< "$output"
    ! grep -q 'SET timestamp' <<< "$output"
}

@test "slow_log_forwarder: the multi-row INSERT keeps its shape with every literal replaced" {
    run "$LUA_BIN" "$RUNNER" "$FILTER" file "$FIXTURE"
    grep -qx 'statement=insert into t values (?,?,?);' <<< "$output"
    grep -qx 'statement=update t set name=? where id=? and email like ?;' <<< "$output"
    grep -qx 'statement=select id, count(\*) from t where id IN (?) group by id having count(\*) > ?;' <<< "$output"
    grep -qx 'statement=select ? as a from t where name = ?;' <<< "$output"
}

@test "slow_log_forwarder: an entry becomes attributes" {
    run "$LUA_BIN" "$RUNNER" "$FILTER" file "$FIXTURE"
    block=$(awk '/^ts=1791400924/{n++} n==2' <<< "$output" | sed '/^---$/q')
    grep -qx 'ts=1791400924' <<< "$block"
    grep -qx 'logtype=mariadb-slow-query' <<< "$block"
    grep -qx 'query_time=0.001381' <<< "$block"
    grep -qx 'lock_time=0.000164' <<< "$block"
    grep -qx 'rows_sent=0' <<< "$block"
    grep -qx 'rows_examined=0' <<< "$block"
    grep -qx 'user=root' <<< "$block"
    grep -qx 'schema=d' <<< "$block"
    grep -Eqx 'digest=[0-9a-f]{16}' <<< "$block"
    grep -qx 'message=insert into t values (?,?,?);' <<< "$block"
}

@test "slow_log_forwarder: an entry with no schema reports an empty schema" {
    run "$LUA_BIN" "$RUNNER" "$FILTER" file "$FIXTURE"
    grep -qx 'schema=' <<< "$output"
}

@test "slow_log_forwarder: the restart banner and a bare Time line are dropped" {
    run "$LUA_BIN" "$RUNNER" "$FILTER" file "$FIXTURE"
    [ "$(grep -c '^DROPPED$' <<< "$output")" -eq 4 ]
}

@test "slow_log_forwarder: a banner appended to the previous entry is not statement text" {
    log="$BATS_TEST_TMPDIR/banner.log"
    printf '%s\n' \
        '# User@Host: app[app] @  [10.0.0.5]' \
        '# Thread_id: 9  Schema: shop  QC_hit: No' \
        '# Query_time: 1.5  Lock_time: 0.0  Rows_sent: 1  Rows_examined: 20' \
        'use shop;' \
        'select 1 from t;' \
        'mariadbd, Version: 11.8.9-MariaDB-ubu2404-log (mariadb.org binary distribution). started with:' \
        'Tcp port: 0  Unix socket: /run/mysqld/mysqld.sock' \
        'Time		    Id Command	Argument' > "$log"
    run "$LUA_BIN" "$RUNNER" "$FILTER" file "$log"
    grep -qx 'statement=select ? from t;' <<< "$output"
    grep -qx 'schema=shop' <<< "$output"
    # No SET timestamp in the entry: the record keeps the timestamp it arrived with.
    grep -qx 'ts=0' <<< "$output"
}

@test "slow_log_forwarder: a record without a log string is dropped" {
    run "$LUA_BIN" "$RUNNER" "$FILTER" nolog
    [[ "$output" == "-1	5	table:"* ]]
}

@test "slow_log_forwarder: a record without Query_time is dropped" {
    log="$BATS_TEST_TMPDIR/noqt.log"
    printf '# User@Host: app[app] @  [x]\nselect 1;\n' > "$log"
    run "$LUA_BIN" "$RUNNER" "$FILTER" file "$log"
    [ "$(head -n 1 <<< "$output")" = "DROPPED" ]
}

# ── normalisation rules ──────────────────────────────────────────────────────

@test "normalise: empty input" {
    [ "$(norm '')" = "" ]
}

@test "normalise: single- and double-quoted strings, doubled quotes and backslash escapes" {
    [ "$(norm "a = 'x' and b = \"y\"")" = "a = ? and b = ?" ]
    [ "$(norm "a = 'it''s Jane' and c = 1")" = "a = ? and c = ?" ]
    [ "$(norm "a = 'it\\'s Jane' and c = 1")" = "a = ? and c = ?" ]
    [ "$(norm 'a = "say ""Jane"""')" = "a = ?" ]
}

@test "normalise: an unterminated string swallows the rest" {
    [ "$(norm "a = 'Jane Example")" = "a = ?" ]
    [ "$(norm "a = 'Jane \\")" = "a = ?" ]
}

@test "normalise: backtick identifiers are kept, even unterminated" {
    [ "$(norm 'select `my col` from `t`')" = 'select `my col` from `t`' ]
    [ "$(norm 'select `unterminated')" = 'select `unterminated' ]
}

@test "normalise: comments are removed" {
    [ "$(norm 'select /* Jane */ 1')" = "select ?" ]
    [ "$(norm 'select 1 /* Jane')" = "select ?" ]
    [ "$(norm 'select 1 # Jane
from t')" = "select ? from t" ]
    [ "$(norm 'select 1 -- Jane
from t')" = "select ? from t" ]
    [ "$(norm 'select 1 -- Jane')" = "select ?" ]
    [ "$(norm 'select 1 --')" = "select ?" ]
}

@test "normalise: two dashes with no space are not a comment" {
    [ "$(norm 'select a--b')" = "select a--b" ]
}

@test "normalise: hex and binary literals" {
    [ "$(norm "a = x'4a6f' and b = X'00' and c = b'0101' and d = B'1'")" = "a = ? and b = ? and c = ? and d = ?" ]
    [ "$(norm 'a = 0x5a and b = 0XfF')" = "a = ? and b = ?" ]
}

@test "normalise: a word that merely starts with x or b is kept" {
    [ "$(norm "select xa, b2, bx from t")" = "select xa, b2, bx from t" ]
    [ "$(norm "select x from t")" = "select x from t" ]
}

@test "normalise: integers, decimals, exponents and signs" {
    [ "$(norm 'a = 12 and b = 1.5 and c = 2e10 and d = 3.5E-2 and e = 4e+1')" = "a = ? and b = ? and c = ? and d = ? and e = ?" ]
    [ "$(norm 'a = -5 and b=-1.5')" = "a = ? and b=?" ]
    [ "$(norm 'x = (1)-2')" = "x = (?)-?" ]
    [ "$(norm 'a-1')" = "a-?" ]
}

@test "normalise: digits inside an identifier are kept" {
    [ "$(norm 'select col1, t2.id from t2')" = "select col1, t2.id from t2" ]
}

@test "normalise: a leading dot or a lone minus is kept" {
    [ "$(norm 'a - b')" = "a - b" ]
}

@test "normalise: IN lists collapse, any case and spacing, but IN-like words do not" {
    [ "$(norm 'a in (1,2,3)')" = "a IN (?)" ]
    [ "$(norm "a IN ( 'x' , 'y' )")" = "a IN (?)" ]
    [ "$(norm 'a IN (1)')" = "a IN (?)" ]
    [ "$(norm 'select bin (1, 2) from t')" = "select bin (?, ?) from t" ]
}

@test "normalise: repeated VALUES tuples collapse to one" {
    [ "$(norm 'insert into t values (1,2),(3,4),(5,6),(7,8),(9,10)')" = "insert into t values (?,?)" ]
    [ "$(norm 'insert into t values (1,2),(3)')" = "insert into t values (?,?),(?)" ]
}

@test "normalise: whitespace collapses and the ends are trimmed" {
    [ "$(norm '
  select   1
   from	t  ')" = "select ? from t" ]
}

@test "normalise: output is capped at 500 characters" {
    long=$(printf 'a%.0s' $(seq 1 600))
    [ "${#long}" -eq 600 ]
    [ "$(norm "select $long")" = "select $(printf 'a%.0s' $(seq 1 493))" ]
}

@test "normalise: is idempotent" {
    once=$(norm "select * from t where a = 'x' and b in (1,2,3)")
    [ "$(norm "$once")" = "$once" ]
}

@test "normalise: other punctuation passes through" {
    [ "$(norm 'select t.a, (b + c) * d from t where e <> f')" = "select t.a, (b + c) * d from t where e <> f" ]
}

# ── digest ───────────────────────────────────────────────────────────────────

@test "digest: same shape gives the same 16 hex characters, another shape another" {
    run "$LUA_BIN" -e "dofile('$FILTER'); print(slowlog_digest('select ?'), slowlog_digest('select ?'), slowlog_digest('select ??'))"
    [ "$status" -eq 0 ]
    read -r a b c <<< "$output"
    [[ "$a" =~ ^[0-9a-f]{16}$ ]]
    [ "$a" = "$b" ]
    [ "$a" != "$c" ]
}
