#!/usr/bin/env bats
# Characterization tests for scripts/install-observability.sh
#
# Captures current behavior of the pluggable observability agent installer
# so future refactors can't silently drift. Covers:
#   - argument validation (provider, key, endpoint)
#   - provider selection (newrelic vs opentelemetry)
#   - env file rendering (per-provider content)
#   - systemd unit content (stale-container cleanup, paths)
#   - compose template userns_mode=host requirement
#   - stale container / previous-provider teardown
#   - idempotency and --force
#   - runtime egress derivation for opentelemetry
#   - error paths (missing template, bad key, docker failure)

load 'helpers/common'

setup() {
    setup_mocks

    # Isolated directory tree
    export OBS_ETC_DIR="$BATS_TEST_TMPDIR/etc/observability"
    export OBS_OPT_DIR="$BATS_TEST_TMPDIR/opt/observability"
    export OBS_SYSTEMD_DIR="$BATS_TEST_TMPDIR/etc/systemd/system"
    export TEMPLATE_DIR="$TEMPLATES_DIR"
    mkdir -p "$OBS_SYSTEMD_DIR"

    # Logs for captured commands
    export SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    export DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"

    # Mock systemctl — record calls; is-active returns "active" exit by default
    # so `already_configured` won't short-circuit on a fresh install (we depend
    # on the env_file/provider_file absence to make it return 1 instead).
    cat > "$MOCK_BIN/systemctl" <<MOCK_BODY
#!/bin/bash
echo "\$*" >> "$SYSTEMCTL_LOG"
if [[ "\$1" == "is-active" ]]; then
    exit 1
fi
exit 0
MOCK_BODY
    chmod +x "$MOCK_BIN/systemctl"

    # Mock docker — record calls. `docker inspect` returns "running" so
    # verify_running succeeds quickly without sleeping 60s.
    cat > "$MOCK_BIN/docker" <<MOCK_BODY
#!/bin/bash
echo "\$*" >> "$DOCKER_LOG"
case "\$1" in
    inspect)
        echo "running"
        ;;
    compose)
        ;;
esac
exit 0
MOCK_BODY
    chmod +x "$MOCK_BIN/docker"

    # `install` may not be available with -o root flags as non-root. Replace
    # with a friendly version that just mkdir -p's the target directory(ies).
    cat > "$MOCK_BIN/install" <<'INSTALL_MOCK'
#!/bin/bash
# Strip option flags; remaining positional args are paths to create.
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d) shift ;;
        -m|-o|-g) shift 2 ;;
        --) shift; break ;;
        -*) shift ;;
        *) mkdir -p "$1"; shift ;;
    esac
done
exit 0
INSTALL_MOCK
    chmod +x "$MOCK_BIN/install"

    # chown / chmod must succeed even without privileges
    create_mock "chown"
    # Don't mock chmod — the real one works on files we own in tmpdir.

    # Mock sleep so verify_running loop is fast
    create_mock "sleep"

    # Patch the script to bypass the EUID check
    SCRIPT="$BATS_TEST_TMPDIR/install-observability-patched.sh"
    sed -e 's/if \[\[ "$EUID" -ne 0 \]\]/if false/' \
        "$SCRIPTS_DIR/install-observability.sh" > "$SCRIPT"
    chmod +x "$SCRIPT"

    # Valid 40-char alphanumeric key for newrelic tests
    export VALID_NR_KEY="abcdef0123456789abcdef0123456789ABCDEFAB"
    export VALID_OTEL_ENDPOINT="https://otlp.example.com:4318/v1/metrics"
    export VALID_OTEL_AUTH="Bearer some-opaque-token-value"
}

teardown() {
    teardown_mocks
}

# ── argument validation ──────────────────────────────────────────────────────

@test "install-observability: exits 1 when --provider is missing" {
    run bash "$SCRIPT" --observability-key="$VALID_NR_KEY"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Missing --provider"* ]]
}

@test "install-observability: exits 1 on unknown provider" {
    run bash "$SCRIPT" --provider=bogus --observability-key="$VALID_NR_KEY"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown provider 'bogus'"* ]]
}

