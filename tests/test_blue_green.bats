#!/usr/bin/env bats
# Blue/green behaviour of lib/update-site.sh (VelaAir F2040, lib/update-site-bluegreen.sh).
#
# docker is a stub that logs every call and answers the few queries the updater
# makes from fixture files; the project's deploy-blue-green.sh is a stub that
# logs into the same file, so the tests assert the exact call sequence.  The
# tests marked "channel" run the real download path with curl stubbed and need
# Linux tools (md5sum, GNU stat), like tests/lib/test_gcs.bats.

load 'helpers/common'

UPDATE_SITE="${REPO_ROOT}/lib/update-site.sh"
BG_LIB="${REPO_ROOT}/lib/update-site-bluegreen.sh"

setup() {
    setup_mocks
    PROJ="$BATS_TEST_TMPDIR/site"
    CALLS="$BATS_TEST_TMPDIR/calls.log"
    : > "$CALLS"
    mkdir -p "${PROJ}/infra/scripts" "${PROJ}/infra/hooks" "${PROJ}/secrets" "${PROJ}/artifact-cache"
    touch "${PROJ}/docker-compose.yml"
    cat > "${PROJ}/.env" <<'ENV'
GCS_BUCKET=gs://fake-bucket
RELEASE_CHANNEL=main-latest
INFRA_HASH=aabbccdd1122
ENV
    echo '{}' > "${PROJ}/secrets/gcs_service_account.json"

    # Merged compose config: api and web are the blue/green services.
    COMPOSE_JSON="$BATS_TEST_TMPDIR/config.json"
    cat > "$COMPOSE_JSON" <<'JSON'
{"services": {
  "vault": {},
  "kong": {},
  "api": {"labels": {"artifact": "api", "com.velaair.bluegreen": "true"}},
  "web": {"labels": ["artifact=web", "com.velaair.bluegreen=true"]},
  "worker-ingest": {"labels": {"artifact": "worker"}}
}}
JSON
    SERVICES="$BATS_TEST_TMPDIR/services"
    printf 'vault\nkong\napi\nweb\nworker-ingest\n' > "$SERVICES"
    RUNNING="$BATS_TEST_TMPDIR/running"
    cp "$SERVICES" "$RUNNING"
    export CALLS COMPOSE_JSON SERVICES RUNNING

    create_mock_with_body docker '
echo "docker $*" >> "$CALLS"
case "$*" in
    *"config --format json"*) cat "$COMPOSE_JSON" ;;
    *"config --services"*) cat "$SERVICES" ;;
    *"ps --services --status running"*) cat "$RUNNING" ;;
esac
exit 0'

    # Hook that records that post-start ran.
    echo '{"hooks":[{"script":"infra/hooks/post.sh","trigger":"update","phase":"post-start"}]}' \
        > "${PROJ}/infra/lifecycle-hooks.json"
    printf '#!/bin/bash\necho "hook post-start" >> "%s"\n' "$CALLS" > "${PROJ}/infra/hooks/post.sh"
}

# The project's switch-over script: logs its arguments, exits with BG_RC.
_install_bg_script() {
    printf '#!/bin/bash\necho "bg $*" >> "%s"\nexit "${BG_RC:-0}"\n' "$CALLS" \
        > "${PROJ}/infra/scripts/deploy-blue-green.sh"
}

# Fail when the call log has a line matching extended regex $1.
_never_logged() { if grep -qE -- "$1" "$CALLS"; then cat "$CALLS"; return 1; fi; }

_enable_bg() { echo 'BLUE_GREEN_ENABLED=true' >> "${PROJ}/.env"; }

_update() { run bash "$UPDATE_SITE" "$PROJ" "$@"; }

_docker_calls() { grep -E '^docker compose .* (up|ps --services) ' "$CALLS" | sed "s|--project-directory ${PROJ} --env-file ${PROJ}/.env ||"; }

# ── disabled: unchanged ───────────────────────────────────────────────────────

@test "bluegreen off: --force recreates every service but vault, no switch-over" {
    _install_bg_script
    _update --skip-artifact-download --force
    [ "$status" -eq 0 ]
    [ "$(_docker_calls)" = "docker compose up -d --force-recreate kong api web worker-ingest" ]
    _never_logged '^bg '
    [[ "$output" != *"lue/green"* ]]
}

@test "bluegreen off: flag false with the script present behaves like unset" {
    _install_bg_script
    echo 'BLUE_GREEN_ENABLED=false' >> "${PROJ}/.env"
    _update --skip-artifact-download --force
    [ "$status" -eq 0 ]
    [ "$(_docker_calls)" = "docker compose up -d --force-recreate kong api web worker-ingest" ]
    _never_logged '^bg '
}

@test "bluegreen off: flag true but the script absent behaves like unset" {
    _enable_bg
    _update --skip-artifact-download --force
    [ "$status" -eq 0 ]
    [ "$(_docker_calls)" = "docker compose up -d --force-recreate kong api web worker-ingest" ]
    _never_logged 'config --format json'
}

