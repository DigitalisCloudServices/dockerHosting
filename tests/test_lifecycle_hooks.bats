#!/usr/bin/env bats
# Lifecycle hook tests for lib/update-site.sh
#
# Tests hook dispatch logic and the --always-run-hooks flag without real GCS or Docker.
# Uses --skip-artifact-download so no network calls are made.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
UPDATE_SITE="${REPO_ROOT}/lib/update-site.sh"

# ── Fixture helpers ────────────────────────────────────────────────────────────

setup() {
    PROJ="$BATS_TEST_TMPDIR/site"
    mkdir -p "${PROJ}/infra/secrets" "${PROJ}/artifact-cache"

    # Minimal .env — INFRA_HASH matches itself so nothing appears stale
    cat > "${PROJ}/.env" <<'ENV'
GCS_BUCKET=gs://fake-bucket
RELEASE_CHANNEL=main-latest
INFRA_HASH=aabbccdd1122
INFRA_ARTIFACT=./artifact-cache/infra-aabbccdd1122.tar.gz
ENV

    # GCS key file must exist (content unused with --skip-artifact-download)
    echo '{}' > "${PROJ}/infra/secrets/gcs_service_account.json"
}

_write_hooks() {
    cat > "${PROJ}/infra/lifecycle-hooks.json" <<EOF
{
  "version": "1",
  "hooks": $1
}
EOF
}

_write_hook_script() {
    local path="$1" log="$2"
    mkdir -p "$(dirname "${PROJ}/${path}")"
    printf '#!/bin/bash\necho "ran:%s" >> "%s"\n' "$path" "$log" > "${PROJ}/${path}"
    chmod +x "${PROJ}/${path}"
}

# ── --always-run-hooks flag ────────────────────────────────────────────────────

@test "update-site: nothing stale, no --always-run-hooks → exits 0, hooks not run" {
    local hooklog="$BATS_TEST_TMPDIR/ran.log"
    _write_hooks '[{"script":"infra/hooks/check.sh","trigger":"update","phase":"post-start"}]'
    _write_hook_script "infra/hooks/check.sh" "$hooklog"

    run bash "$UPDATE_SITE" "$PROJ" --skip-artifact-download
    [ "$status" -eq 0 ]
    [ ! -f "$hooklog" ]
}

@test "update-site: nothing stale, --always-run-hooks → hooks fire" {
    local hooklog="$BATS_TEST_TMPDIR/ran.log"
    _write_hooks '[{"script":"infra/hooks/check.sh","trigger":"update","phase":"post-start"}]'
    _write_hook_script "infra/hooks/check.sh" "$hooklog"

    run bash "$UPDATE_SITE" "$PROJ" --skip-artifact-download --always-run-hooks
    [ "$status" -eq 0 ]
    [ -f "$hooklog" ]
    grep -q "ran:infra/hooks/check.sh" "$hooklog"
}

@test "update-site: --always-run-hooks output contains 'running hooks only' message" {
    _write_hooks '[]'
    run bash "$UPDATE_SITE" "$PROJ" --skip-artifact-download --always-run-hooks
    [ "$status" -eq 0 ]
    [[ "$output" == *"running hooks only"* ]]
}

# ── Trigger/phase dispatch ─────────────────────────────────────────────────────

@test "update-site: bootstrap trigger only runs bootstrap hooks" {
    local hooklog="$BATS_TEST_TMPDIR/ran.log"
    _write_hooks '[
      {"script":"infra/hooks/boot.sh","trigger":"bootstrap","phase":"post-start"},
      {"script":"infra/hooks/upd.sh","trigger":"update","phase":"post-start"}
    ]'
    _write_hook_script "infra/hooks/boot.sh" "$hooklog"
    _write_hook_script "infra/hooks/upd.sh" "$hooklog"

    # Force all stale so hooks run in normal update path; use bootstrap trigger
    run bash "$UPDATE_SITE" "$PROJ" \
        --trigger bootstrap \
        --skip-artifact-download \
        --always-run-hooks
    [ "$status" -eq 0 ]
    grep -q "ran:infra/hooks/boot.sh" "$hooklog"
    ! grep -q "ran:infra/hooks/upd.sh" "$hooklog"
}

@test "update-site: update trigger only runs update hooks" {
    local hooklog="$BATS_TEST_TMPDIR/ran.log"
    _write_hooks '[
      {"script":"infra/hooks/boot.sh","trigger":"bootstrap","phase":"post-start"},
      {"script":"infra/hooks/upd.sh","trigger":"update","phase":"post-start"}
    ]'
    _write_hook_script "infra/hooks/boot.sh" "$hooklog"
    _write_hook_script "infra/hooks/upd.sh" "$hooklog"

    run bash "$UPDATE_SITE" "$PROJ" \
        --trigger update \
        --skip-artifact-download \
        --always-run-hooks
    [ "$status" -eq 0 ]
    grep -q "ran:infra/hooks/upd.sh" "$hooklog"
    ! grep -q "ran:infra/hooks/boot.sh" "$hooklog"
}

@test "update-site: pre-start hook runs before post-start hook" {
    local hooklog="$BATS_TEST_TMPDIR/order.log"
    _write_hooks '[
      {"script":"infra/hooks/post.sh","trigger":"update","phase":"post-start"},
      {"script":"infra/hooks/pre.sh","trigger":"update","phase":"pre-start"}
    ]'
    _write_hook_script "infra/hooks/pre.sh" "$hooklog"
    _write_hook_script "infra/hooks/post.sh" "$hooklog"

    run bash "$UPDATE_SITE" "$PROJ" \
        --skip-artifact-download \
        --always-run-hooks
    [ "$status" -eq 0 ]
    # pre-start line must appear before post-start line in log
    local pre_line post_line
    pre_line="$(grep -n "pre.sh" "$hooklog" | cut -d: -f1)"
    post_line="$(grep -n "post.sh" "$hooklog" | cut -d: -f1)"
    [ "$pre_line" -lt "$post_line" ]
}

# ── Missing hook script ────────────────────────────────────────────────────────

@test "update-site: missing hook script logs WARN but does not abort" {
    _write_hooks '[{"script":"infra/hooks/missing.sh","trigger":"update","phase":"post-start"}]'
    # Do NOT create the hook script

    run bash "$UPDATE_SITE" "$PROJ" --skip-artifact-download --always-run-hooks
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN"* ]]
}

@test "update-site: missing hook does not prevent other hooks from running" {
    local hooklog="$BATS_TEST_TMPDIR/ran.log"
    _write_hooks '[
      {"script":"infra/hooks/missing.sh","trigger":"update","phase":"post-start"},
      {"script":"infra/hooks/real.sh","trigger":"update","phase":"post-start"}
    ]'
    _write_hook_script "infra/hooks/real.sh" "$hooklog"

    run bash "$UPDATE_SITE" "$PROJ" --skip-artifact-download --always-run-hooks
    [ "$status" -eq 0 ]
    grep -q "ran:infra/hooks/real.sh" "$hooklog"
}

# ── --dry-run compatibility ────────────────────────────────────────────────────

@test "update-site: --dry-run reports stale artifacts and exits without changes" {
    # Make infra appear stale by setting a different hash in .env vs channel
    # With --skip-artifact-download, channel hash is read from .env; use --force to force stale
    run bash "$UPDATE_SITE" "$PROJ" --skip-artifact-download --force --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dry-run"* ]]
}