@test "install-observability: lists supported providers in error message" {
    run bash "$SCRIPT" --provider=bogus --observability-key="$VALID_NR_KEY"
    [ "$status" -eq 1 ]
    [[ "$output" == *"newrelic"* ]]
    [[ "$output" == *"opentelemetry"* ]]
}

@test "install-observability: exits 1 when --observability-key is missing" {
    run bash "$SCRIPT" --provider=newrelic
    [ "$status" -eq 1 ]
    [[ "$output" == *"Missing --observability-key"* ]]
}

@test "install-observability: exits 1 when newrelic key is too short" {
    run bash "$SCRIPT" --provider=newrelic --observability-key=tooshort
    [ "$status" -eq 1 ]
    [[ "$output" == *"40 alphanumeric"* ]]
}

@test "install-observability: exits 1 when opentelemetry endpoint is missing" {
    run bash "$SCRIPT" --provider=opentelemetry \
        --observability-key="$VALID_OTEL_AUTH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires --observability-endpoint"* ]]
}

@test "install-observability: exits 1 when opentelemetry endpoint is not https" {
    run bash "$SCRIPT" --provider=opentelemetry \
        --observability-key="$VALID_OTEL_AUTH" \
        --observability-endpoint="http://otlp.example.com/v1/metrics"
    [ "$status" -eq 1 ]
    [[ "$output" == *"https://"* ]]
}

@test "install-observability: exits 1 if a provider template is missing" {
    # Point TEMPLATE_DIR at empty dir so all templates are absent
    export TEMPLATE_DIR="$BATS_TEST_TMPDIR/empty-templates"
    mkdir -p "$TEMPLATE_DIR/observability"

    run bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Missing template"* ]]
}

# ── newrelic install path ───────────────────────────────────────────────────

@test "install-observability: newrelic install writes provider marker" {
    run bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    [ "$status" -eq 0 ]
    assert_file_exists "$OBS_ETC_DIR/provider"
    assert_file_contains "$OBS_ETC_DIR/provider" "newrelic"
}

@test "install-observability: newrelic install writes env file with license key" {
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    assert_file_exists "$OBS_ETC_DIR/newrelic.env"
    assert_file_contains "$OBS_ETC_DIR/newrelic.env" "NRIA_LICENSE_KEY=$VALID_NR_KEY"
}

@test "install-observability: newrelic env file is mode 600" {
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    local mode
    mode=$(stat -f '%Lp' "$OBS_ETC_DIR/newrelic.env" 2>/dev/null \
        || stat -c '%a' "$OBS_ETC_DIR/newrelic.env" 2>/dev/null)
    [ "$mode" = "600" ]
}

@test "install-observability: newrelic install copies compose template" {
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    assert_file_exists "$OBS_OPT_DIR/newrelic/docker-compose.yml"
}

@test "install-observability: newrelic compose has userns_mode host" {
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    assert_file_contains "$OBS_OPT_DIR/newrelic/docker-compose.yml" 'userns_mode: "host"'
}

@test "install-observability: newrelic compose shares the host cgroup namespace" {
    # cgroup v2 hosts give containers a private cgroupns by default; the agent
    # then reads its own namespace root, reporting 0 for every container and
    # host-wide totals for itself. New Relic: --cgroupns=host is required.
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    assert_file_contains "$OBS_OPT_DIR/newrelic/docker-compose.yml" 'cgroup: host'
}

@test "install-observability: newrelic install writes the nri-docker interval override" {
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    assert_file_exists "$OBS_OPT_DIR/newrelic/integrations.d/docker-config.yml"
    assert_file_contains "$OBS_OPT_DIR/newrelic/integrations.d/docker-config.yml" 'name: nri-docker'
    assert_file_contains "$OBS_OPT_DIR/newrelic/integrations.d/docker-config.yml" 'interval: 60s'
}

@test "install-observability: newrelic compose mounts integrations.d over the baked-in folder" {
    # The agent does not read subfolders of integrations.d, so a site's
    # integration config has to sit next to docker-config.yml in one folder.
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    assert_file_contains "$OBS_OPT_DIR/newrelic/docker-compose.yml" \
        './integrations.d:/etc/newrelic-infra/integrations.d:ro'
}