@test "bluegreen off: bootstrap recovery is a plain up -d" {
    _install_bg_script
    grep -v '^kong$' "$SERVICES" > "$RUNNING"
    _update --trigger bootstrap --skip-artifact-download
    [ "$status" -eq 0 ]
    [ "$(_docker_calls | grep ' up ')" = "docker compose up -d" ]
}

# ── enabled: labelled services are never recreated in place ───────────────────

@test "bluegreen on: infra-stale path leaves api and web out, then switches them over" {
    _install_bg_script
    _enable_bg
    _update --skip-artifact-download --force
    [ "$status" -eq 0 ]
    [ "$(_docker_calls | grep ' up ')" = "docker compose up -d --force-recreate --no-deps kong worker-ingest" ]
    # the switch-over comes after the recreate and before the post-start hook
    [ "$(grep -E '^(bg|hook)|compose .* up ' "$CALLS" | sed 's/docker compose.* up /up /')" = "$(printf '%s\n' \
        'up -d --force-recreate --no-deps kong worker-ingest' \
        'bg deploy --auto --services api web --force' \
        'hook post-start')" ]
}

@test "bluegreen on: --force passes --force to the switch-over, a plain infra update does not" {
    _install_bg_script
    _enable_bg
    _update --skip-artifact-download --force
    grep -qxF 'bg deploy --auto --services api web --force' "$CALLS"
}

@test "bluegreen on: a failing switch-over fails the update and skips post-start hooks" {
    _install_bg_script
    _enable_bg
    BG_RC=3 _update --skip-artifact-download --force
    [ "$status" -ne 0 ]
    [[ "$output" == *"switch-over failed (exit 3)"* ]]
    [[ "$output" == *"keep serving"* ]]
    _never_logged '^hook '
}

@test "bluegreen on: a stopped labelled service is started directly and not switched" {
    _install_bg_script
    _enable_bg
    grep -v '^api$' "$SERVICES" > "$RUNNING"
    _update --skip-artifact-download --force
    [ "$status" -eq 0 ]
    [ "$(_docker_calls | grep ' up ')" = "$(printf '%s\n' \
        'docker compose up -d api' \
        'docker compose up -d --force-recreate --no-deps kong worker-ingest')" ]
    grep -qxF 'bg deploy --auto --services web --force' "$CALLS"
}

@test "bluegreen on: bootstrap recovery brings up everything but api and web, starting them first when down" {
    _install_bg_script
    _enable_bg
    grep -vE '^(kong|api)$' "$SERVICES" > "$RUNNING"
    _update --trigger bootstrap --skip-artifact-download
    [ "$status" -eq 0 ]
    [ "$(_docker_calls | grep ' up ')" = "$(printf '%s\n' \
        'docker compose up -d api' \
        'docker compose up -d --no-deps vault kong worker-ingest')" ]
    # nothing stale: no switch-over
    _never_logged '^bg '
}

@test "bluegreen on: nothing stale and nothing to start does nothing" {
    _install_bg_script
    _enable_bg
    _update --skip-artifact-download
    [ "$status" -eq 0 ]
    _never_logged ' up |^bg '
}

# ── --dry-run and --pull-only ─────────────────────────────────────────────────

@test "bluegreen on: --dry-run reports the switch-over and changes nothing" {
    _install_bg_script
    _enable_bg
    _update --skip-artifact-download --force --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would switch over (blue/green, no in-place recreate): api web"* ]]
    _never_logged ' up |^bg '
}

@test "bluegreen off: --dry-run output has no blue/green line and makes no docker call" {
    _install_bg_script
    _update --skip-artifact-download --force --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" != *"lue/green"* ]]
    [ ! -s "$CALLS" ]
}

@test "bluegreen on: --pull-only does nothing new" {
    _install_bg_script
    _enable_bg
    _update --skip-artifact-download --force --pull-only
    [ "$status" -eq 0 ]
    [ ! -s "$CALLS" ]
}

@test "bluegreen on: flag set but no service carries the label updates in place with a warning" {
    _install_bg_script
    _enable_bg
    echo '{"services": {"kong": {}, "api": {"labels": {"artifact": "api"}}}}' > "$COMPOSE_JSON"
    printf 'kong\napi\n' > "$SERVICES"
    _update --skip-artifact-download --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"no service carries the com.velaair.bluegreen label"* ]]
    [ "$(_docker_calls | grep ' up ')" = "docker compose up -d --force-recreate kong api" ]
    _never_logged '^bg '
}

# ── library functions ─────────────────────────────────────────────────────────

