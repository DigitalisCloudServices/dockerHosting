#!/usr/bin/env bash
# lib/update-site-bluegreen.sh
#
# Blue/green support for update-site.sh (VelaAir F2040), sourced by it.
# Defines functions and their state variables only.
#
# Opt-in: BLUE_GREEN_ENABLED=true in the project's .env AND the project ships
# infra/scripts/deploy-blue-green.sh.  Services whose merged compose config
# carries the label  com.velaair.bluegreen: "true"  (api and web in VelaAir) are
# then never force-recreated in place.  The project's own switch-over script
# replaces them after the other services are up: it starts a second container,
# waits for it to be healthy, drains the old one and removes it.  With the
# variable unset/false, or the script absent, none of this runs and
# update-site.sh behaves as before.
#
# Uses from update-site.sh: _log _warn _fail _dotenv_get _dc_up_with_recover,
# PROJECT_DIR DOTENV BLUEGREEN_SH FORCE INFRA_STALE ARTIFACT_NAMES ARTIFACT_STALE.

BG_SERVICES="" # labelled services, space separated; empty = blue/green off
BG_SWITCH=""   # labelled services that need a switch-over this run
BG_NO_DEPS=""  # "--no-deps" when on: a dependency recreate must not hit them

# Return all service names whose label KEY equals VALUE in the merged compose
# config.  Requires Docker Compose v2.15+ for --format json.
_services_with_label() {
    local key="$1" value="$2"
    docker compose --project-directory "${PROJECT_DIR}" --env-file "${DOTENV}" config --format json 2> /dev/null |
        python3 -c "
import json, sys
config = json.load(sys.stdin)
key, value = sys.argv[1], sys.argv[2]
for svc, cfg in config.get('services', {}).items():
    labels = cfg.get('labels', {})
    if isinstance(labels, list):
        labels = dict(l.split('=', 1) for l in labels if '=' in l)
    if labels.get(key) == value:
        print(svc)
" "${key}" "${value}" 2> /dev/null || true
}

# Return all service names whose `artifact` label matches the given artifact name.
_services_for_artifact() { _services_with_label artifact "$1"; }

_is_bluegreen_service() { [[ " ${BG_SERVICES}" == *" $1 "* ]]; }

# Print the arguments that are not blue/green services, each followed by a space.
_without_bluegreen() {
    local svc
    for svc in "$@"; do
        _is_bluegreen_service "${svc}" || printf '%s ' "${svc}"
    done
}

# Set BG_SERVICES / BG_NO_DEPS, or leave them empty when blue/green is off.
_bluegreen_init() {
    BG_SERVICES=""
    BG_NO_DEPS=""
    [[ "$(_dotenv_get BLUE_GREEN_ENABLED)" == "true" && -f "${BLUEGREEN_SH}" ]] || return 0
    BG_SERVICES="$(_services_with_label com.velaair.bluegreen true | tr '\n' ' ')"
    if [[ -z "${BG_SERVICES}" ]]; then
        _warn "BLUE_GREEN_ENABLED=true but no service carries the com.velaair.bluegreen label — updating in place"
        return 0
    fi
    # shellcheck disable=SC2034 # used by update-site.sh
    BG_NO_DEPS="--no-deps"
}

# Print the labelled services that need a switch-over: all of them when infra is
# stale (which includes --force), otherwise those whose artifact is stale.
_bluegreen_switch_list() {
    local i svc
    if [[ "${INFRA_STALE}" == "true" ]]; then
        printf '%s' "${BG_SERVICES}"
        return 0
    fi
    for i in "${!ARTIFACT_NAMES[@]}"; do
        [[ "${ARTIFACT_STALE[$i]:-false}" == "true" ]] || continue
        for svc in $(_services_for_artifact "${ARTIFACT_NAMES[$i]}"); do
            if _is_bluegreen_service "${svc}"; then printf '%s ' "${svc}"; fi
        done
    done
}

# A labelled service with no running container has nothing to switch from: start
# it normally (the artifact at the stable path is already current) and take it
# off the switch list.
_bluegreen_start_missing() {
    local running svc
    running="$(docker compose --project-directory "${PROJECT_DIR}" --env-file "${DOTENV}" ps --services --status running 2> /dev/null || true)"
    for svc in ${BG_SERVICES}; do
        if ! grep -Fxq -- "${svc}" <<< "${running}"; then
            _log "Blue/green: ${svc} is not running — starting it directly (nothing to switch from)"
            _dc_up_with_recover -d "${svc}"
            BG_SWITCH=" ${BG_SWITCH}"
            BG_SWITCH="${BG_SWITCH// ${svc} / }"
            BG_SWITCH="${BG_SWITCH# }"
        fi
    done
}

# Before the restarts: decide what blue/green owns this run.
_bluegreen_prepare() {
    _bluegreen_init
    [[ -n "${BG_SERVICES}" ]] || return 0
    BG_SWITCH="$(_bluegreen_switch_list)"
    _bluegreen_start_missing
}

# Bootstrap recovery: bring up every service except the labelled ones.  A plain
# `up -d` would recreate a labelled service whose image or config changed.
_bluegreen_up_others() {
    local others
    # shellcheck disable=SC2046
    others="$(_without_bluegreen $(docker compose --project-directory "${PROJECT_DIR}" \
        --env-file "${DOTENV}" config --services 2> /dev/null))"
    if [[ -z "${others}" ]]; then
        _warn "No services besides the blue/green ones to bring up"
        return 0
    fi
    # shellcheck disable=SC2086
    _dc_up_with_recover -d --no-deps ${others}
}

# After the other services are up: run the project's switch-over script.  Its
# failure fails the update, but it only ever removes the old container after the
# new one is healthy, so the live containers keep serving.
_bluegreen_switch() {
    local services="${BG_SWITCH% }" force="" rc=0
    [[ -n "${services}" ]] || return 0
    # shellcheck disable=SC2153 # FORCE is set by update-site.sh
    if [[ "${FORCE}" == "true" ]]; then force="--force"; fi
    _log "Blue/green: switching over: ${services}"
    bash "${BLUEGREEN_SH}" deploy --auto --services "${services}" ${force:+"${force}"} < /dev/null || rc=$?
    [[ "${rc}" -eq 0 ]] ||
        _fail "Blue/green switch-over failed (exit ${rc}) for: ${services}. The live containers were not stopped and keep serving the previous build. The new artifact is already recorded in .env, so the next update will not retry; fix the cause and run 'velaair deploy'."
}

# --dry-run: report what would be switched over.
_bluegreen_dry_run() {
    _bluegreen_init
    [[ -n "${BG_SERVICES}" ]] || return 0
    BG_SWITCH="$(_bluegreen_switch_list)"
    [[ -z "${BG_SWITCH}" ]] || _log "Dry-run: would switch over (blue/green, no in-place recreate): ${BG_SWITCH% }"
}