@test "install-observability: newrelic keeps a site's integration config across a reinstall" {
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    echo "integrations: []" > "$OBS_OPT_DIR/newrelic/integrations.d/site-mysql.yml"
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY" --force
    assert_file_contains "$OBS_OPT_DIR/newrelic/integrations.d/site-mysql.yml" 'integrations: []'
}

@test "install-observability: newrelic mounts a root-only folder for site secrets" {
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    [ -d "$OBS_ETC_DIR/newrelic.d" ]
    assert_file_contains "$OBS_OPT_DIR/newrelic/docker-compose.yml" \
        '/etc/observability/newrelic.d:/etc/newrelic-infra/secrets.d:ro'
}

@test "install-observability: newrelic ships the nri-mysql container wrapper" {
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    assert_file_exists "$OBS_OPT_DIR/newrelic/nri-mysql-docker.sh"
    assert_file_contains "$OBS_OPT_DIR/newrelic/docker-compose.yml" \
        './nri-mysql-docker.sh:/etc/newrelic-infra/bin/nri-mysql-docker.sh:ro'
}

# ── log forwarder (fluent-bit service) ────────────────────────────────────────

# fluent_bit_service: the fluent-bit service block of the deployed compose file.
fluent_bit_service() {
    awk '/^  [a-z][a-z0-9-]*:$/ { in_svc = ($1 == "fluent-bit:") } in_svc' \
        "$OBS_OPT_DIR/newrelic/docker-compose.yml"
}

@test "install-observability: newrelic ships the forwarder config, slow-log parser, filter and placeholder" {
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    local fb="$OBS_OPT_DIR/newrelic/fluent-bit"
    cmp "$TEMPLATES_DIR/observability/newrelic.fluent-bit.conf" "$fb/fluent-bit.conf"
    cmp "$TEMPLATES_DIR/observability/newrelic.fluent-bit.placeholder.conf" "$fb/pipelines/00-placeholder.conf"
    cmp "$TEMPLATES_DIR/observability/newrelic.slowlog.lua" "$fb/mariadb-slowlog.lua"
    cmp "$TEMPLATES_DIR/observability/newrelic.slowlog.parsers.conf" "$fb/mariadb-slowlog.parsers.conf"
    [ -d "$OBS_OPT_DIR/newrelic/fluent-bit-state" ]
    # The agent's logging.d is not used: its image has no Fluent Bit.
    [ ! -e "$OBS_OPT_DIR/newrelic/logging.d" ]
    run grep -c 'logging.d:' "$OBS_OPT_DIR/newrelic/docker-compose.yml"
    [ "$output" = "0" ]
}

@test "install-observability: newrelic forwarder is a pinned fluent-bit image reading the host read-only" {
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    run fluent_bit_service
    [[ "$output" == *"image: fluent/fluent-bit:4.0.14"* ]]
    [[ "$output" != *"infrastructure-bundle"* ]]
    [[ "$output" == *"container_name: newrelic-fluent-bit"* ]]
    [[ "$output" == *"restart: unless-stopped"* ]]
    [[ "$output" == *'command: ["-c", "/fluent-bit/etc/fluent-bit.conf"]'* ]]
    [[ "$output" == *'"/:/host:ro"'* ]]
    [[ "$output" == *'"./fluent-bit:/fluent-bit/etc:ro"'* ]]
    [[ "$output" == *'"./fluent-bit-state:/var/lib/fluent-bit"'* ]]
    [[ "$output" == *"/etc/observability/newrelic.env"* ]]
    # Host networking, so the ufw OUTPUT egress allowlist applies to it.
    [[ "$output" == *"network_mode: host"* ]]
    [[ "$output" == *'userns_mode: "host"'* ]]
    [[ "$output" == *"cap_drop: [ALL]"* ]]
    [[ "$output" == *"cap_add: [DAC_READ_SEARCH]"* ]]
    [[ "$output" == *"no-new-privileges:true"* ]]
    [[ "$output" == *"read_only: true"* ]]
    [[ "$output" == *"mem_limit: 96m"* ]]
    [[ "$output" == *'max-size: "10m"'* ]]
}

