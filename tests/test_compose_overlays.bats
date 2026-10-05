#!/usr/bin/env bats
# Overlay selection in lib/update-site.sh: each VelaAir opt-in marker under
# secrets/ adds its compose overlay to COMPOSE_FILE, so an updater run keeps
# the overlays the velaair CLI enabled instead of collapsing to the base file.
# A hook records the COMPOSE_FILE it inherits; no GCS or Docker is touched.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
UPDATE_SITE="${REPO_ROOT}/lib/update-site.sh"

setup() {
    PROJ="$BATS_TEST_TMPDIR/site"
    mkdir -p "${PROJ}/infra/secrets" "${PROJ}/infra/hooks" "${PROJ}/secrets" "${PROJ}/artifact-cache"
    cat > "${PROJ}/.env" <<'ENV'
GCS_BUCKET=gs://fake-bucket
RELEASE_CHANNEL=main-latest
INFRA_HASH=aabbccdd1122
INFRA_ARTIFACT=./artifact-cache/infra-aabbccdd1122.tar.gz
ENV
    echo '{}' > "${PROJ}/secrets/gcs_service_account.json"
    cat > "${PROJ}/infra/lifecycle-hooks.json" <<'EOF2'
{"version":"1","hooks":[{"script":"infra/hooks/record.sh","trigger":"update","phase":"post-start"}]}
EOF2
    LOG="$BATS_TEST_TMPDIR/compose-file.log"
    printf '#!/bin/bash\nprintf "%%s\\n" "${COMPOSE_FILE}" > "%s"\n' "$LOG" > "${PROJ}/infra/hooks/record.sh"
    chmod +x "${PROJ}/infra/hooks/record.sh"
}

_compose_file() {
    run bash "$UPDATE_SITE" "$PROJ" --skip-artifact-download --always-run-hooks
    [ "$status" -eq 0 ]
    cat "$LOG"
}

@test "overlays: no markers → base compose only" {
    [ "$(_compose_file)" = "${PROJ}/docker-compose.yml" ]
}

@test "overlays: dr-source marker adds docker-compose.dr-source.yml (VelaAir F1543)" {
    touch "${PROJ}/secrets/dr-source-enabled"
    [ "$(_compose_file)" = "${PROJ}/docker-compose.yml:${PROJ}/docker-compose.dr-source.yml" ]
}

@test "overlays: replica, wireguard and dr-source markers combine in order" {
    touch "${PROJ}/secrets/mariadb-replica-enabled" "${PROJ}/secrets/wireguard-enabled" "${PROJ}/secrets/dr-source-enabled"
    [ "$(_compose_file)" = "${PROJ}/docker-compose.yml:${PROJ}/docker-compose.replicas.yml:${PROJ}/docker-compose.wireguard.yml:${PROJ}/docker-compose.dr-source.yml" ]
}