# Run snippet $1 with the library loaded and update-site.sh's state faked.
_lib() {
    run bash -c "
        set -euo pipefail
        _log() { :; }; _warn() { echo \"WARN: \$*\" >&2; }; _fail() { echo \"FATAL: \$*\" >&2; exit 1; }
        PROJECT_DIR='$PROJ'; DOTENV='$PROJ/.env'; BLUEGREEN_SH='$PROJ/infra/scripts/deploy-blue-green.sh'; FORCE=false; INFRA_STALE=false
        ARTIFACT_NAMES=(); ARTIFACT_STALE=()
        _dotenv_get() { grep -E \"^\$1=\" '$PROJ/.env' | cut -d= -f2- || true; }
        source '$BG_LIB'
        $1"
}

@test "lib: _services_with_label reads dict and list labels" {
    _lib '_services_with_label com.velaair.bluegreen true | tr "\n" " "'
    [ "$status" -eq 0 ]
    [ "$output" = "api web " ]
    _lib '_services_with_label artifact worker'
    [ "$output" = "worker-ingest" ]
}

@test "lib: _services_with_label prints nothing when compose config fails" {
    create_mock_with_body docker 'exit 1'
    _lib '_services_with_label artifact api'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "lib: switch list is the stale artifacts' labelled services only" {
    _install_bg_script
    _enable_bg
    _lib '
        _services_for_artifact() { case "$1" in api) echo api;; web) echo web;; worker) echo worker-ingest;; esac; }
        _bluegreen_init
        ARTIFACT_NAMES=(api web worker); ARTIFACT_STALE=(true false true)
        echo "[$(_bluegreen_switch_list)]"
        ARTIFACT_STALE=(false false true)
        echo "[$(_bluegreen_switch_list)]"
        INFRA_STALE=true
        echo "[$(_bluegreen_switch_list)]"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "[api ]" ]
    [ "${lines[1]}" = "[]" ]
    [ "${lines[2]}" = "[api web ]" ]
}

@test "lib: _without_bluegreen drops only the labelled services" {
    _install_bg_script
    _enable_bg
    _lib '_bluegreen_init; _without_bluegreen vault api kong web worker-ingest'
    [ "$output" = "vault kong worker-ingest " ]
}

# ── channel path: artifact-stale (real download code, curl stubbed) ───────────

# Linux only (md5sum, GNU stat for the GCS token cache).  A fresh token cache
# entry means no OAuth call; curl serves the channel metadata and empty tarballs.
_channel_setup() {
    [[ "$(uname)" == "Linux" ]] || skip "needs Linux md5sum/stat (token cache)"
    local key
    key="$(printf '%s' "${PROJ}/secrets/gcs_service_account.json" | md5sum | cut -c1-16)"
    TOKEN_CACHE="/tmp/.gcs_token_${key}"
    printf 'tok' > "$TOKEN_CACHE"
    mkdir -p "$BATS_TEST_TMPDIR/empty"
    tar -czf "$BATS_TEST_TMPDIR/empty.tar.gz" -C "$BATS_TEST_TMPDIR/empty" .
    cat > "$BATS_TEST_TMPDIR/channel.json" <<'JSON'
{"infra": {"git_hash": "aabbccdd1122", "signed": false, "encrypted": false,
           "type": "http", "url": "http://x/infra-aabbccdd1122.tar.gz"},
 "artifacts": [
  {"name": "api", "git_hash": "newapi", "signed": false, "encrypted": false,
   "type": "http", "url": "http://x/api-newapi.tar.gz"},
  {"name": "worker", "git_hash": "newworker", "signed": false, "encrypted": false,
   "type": "http", "url": "http://x/worker-newworker.tar.gz"}]}
JSON
    export EMPTY_TAR="$BATS_TEST_TMPDIR/empty.tar.gz" CHANNEL_JSON="$BATS_TEST_TMPDIR/channel.json"
    create_mock_with_body curl '
out=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-o" ]] && out="$2"; shift; done
if [[ -n "$out" ]]; then cp "$EMPTY_TAR" "$out"; else cat "$CHANNEL_JSON"; fi'
    printf 'API_GIT_HASH=oldapi\nWORKER_GIT_HASH=oldworker\n' >> "${PROJ}/.env"
}

teardown() { rm -f "${TOKEN_CACHE:-}"; }

@test "channel, bluegreen off: stale artifacts recreate their services in place" {
    _channel_setup
    _install_bg_script
    _update
    [ "$status" -eq 0 ]
    [ "$(_docker_calls | grep ' up ')" = "docker compose up -d --force-recreate api worker-ingest" ]
    _never_logged '^bg '
}

@test "channel, bluegreen on: stale artifact path recreates only unlabelled services, then switches" {
    _channel_setup
    _install_bg_script
    _enable_bg
    _update
    [ "$status" -eq 0 ]
    [ "$(_docker_calls | grep ' up ')" = "docker compose up -d --force-recreate --no-deps worker-ingest" ]
    [ "$(grep -E '^(bg|hook)' "$CALLS")" = "$(printf '%s\n' 'bg deploy --auto --services api' 'hook post-start')" ]
}

@test "channel, bluegreen on: only a labelled service stale means no recreate at all" {
    _channel_setup
    _install_bg_script
    _enable_bg
    sed -i 's/^WORKER_GIT_HASH=.*/WORKER_GIT_HASH=newworker/' "${PROJ}/.env"
    _update
    [ "$status" -eq 0 ]
    _never_logged ' up '
    [[ "$output" != *"No labeled services"* ]]
    grep -qxF 'bg deploy --auto --services api' "$CALLS"
}

@test "channel, bluegreen on: dry-run names the labelled services it would switch" {
    _channel_setup
    _install_bg_script
    _enable_bg
    _update --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would switch over (blue/green, no in-place recreate): api"* ]]
    _never_logged ' up |^bg '
}