@test "install-observability: newrelic forwarder ships slow-log entries with nrlogs to the agent's region" {
    local conf="$TEMPLATES_DIR/observability/newrelic.fluent-bit.conf"
    assert_file_contains "$conf" 'Parsers_File  /fluent-bit/etc/mariadb-slowlog.parsers.conf'
    assert_file_contains "$conf" '@INCLUDE /fluent-bit/etc/pipelines/*.conf'
    assert_file_contains "$conf" 'Name          nrlogs'
    assert_file_contains "$conf" 'Match         mariadb.slowlog.*'
    assert_file_contains "$conf" 'license_key   ${NRIA_LICENSE_KEY}'
    assert_file_contains "$conf" 'Record        hostname ${NRIA_DISPLAY_NAME}'
    # The region is the agent's (EU), and the log API host is on the egress allowlist.
    assert_file_contains "$TEMPLATES_DIR/observability/newrelic.compose.template" 'NEW_RELIC_REGION: EU'
    assert_file_contains "$conf" 'base_uri      https://log-api.eu.newrelic.com/log/v1'
    grep -qx 'log-api.eu.newrelic.com' "$TEMPLATES_DIR/observability/newrelic.egress"
}

@test "install-observability: newrelic licence key reaches the forwarder only through the root-only env file" {
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    run grep -rl "$VALID_NR_KEY" "$OBS_OPT_DIR" "$TEMPLATES_DIR/observability"
    [ "$status" -eq 1 ]
    assert_file_contains "$OBS_ETC_DIR/newrelic.env" "NRIA_LICENSE_KEY=$VALID_NR_KEY"
    assert_file_contains "$OBS_ETC_DIR/newrelic.env" 'NRIA_DISPLAY_NAME='
}

@test "install-observability: newrelic forwarder's placeholder pipeline holds only comments" {
    # An @INCLUDE glob that matches nothing stops Fluent Bit, so the placeholder
    # must always match, and must add nothing to the configuration.
    run grep -cvE '^(#.*)?$' "$TEMPLATES_DIR/observability/newrelic.fluent-bit.placeholder.conf"
    [ "$output" = "0" ]
}

@test "install-observability: newrelic forwarder finds every file its configs name under /fluent-bit/etc" {
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    local path
    [ -d "$OBS_OPT_DIR/newrelic/fluent-bit/pipelines" ]
    for path in $(grep -hoE '/fluent-bit/etc/[A-Za-z0-9_.-]+\.(conf|lua)' \
        "$TEMPLATES_DIR/observability/newrelic.fluent-bit.conf" \
        "$TEMPLATES_DIR/observability/newrelic.slowlog.conf.template" | sort -u); do
        assert_file_exists "$OBS_OPT_DIR/newrelic/fluent-bit/${path#/fluent-bit/etc/}"
    done
}

@test "install-observability: idempotency check fails when the slow-log filter is missing" {
    cat > "$MOCK_BIN/systemctl" <<MOCK_BODY
#!/bin/bash
echo "\$*" >> "$SYSTEMCTL_LOG"
exit 0
MOCK_BODY
    chmod +x "$MOCK_BIN/systemctl"

    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    rm -f "$OBS_OPT_DIR/newrelic/fluent-bit/mariadb-slowlog.lua"

    run bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    [ "$status" -eq 0 ]
    [[ "$output" != *"already configured and running"* ]]
    assert_file_exists "$OBS_OPT_DIR/newrelic/fluent-bit/mariadb-slowlog.lua"
}

@test "install-observability: newrelic keeps a site's slow-log pipeline across a reinstall" {
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    echo "# site pipeline" > "$OBS_OPT_DIR/newrelic/fluent-bit/pipelines/site-primary-slowlog.conf"
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY" --force
    assert_file_contains "$OBS_OPT_DIR/newrelic/fluent-bit/pipelines/site-primary-slowlog.conf" '# site pipeline'
}

@test "install-observability: newrelic summary names the forwarder's logs" {
    run bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    [ "$status" -eq 0 ]
    [[ "$output" == *"docker logs newrelic-fluent-bit"* ]]
}

@test "install-observability: newrelic compose does not pass interface filters as an env var" {
    # network_interface_filters has no env-var support. The agent's envconfig
    # rejected the JSON value on production ("invalid map item") and abandoned
    # the whole NRIA_* environment: display name and sample rates included.
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    run grep -c 'NRIA_NETWORK_INTERFACE_FILTERS:' "$OBS_OPT_DIR/newrelic/docker-compose.yml"
    [ "$output" = "0" ]
}

@test "install-observability: newrelic install writes agent YAML with the interface filters" {
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    assert_file_exists "$OBS_OPT_DIR/newrelic/newrelic-infra.yml"
    assert_file_contains "$OBS_OPT_DIR/newrelic/newrelic-infra.yml" 'network_interface_filters:'
    assert_file_contains "$OBS_OPT_DIR/newrelic/newrelic-infra.yml" '- br-'
    assert_file_contains "$OBS_OPT_DIR/newrelic/docker-compose.yml" \
        './newrelic-infra.yml:/etc/newrelic-infra.yml:ro'
}

@test "install-observability: idempotency check fails when the agent YAML has drifted" {
    cat > "$MOCK_BIN/systemctl" <<MOCK_BODY
#!/bin/bash
echo "\$*" >> "$SYSTEMCTL_LOG"
exit 0
MOCK_BODY
    chmod +x "$MOCK_BIN/systemctl"

    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    echo "# hand edit" >> "$OBS_OPT_DIR/newrelic/newrelic-infra.yml"

    run bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    [ "$status" -eq 0 ]
    [[ "$output" != *"already configured and running"* ]]
}

@test "install-observability: writes systemd unit file" {
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    assert_file_exists "$OBS_SYSTEMD_DIR/observability-agent.service"
}

@test "install-observability: systemd unit contains stale-container cleanup ExecStartPre" {
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    # The unit has an ExecStartPre that runs `down --remove-orphans` to clean
    # up stale containers before bringing the stack up.
    assert_file_contains "$OBS_SYSTEMD_DIR/observability-agent.service" "down --remove-orphans"
    assert_file_contains "$OBS_SYSTEMD_DIR/observability-agent.service" "ExecStartPre"
}

@test "install-observability: systemd unit references /etc/observability/provider marker" {
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    assert_file_contains "$OBS_SYSTEMD_DIR/observability-agent.service" \
        "/etc/observability/provider"
}

@test "install-observability: starts service via systemctl enable --now on first install" {
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    assert_file_exists "$SYSTEMCTL_LOG"
    assert_file_contains "$SYSTEMCTL_LOG" "daemon-reload"
    assert_file_contains "$SYSTEMCTL_LOG" "enable --now observability-agent.service"
}

@test "install-observability: verifies running container via docker inspect" {
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    assert_file_exists "$DOCKER_LOG"
    assert_file_contains "$DOCKER_LOG" "inspect newrelic-infra"
}

@test "install-observability: prints provider summary on success" {
    run bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Observability agent installed: newrelic"* ]]
    [[ "$output" == *"Provider:"* ]]
    [[ "$output" == *"newrelic"* ]]
}

@test "install-observability: warns about duplicate agents on hosts" {
    run bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    [[ "$output" == *"MUST NOT run their own copy"* ]]
}

# ── opentelemetry install path ──────────────────────────────────────────────

@test "install-observability: opentelemetry writes env with OTLP_ENDPOINT and AUTH" {
    bash "$SCRIPT" --provider=opentelemetry \
        --observability-key="$VALID_OTEL_AUTH" \
        --observability-endpoint="$VALID_OTEL_ENDPOINT"
    assert_file_exists "$OBS_ETC_DIR/opentelemetry.env"
    assert_file_contains "$OBS_ETC_DIR/opentelemetry.env" "OTLP_ENDPOINT=$VALID_OTEL_ENDPOINT"
    assert_file_contains "$OBS_ETC_DIR/opentelemetry.env" "OTLP_AUTH_HEADER=$VALID_OTEL_AUTH"
}

@test "install-observability: opentelemetry copies collector config" {
    bash "$SCRIPT" --provider=opentelemetry \
        --observability-key="$VALID_OTEL_AUTH" \
        --observability-endpoint="$VALID_OTEL_ENDPOINT"
    assert_file_exists "$OBS_OPT_DIR/opentelemetry/config.yaml"
}

@test "install-observability: opentelemetry compose has userns_mode host" {
    bash "$SCRIPT" --provider=opentelemetry \
        --observability-key="$VALID_OTEL_AUTH" \
        --observability-endpoint="$VALID_OTEL_ENDPOINT"
    assert_file_contains "$OBS_OPT_DIR/opentelemetry/docker-compose.yml" \
        'userns_mode: "host"'
}

@test "install-observability: opentelemetry writes runtime egress with derived FQDN" {
    bash "$SCRIPT" --provider=opentelemetry \
        --observability-key="$VALID_OTEL_AUTH" \
        --observability-endpoint="$VALID_OTEL_ENDPOINT"
    assert_file_exists "$OBS_ETC_DIR/opentelemetry.egress"
    # FQDN derived from https://otlp.example.com:4318/v1/metrics → otlp.example.com
    # (The script keeps a "Derived from ..." comment header containing the full
    # endpoint for traceability; the actual rule lines exclude port and path.)
    assert_file_contains "$OBS_ETC_DIR/opentelemetry.egress" "otlp.example.com"
    # Non-comment lines must NOT contain port/path — strip comments first.
    rules=$(grep -v '^#' "$OBS_ETC_DIR/opentelemetry.egress" || true)
    [[ "$rules" != *"4318"* ]]
    [[ "$rules" != *"v1/metrics"* ]]
}

@test "install-observability: opentelemetry verifies otel-collector container" {
    bash "$SCRIPT" --provider=opentelemetry \
        --observability-key="$VALID_OTEL_AUTH" \
        --observability-endpoint="$VALID_OTEL_ENDPOINT"
    assert_file_contains "$DOCKER_LOG" "inspect otel-collector"
}

@test "install-observability: opentelemetry preserves edited config.yaml on rerun" {
    # First install
    bash "$SCRIPT" --provider=opentelemetry \
        --observability-key="$VALID_OTEL_AUTH" \
        --observability-endpoint="$VALID_OTEL_ENDPOINT"

    # Operator edits the deployed config
    echo "# operator customisation" >> "$OBS_OPT_DIR/opentelemetry/config.yaml"

    # Force re-install without --force=observability flag (script uses --force)
    # Note: re-running without --force triggers idempotency skip, so use --force
    # to actually run the install logic but expect config to be overwritten.
    # The "preserve" branch only fires WITHOUT --force AND when config exists.
    # We test the preserve branch via a different path: delete provider file
    # to bypass already_configured, but keep config.yaml.
    rm -f "$OBS_ETC_DIR/provider"

    run bash "$SCRIPT" --provider=opentelemetry \
        --observability-key="$VALID_OTEL_AUTH" \
        --observability-endpoint="$VALID_OTEL_ENDPOINT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Preserved existing"* ]]
    assert_file_contains "$OBS_OPT_DIR/opentelemetry/config.yaml" "operator customisation"
}

# ── idempotency and --force ─────────────────────────────────────────────────

@test "install-observability: skips reinstall when already configured and service active" {
    # Mock systemctl to report active so idempotency check succeeds
    cat > "$MOCK_BIN/systemctl" <<MOCK_BODY
#!/bin/bash
echo "\$*" >> "$SYSTEMCTL_LOG"
exit 0
MOCK_BODY
    chmod +x "$MOCK_BIN/systemctl"

    # First install
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"

    # Second install (no --force) should skip
    run bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already configured and running"* ]]
}

@test "install-observability: --force bypasses idempotency check" {
    # Mock systemctl always returning active
    cat > "$MOCK_BIN/systemctl" <<MOCK_BODY
#!/bin/bash
echo "\$*" >> "$SYSTEMCTL_LOG"
exit 0
MOCK_BODY
    chmod +x "$MOCK_BIN/systemctl"

    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"

    run bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY" --force
    [ "$status" -eq 0 ]
    [[ "$output" != *"already configured and running"* ]]
    [[ "$output" == *"Installing observability agent"* ]]
}

@test "install-observability: idempotency check fails when env content differs" {
    cat > "$MOCK_BIN/systemctl" <<MOCK_BODY
#!/bin/bash
echo "\$*" >> "$SYSTEMCTL_LOG"
exit 0
MOCK_BODY
    chmod +x "$MOCK_BIN/systemctl"

    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"

    # Reinstall with a different (still valid) key — should NOT skip
    local OTHER_KEY="zyxwvu0123456789zyxwvu0123456789ZYXWVUZY"
    run bash "$SCRIPT" --provider=newrelic --observability-key="$OTHER_KEY"
    [ "$status" -eq 0 ]
    [[ "$output" != *"already configured and running"* ]]
    assert_file_contains "$OBS_ETC_DIR/newrelic.env" "$OTHER_KEY"
}

@test "install-observability: idempotency check fails when the deployed compose has drifted from the template" {
    # Regression: a template change (e.g. c2a355a's ingest filters) never
    # reached a host that was already configured, because only the env file
    # was compared. Same key, stale compose => must reinstall.
    cat > "$MOCK_BIN/systemctl" <<MOCK_BODY
#!/bin/bash
echo "\$*" >> "$SYSTEMCTL_LOG"
exit 0
MOCK_BODY
    chmod +x "$MOCK_BIN/systemctl"

    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    echo "# stale copy from an older template" >> "$OBS_OPT_DIR/newrelic/docker-compose.yml"

    run bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    [ "$status" -eq 0 ]
    [[ "$output" != *"already configured and running"* ]]
    run grep -c "stale copy" "$OBS_OPT_DIR/newrelic/docker-compose.yml"
    [ "$output" = "0" ]
}

@test "install-observability: idempotency check fails when the nri-docker override is missing" {
    cat > "$MOCK_BIN/systemctl" <<MOCK_BODY
#!/bin/bash
echo "\$*" >> "$SYSTEMCTL_LOG"
exit 0
MOCK_BODY
    chmod +x "$MOCK_BIN/systemctl"

    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    rm -f "$OBS_OPT_DIR/newrelic/integrations.d/docker-config.yml"

    run bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    [ "$status" -eq 0 ]
    [[ "$output" != *"already configured and running"* ]]
    assert_file_exists "$OBS_OPT_DIR/newrelic/integrations.d/docker-config.yml"
}

# ── provider switching ─────────────────────────────────────────────────────

@test "install-observability: tears down previous provider stack on switch" {
    # First install: newrelic
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"

    # Switch to opentelemetry
    rm -f "$DOCKER_LOG"
    run bash "$SCRIPT" --provider=opentelemetry \
        --observability-key="$VALID_OTEL_AUTH" \
        --observability-endpoint="$VALID_OTEL_ENDPOINT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Switching provider: newrelic"* ]]
    # docker compose down was issued against the previous (newrelic) compose file
    assert_file_contains "$DOCKER_LOG" "compose -f"
    assert_file_contains "$DOCKER_LOG" "newrelic/docker-compose.yml down --remove-orphans"
}

@test "install-observability: does not stop previous stack when provider unchanged" {
    cat > "$MOCK_BIN/systemctl" <<MOCK_BODY
#!/bin/bash
echo "\$*" >> "$SYSTEMCTL_LOG"
exit 0
MOCK_BODY
    chmod +x "$MOCK_BIN/systemctl"

    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"

    rm -f "$DOCKER_LOG"
    bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY" --force

    # No "Switching provider" log expected
    if [[ -f "$DOCKER_LOG" ]]; then
        # If docker was called, it must not have been to down a previous newrelic
        # via the switch path (which would have logged "Switching provider").
        # We only assert via the run output captured separately below.
        :
    fi

    run bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY" --force
    [[ "$output" != *"Switching provider"* ]]
}

# ── error paths ────────────────────────────────────────────────────────────

@test "install-observability: exits 1 when systemd unit template is missing" {
    # Stage a TEMPLATE_DIR that has the observability/ subdir but no
    # observability-agent.service.template at the top level.
    export TEMPLATE_DIR="$BATS_TEST_TMPDIR/partial-templates"
    mkdir -p "$TEMPLATE_DIR/observability"
    cp "$TEMPLATES_DIR/observability/"newrelic.* "$TEMPLATE_DIR/observability/"

    run bash "$SCRIPT" --provider=newrelic --observability-key="$VALID_NR_KEY"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Missing systemd template"* ]]
}

@test "install-observability: exits 1 when opentelemetry endpoint has empty host" {
    run bash "$SCRIPT" --provider=opentelemetry \
        --observability-key="$VALID_OTEL_AUTH" \
        --observability-endpoint="https:///path"
    # Validator rejects an empty host before write_runtime_egress runs.
    [ "$status" -eq 1 ]
}
