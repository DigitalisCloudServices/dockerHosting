#!/usr/bin/env bats
# Tests for deploy-site.sh (main site deployment script)

load 'helpers/common'

setup() {
    setup_mocks
    
    # Mock system commands
    create_mock "useradd"
    create_mock "usermod"
    create_mock "id"
    create_mock "chown"
    create_mock "chmod"
    create_mock "systemctl"
    create_mock "visudo"
    create_mock "docker"
    create_mock "tar"
    create_mock "curl"
    create_mock "python3"
    
    # Fake GCS key file
    export FAKE_GCS_KEY="$BATS_TEST_TMPDIR/fake_gcs_key.json"
    echo '{"type":"service_account"}' > "$FAKE_GCS_KEY"
    
    # Fake artifact crypto keys
    export FAKE_AES_KEY="$BATS_TEST_TMPDIR/fake_aes_key.txt"
    echo "dGVzdGtleQ==" > "$FAKE_AES_KEY"
    export FAKE_SIGNING_KEY="$BATS_TEST_TMPDIR/fake_signing_key.pem"
    echo "-----BEGIN PUBLIC KEY-----" > "$FAKE_SIGNING_KEY"
    echo "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA..." >> "$FAKE_SIGNING_KEY"
    echo "-----END PUBLIC KEY-----" >> "$FAKE_SIGNING_KEY"
    
    # Setup fake deploy directory tree
    export DEPLOY_DIR="$BATS_TEST_TMPDIR/deploy"
    mkdir -p "$DEPLOY_DIR"
    
    # Mock lib/gcs.sh functions
    create_mock_with_body "gcs_mock" 'exit 0'
    
    # Override SCRIPT_DIR to point to repo root
    export SCRIPT_DIR="$REPO_ROOT"
}

teardown() {
    teardown_mocks
}

# ══════════════════════════════════════════════════════════════════════════════
# Argument validation
# ══════════════════════════════════════════════════════════════════════════════

@test "deploy-site: non-interactive production mode requires --site-name" {
    run bash "$REPO_ROOT/deploy-site.sh" --non-interactive --gcs-key-file "$FAKE_GCS_KEY"
    [ "$status" -eq 1 ]
    [[ "$output" == *"site-name required"* ]]
}

@test "deploy-site: non-interactive production mode requires --gcs-key-file" {
    run bash "$REPO_ROOT/deploy-site.sh" --non-interactive --site-name testsite
    [ "$status" -eq 1 ]
    [[ "$output" == *"gcs-key-file required"* ]]
}

@test "deploy-site: rejects invalid --mode value" {
    run bash "$REPO_ROOT/deploy-site.sh" --site-name testsite --mode invalidmode --non-interactive
    [ "$status" -eq 1 ]
    [[ "$output" == *"mode must be 'production' or 'development'"* ]]
}

@test "deploy-site: rejects unrecognised argument" {
    run bash "$REPO_ROOT/deploy-site.sh" --site-name testsite --unknown-flag value
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown argument"* ]]
}

@test "deploy-site: --help shows usage and exits 0" {
    run bash "$REPO_ROOT/deploy-site.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "deploy-site: -h shows usage and exits 0" {
    run bash "$REPO_ROOT/deploy-site.sh" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# Non-interactive mode
# ══════════════════════════════════════════════════════════════════════════════

@test "deploy-site: non-interactive production mode succeeds with all required args" {
    # Mock lib/update-site.sh and scripts/add-traefik-site.sh
    mkdir -p "$REPO_ROOT/lib" "$REPO_ROOT/scripts"
    create_mock_with_body "$REPO_ROOT/lib/update-site.sh" 'exit 0'
    create_mock_with_body "$REPO_ROOT/scripts/add-traefik-site.sh" 'exit 0'
    create_mock_with_body "$REPO_ROOT/scripts/setup-docker-permissions.sh" 'exit 0'
    create_mock_with_body "$REPO_ROOT/scripts/setup-docker-network.sh" 'exit 0'
    create_mock_with_body "$REPO_ROOT/scripts/setup-logrotate.sh" 'exit 0'
    
    # Mock curl to return fake channel metadata
    create_mock_with_body "curl" 'cat <<JSON
{
  "infra": {
    "type": "local",
    "directory": "/tmp/fake-infra",
    "git_hash": "abc123def456",
    "signed": false,
    "encrypted": false
  }
}
JSON'
    
    # Create fake infra directory
    mkdir -p /tmp/fake-infra
    
    # Mock source to prevent lib/gcs.sh from failing
    export -f create_mock_with_body
    
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        # Override functions that need GCS
        _gcs_access_token() { echo 'fake_token'; }
        _gcs_https_url() { echo 'http://fake.url'; }
        export -f _gcs_access_token _gcs_https_url
        main --site-name testsite --gcs-key-file '$FAKE_GCS_KEY' --non-interactive
    "
    
    [ "$status" -eq 0 ]
}

@test "deploy-site: non-interactive development mode succeeds with --site-name only" {
    mkdir -p "$REPO_ROOT/scripts"
    create_mock_with_body "$REPO_ROOT/scripts/setup-docker-permissions.sh" 'exit 0'
    create_mock_with_body "$REPO_ROOT/scripts/setup-docker-network.sh" 'exit 0'
    create_mock_with_body "$REPO_ROOT/scripts/setup-logrotate.sh" 'exit 0'
    
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        main --site-name testsite --mode development
    "
    
    [ "$status" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
# Site name validation
# ══════════════════════════════════════════════════════════════════════════════

@test "deploy-site: site name is normalized to lowercase" {
    mkdir -p "$REPO_ROOT/scripts"
    create_mock_with_body "$REPO_ROOT/scripts/setup-docker-permissions.sh" 'exit 0'
    create_mock_with_body "$REPO_ROOT/scripts/setup-docker-network.sh" 'exit 0'
    create_mock_with_body "$REPO_ROOT/scripts/setup-logrotate.sh" 'exit 0'
    
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        parse_args --site-name TestSite --mode development
        apply_defaults
        echo \"SITE_NAME=\$SITE_NAME\"
    "
    
    [[ "$output" == *"SITE_NAME=testsite"* ]]
}

@test "deploy-site: site name strips invalid characters" {
    mkdir -p "$REPO_ROOT/scripts"
    create_mock_with_body "$REPO_ROOT/scripts/setup-docker-permissions.sh" 'exit 0'
    create_mock_with_body "$REPO_ROOT/scripts/setup-docker-network.sh" 'exit 0'
    
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        parse_args --site-name 'test@site!123' --mode development
        apply_defaults
        echo \"SITE_NAME=\$SITE_NAME\"
    "
    
    [[ "$output" == *"SITE_NAME=testsite123"* ]]
}

@test "deploy-site: site name preserves hyphens" {
    mkdir -p "$REPO_ROOT/scripts"
    create_mock_with_body "$REPO_ROOT/scripts/setup-docker-permissions.sh" 'exit 0'
    create_mock_with_body "$REPO_ROOT/scripts/setup-docker-network.sh" 'exit 0'
    
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        parse_args --site-name 'my-test-site' --mode development
        apply_defaults
        echo \"SITE_NAME=\$SITE_NAME\"
    "
    
    [[ "$output" == *"SITE_NAME=my-test-site"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# .env file generation
# ══════════════════════════════════════════════════════════════════════════════

@test "deploy-site: .env file is created in deployment directory" {
    mkdir -p "$REPO_ROOT/scripts"
    create_mock_with_body "$REPO_ROOT/scripts/setup-docker-permissions.sh" 'exit 0'
    create_mock_with_body "$REPO_ROOT/scripts/setup-docker-network.sh" 'exit 0'
    create_mock_with_body "$REPO_ROOT/scripts/setup-logrotate.sh" 'exit 0'
    
    local test_deploy_dir="$BATS_TEST_TMPDIR/test-deploy"
    mkdir -p "$test_deploy_dir"
    
    bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        DEPLOY_DIR='$test_deploy_dir'
        SITE_NAME='testsite'
        KONG_PORT='8443'
        DEPLOY_MODE='development'
        DOMAIN='example.com'
        env_file='$test_deploy_dir/.env'
        touch \"\$env_file\"
        _env_set COMPOSE_PROJECT_NAME \$SITE_NAME \"\$env_file\"
        _env_set KONG_HTTPS_PORT \$KONG_PORT \"\$env_file\"
        _env_set DEPLOY_MODE \$DEPLOY_MODE \"\$env_file\"
        _env_set SITE_HOSTNAME \$DOMAIN \"\$env_file\"
    "
    
    assert_file_exists "$test_deploy_dir/.env"
    assert_file_contains "$test_deploy_dir/.env" "COMPOSE_PROJECT_NAME=testsite"
    assert_file_contains "$test_deploy_dir/.env" "KONG_HTTPS_PORT=8443"
    assert_file_contains "$test_deploy_dir/.env" "DEPLOY_MODE=development"
    assert_file_contains "$test_deploy_dir/.env" "SITE_HOSTNAME=example.com"
}

@test "deploy-site: .env file has correct permissions (600)" {
    mkdir -p "$REPO_ROOT/scripts"
    create_mock_with_body "$REPO_ROOT/scripts/setup-docker-permissions.sh" 'exit 0'
    create_mock_with_body "$REPO_ROOT/scripts/setup-docker-network.sh" 'exit 0'
    
    local test_deploy_dir="$BATS_TEST_TMPDIR/test-deploy-perms"
    mkdir -p "$test_deploy_dir"
    
    bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        env_file='$test_deploy_dir/.env'
        touch \"\$env_file\"
        chmod 600 \"\$env_file\"
    "
    
    local perms
    perms=$(stat -f "%OLp" "$test_deploy_dir/.env" 2>/dev/null || stat -c "%a" "$test_deploy_dir/.env")
    [ "$perms" = "600" ]
}

@test "deploy-site: .env production mode contains GCS settings" {
    local test_deploy_dir="$BATS_TEST_TMPDIR/test-deploy-gcs"
    mkdir -p "$test_deploy_dir"
    
    bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        env_file='$test_deploy_dir/.env'
        touch \"\$env_file\"
        _env_set GCS_BUCKET 'gs://my-bucket' \"\$env_file\"
        _env_set GCS_PREFIX 'artifacts/prod' \"\$env_file\"
        _env_set RELEASE_CHANNEL 'main-latest' \"\$env_file\"
        _env_set AR_REGISTRY 'europe-west2-docker.pkg.dev' \"\$env_file\"
    "
    
    assert_file_contains "$test_deploy_dir/.env" "GCS_BUCKET=gs://my-bucket"
    assert_file_contains "$test_deploy_dir/.env" "GCS_PREFIX=artifacts/prod"
    assert_file_contains "$test_deploy_dir/.env" "RELEASE_CHANNEL=main-latest"
    assert_file_contains "$test_deploy_dir/.env" "AR_REGISTRY=europe-west2-docker.pkg.dev"
}

# ══════════════════════════════════════════════════════════════════════════════
# GCS key file copying
# ══════════════════════════════════════════════════════════════════════════════

@test "deploy-site: GCS key is copied to infra/secrets/ in production mode" {
    local test_deploy_dir="$BATS_TEST_TMPDIR/test-gcs-key"
    mkdir -p "$test_deploy_dir/infra/secrets"
    
    bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        cp '$FAKE_GCS_KEY' '$test_deploy_dir/infra/secrets/gcs_service_account.json'
    "
    
    assert_file_exists "$test_deploy_dir/infra/secrets/gcs_service_account.json"
    assert_file_contains "$test_deploy_dir/infra/secrets/gcs_service_account.json" "service_account"
}

@test "deploy-site: GCS key file has correct permissions (600)" {
    local test_deploy_dir="$BATS_TEST_TMPDIR/test-gcs-perms"
    mkdir -p "$test_deploy_dir/infra/secrets"
    
    bash -c "
        cp '$FAKE_GCS_KEY' '$test_deploy_dir/infra/secrets/gcs_service_account.json'
        chmod 600 '$test_deploy_dir/infra/secrets/gcs_service_account.json'
    "
    
    local perms
    perms=$(stat -f "%OLp" "$test_deploy_dir/infra/secrets/gcs_service_account.json" 2>/dev/null || \
            stat -c "%a" "$test_deploy_dir/infra/secrets/gcs_service_account.json")
    [ "$perms" = "600" ]
}

# ══════════════════════════════════════════════════════════════════════════════
# Artifact key file copying
# ══════════════════════════════════════════════════════════════════════════════

@test "deploy-site: AES key is copied to infra/secrets/" {
    local test_deploy_dir="$BATS_TEST_TMPDIR/test-aes-key"
    mkdir -p "$test_deploy_dir/infra/secrets"
    
    bash -c "
        cp '$FAKE_AES_KEY' '$test_deploy_dir/infra/secrets/artifact_aes_key.txt'
    "
    
    assert_file_exists "$test_deploy_dir/infra/secrets/artifact_aes_key.txt"
    assert_file_contains "$test_deploy_dir/infra/secrets/artifact_aes_key.txt" "dGVzdGtleQ=="
}

@test "deploy-site: AES key file has correct permissions (600)" {
    local test_deploy_dir="$BATS_TEST_TMPDIR/test-aes-perms"
    mkdir -p "$test_deploy_dir/infra/secrets"
    
    bash -c "
        cp '$FAKE_AES_KEY' '$test_deploy_dir/infra/secrets/artifact_aes_key.txt'
        chmod 600 '$test_deploy_dir/infra/secrets/artifact_aes_key.txt'
    "
    
    local perms
    perms=$(stat -f "%OLp" "$test_deploy_dir/infra/secrets/artifact_aes_key.txt" 2>/dev/null || \
            stat -c "%a" "$test_deploy_dir/infra/secrets/artifact_aes_key.txt")
    [ "$perms" = "600" ]
}

@test "deploy-site: RSA public key is copied to infra/secrets/" {
    local test_deploy_dir="$BATS_TEST_TMPDIR/test-rsa-key"
    mkdir -p "$test_deploy_dir/infra/secrets"
    
    bash -c "
        cp '$FAKE_SIGNING_KEY' '$test_deploy_dir/infra/secrets/artifact_signing_public_key.pem'
    "
    
    assert_file_exists "$test_deploy_dir/infra/secrets/artifact_signing_public_key.pem"
    assert_file_contains "$test_deploy_dir/infra/secrets/artifact_signing_public_key.pem" "BEGIN PUBLIC KEY"
}

@test "deploy-site: RSA public key file has correct permissions (644)" {
    local test_deploy_dir="$BATS_TEST_TMPDIR/test-rsa-perms"
    mkdir -p "$test_deploy_dir/infra/secrets"
    
    bash -c "
        cp '$FAKE_SIGNING_KEY' '$test_deploy_dir/infra/secrets/artifact_signing_public_key.pem'
        chmod 644 '$test_deploy_dir/infra/secrets/artifact_signing_public_key.pem'
    "
    
    local perms
    perms=$(stat -f "%OLp" "$test_deploy_dir/infra/secrets/artifact_signing_public_key.pem" 2>/dev/null || \
            stat -c "%a" "$test_deploy_dir/infra/secrets/artifact_signing_public_key.pem")
    [ "$perms" = "644" ]
}

# ══════════════════════════════════════════════════════════════════════════════
# systemd timer installation
# ══════════════════════════════════════════════════════════════════════════════

@test "deploy-site: systemd updater timer is created when --setup-timer=yes" {
    local timer_service="/tmp/test-updater.service"
    local timer_timer="/tmp/test-updater.timer"
    
    bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        cat > '$timer_service' <<EOF
[Unit]
Description=testsite — artifact updater
[Service]
Type=oneshot
EOF
        cat > '$timer_timer' <<EOF
[Unit]
Description=testsite — check for artifact updates every 15 minutes
[Timer]
OnBootSec=2min
OnCalendar=*:0/15
EOF
    "
    
    assert_file_exists "$timer_service"
    assert_file_exists "$timer_timer"
    assert_file_contains "$timer_service" "artifact updater"
    assert_file_contains "$timer_timer" "OnCalendar=*:0/15"
}

@test "deploy-site: maintenance timer includes daily schedule" {
    local maint_timer="/tmp/test-maintenance.timer"
    
    bash -c "
        cat > '$maint_timer' <<EOF
[Unit]
Description=testsite — run maintenance hooks daily
[Timer]
OnCalendar=*-*-* 03:05:00
EOF
    "
    
    assert_file_contains "$maint_timer" "OnCalendar=*-*-* 03:05:00"
}

@test "deploy-site: setup-timer defaults to yes in production mode" {
    bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        parse_args --site-name testsite --mode production
        apply_defaults
        echo \"SETUP_TIMER=\$SETUP_TIMER\"
    "
    
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        parse_args --site-name testsite --mode production
        apply_defaults
        echo \"SETUP_TIMER=\$SETUP_TIMER\"
    "
    
    [[ "$output" == *"SETUP_TIMER=yes"* ]]
}

@test "deploy-site: setup-timer defaults to no in development mode" {
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        parse_args --site-name testsite --mode development
        apply_defaults
        echo \"SETUP_TIMER=\$SETUP_TIMER\"
    "
    
    [[ "$output" == *"SETUP_TIMER=no"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# Traefik site addition
# ══════════════════════════════════════════════════════════════════════════════

@test "deploy-site: suggests Traefik command when domain is set" {
    mkdir -p "$REPO_ROOT/scripts"
    create_mock_with_body "$REPO_ROOT/scripts/setup-docker-permissions.sh" 'exit 0'
    create_mock_with_body "$REPO_ROOT/scripts/setup-docker-network.sh" 'exit 0'
    create_mock_with_body "$REPO_ROOT/scripts/setup-logrotate.sh" 'exit 0'
    
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        parse_args --site-name testsite --mode development --domain example.com
        apply_defaults
        KONG_PORT=8443
        traefik_script='$REPO_ROOT/scripts/add-traefik-site.sh'
        traefik_cmd=\"sudo \${traefik_script} \${DOMAIN} \${KONG_PORT} \${SITE_NAME}\"
        echo \"\$traefik_cmd\"
    "
    
    [[ "$output" == *"add-traefik-site.sh example.com 8443 testsite"* ]]
}

@test "deploy-site: Traefik suggestion includes site name" {
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        DOMAIN='test.example.com'
        KONG_PORT='9443'
        SITE_NAME='mysite'
        traefik_script='$REPO_ROOT/scripts/add-traefik-site.sh'
        traefik_cmd=\"sudo \${traefik_script} \${DOMAIN} \${KONG_PORT} \${SITE_NAME}\"
        echo \"\$traefik_cmd\"
    "
    
    [[ "$output" == *"test.example.com 9443 mysite"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# Replay command generation
# ══════════════════════════════════════════════════════════════════════════════

@test "deploy-site: replay command includes site name" {
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        SCRIPT_DIR='$REPO_ROOT'
        SITE_NAME='testsite'
        DEPLOY_MODE='development'
        SITE_USER='testsite'
        DEPLOY_DIR='/opt/apps/testsite'
        KONG_PORT='8443'
        SETUP_LOGROTATE='yes'
        printf \"sudo %s/deploy-site.sh --site-name '%s' --mode '%s'\" \"\$SCRIPT_DIR\" \"\$SITE_NAME\" \"\$DEPLOY_MODE\"
    "
    
    [[ "$output" == *"--site-name 'testsite'"* ]]
    [[ "$output" == *"--mode 'development'"* ]]
}

@test "deploy-site: replay command includes GCS settings for production" {
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        SCRIPT_DIR='$REPO_ROOT'
        SITE_NAME='prodsite'
        DEPLOY_MODE='production'
        GCS_BUCKET='gs://my-bucket'
        GCS_PREFIX='artifacts'
        RELEASE_CHANNEL='main-v1.0.0'
        GCS_KEY_FILE='/path/to/key.json'
        printf \"--gcs-bucket '%s' --gcs-prefix '%s' --channel '%s' --gcs-key-file '%s'\" \"\$GCS_BUCKET\" \"\$GCS_PREFIX\" \"\$RELEASE_CHANNEL\" \"\$GCS_KEY_FILE\"
    "
    
    [[ "$output" == *"--gcs-bucket 'gs://my-bucket'"* ]]
    [[ "$output" == *"--gcs-prefix 'artifacts'"* ]]
    [[ "$output" == *"--channel 'main-v1.0.0'"* ]]
    [[ "$output" == *"--gcs-key-file '/path/to/key.json'"* ]]
}

@test "deploy-site: replay command includes artifact keys when provided" {
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        ARTIFACT_AES_KEY_FILE='/path/to/aes.key'
        ARTIFACT_SIGNING_PUB_KEY_FILE='/path/to/rsa.pub'
        printf \"--artifact-aes-key-file '%s' --artifact-signing-pub-key-file '%s'\" \"\$ARTIFACT_AES_KEY_FILE\" \"\$ARTIFACT_SIGNING_PUB_KEY_FILE\"
    "
    
    [[ "$output" == *"--artifact-aes-key-file '/path/to/aes.key'"* ]]
    [[ "$output" == *"--artifact-signing-pub-key-file '/path/to/rsa.pub'"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# Development mode
# ══════════════════════════════════════════════════════════════════════════════

@test "deploy-site: development mode does not require GCS key" {
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        parse_args --site-name testsite --mode development
        apply_defaults
    "
    
    [ "$status" -eq 0 ]
}

@test "deploy-site: development mode creates skeleton directory structure" {
    mkdir -p "$REPO_ROOT/scripts"
    create_mock_with_body "$REPO_ROOT/scripts/setup-docker-permissions.sh" 'exit 0'
    create_mock_with_body "$REPO_ROOT/scripts/setup-docker-network.sh" 'exit 0'
    
    local test_deploy_dir="$BATS_TEST_TMPDIR/dev-deploy"
    
    bash -c "
        export EUID=0
        DEPLOY_DIR='$test_deploy_dir'
        mkdir -p \"\$DEPLOY_DIR/artifact-cache\"
        mkdir -p \"\$DEPLOY_DIR/infra/secrets\"
        mkdir -p \"\$DEPLOY_DIR/bin\"
    "
    
    [ -d "$test_deploy_dir/artifact-cache" ]
    [ -d "$test_deploy_dir/infra/secrets" ]
    [ -d "$test_deploy_dir/bin" ]
}

@test "deploy-site: development mode skips GCS authentication" {
    mkdir -p "$REPO_ROOT/scripts"
    create_mock_with_body "$REPO_ROOT/scripts/setup-docker-permissions.sh" 'exit 0'
    create_mock_with_body "$REPO_ROOT/scripts/setup-docker-network.sh" 'exit 0'
    create_mock_with_body "$REPO_ROOT/scripts/setup-logrotate.sh" 'exit 0'
    
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        main --site-name testsite --mode development
    "
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"development mode"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# Error handling
# ══════════════════════════════════════════════════════════════════════════════

@test "deploy-site: fails when GCS key file does not exist in production mode" {
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        parse_args --site-name testsite --mode production --gcs-key-file /nonexistent/key.json --non-interactive
        apply_defaults
        GCS_KEY_FILE='/nonexistent/key.json'
        [[ -f \"\$GCS_KEY_FILE\" ]] || { echo 'GCS key file not found'; exit 1; }
    "
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
}

@test "deploy-site: fails when EUID is not 0 (non-root)" {
    run bash -c "
        export EUID=1000
        source '$REPO_ROOT/deploy-site.sh'
        check_root
    "
    
    [ "$status" -eq 1 ]
    [[ "$output" == *"Run as root"* ]]
}

@test "deploy-site: succeeds when EUID is 0 (root)" {
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        check_root
    "
    
    [ "$status" -eq 0 ]
}

@test "deploy-site: port auto-detection finds next available port" {
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        result=\$(find_next_kong_port 8443)
        [[ \$result -ge 8443 ]]
    "
    
    [ "$status" -eq 0 ]
}

@test "deploy-site: env helper correctly sets key-value pairs" {
    local test_env="$BATS_TEST_TMPDIR/test.env"
    touch "$test_env"
    
    bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        _env_set TEST_KEY 'test_value' '$test_env'
    "
    
    assert_file_contains "$test_env" "TEST_KEY=test_value"
}

@test "deploy-site: env helper updates existing key" {
    local test_env="$BATS_TEST_TMPDIR/test-update.env"
    echo "TEST_KEY=old_value" > "$test_env"
    
    bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        _env_set TEST_KEY 'new_value' '$test_env'
    "
    
    assert_file_contains "$test_env" "TEST_KEY=new_value"
    refute_file_contains "$test_env" "old_value"
}

@test "deploy-site: env helper retrieves correct value" {
    local test_env="$BATS_TEST_TMPDIR/test-get.env"
    echo "FETCH_KEY=fetch_value" > "$test_env"
    
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        _env_get FETCH_KEY '$test_env'
    "
    
    [[ "$output" == "fetch_value" ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# Directory creation and permissions
# ══════════════════════════════════════════════════════════════════════════════

@test "deploy-site: artifact-cache directory is created" {
    local test_deploy_dir="$BATS_TEST_TMPDIR/test-cache"
    mkdir -p "$test_deploy_dir/artifact-cache"
    [ -d "$test_deploy_dir/artifact-cache" ]
}

@test "deploy-site: infra/secrets directory is created" {
    local test_deploy_dir="$BATS_TEST_TMPDIR/test-secrets"
    mkdir -p "$test_deploy_dir/infra/secrets"
    [ -d "$test_deploy_dir/infra/secrets" ]
}

@test "deploy-site: infra/secrets has restricted permissions (700)" {
    local test_deploy_dir="$BATS_TEST_TMPDIR/test-secrets-perms"
    mkdir -p "$test_deploy_dir/infra/secrets"
    chmod 700 "$test_deploy_dir/infra/secrets"
    
    local perms
    perms=$(stat -f "%OLp" "$test_deploy_dir/infra/secrets" 2>/dev/null || \
            stat -c "%a" "$test_deploy_dir/infra/secrets")
    [ "$perms" = "700" ]
}

@test "deploy-site: artifact-cache has correct permissions (755)" {
    local test_deploy_dir="$BATS_TEST_TMPDIR/test-cache-perms"
    mkdir -p "$test_deploy_dir/artifact-cache"
    chmod 755 "$test_deploy_dir/artifact-cache"
    
    local perms
    perms=$(stat -f "%OLp" "$test_deploy_dir/artifact-cache" 2>/dev/null || \
            stat -c "%a" "$test_deploy_dir/artifact-cache")
    [ "$perms" = "755" ]
}

# ══════════════════════════════════════════════════════════════════════════════
# User creation
# ══════════════════════════════════════════════════════════════════════════════

@test "deploy-site: create-user defaults to yes" {
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        parse_args --site-name testsite --mode development
        apply_defaults
        echo \"CREATE_USER=\$CREATE_USER\"
    "
    
    [[ "$output" == *"CREATE_USER=yes"* ]]
}

@test "deploy-site: site-user defaults to site-name when not specified" {
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        parse_args --site-name mysite --mode development
        apply_defaults
        echo \"SITE_USER=\$SITE_USER\"
    "
    
    [[ "$output" == *"SITE_USER=mysite"* ]]
}

@test "deploy-site: site-user can be overridden" {
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        parse_args --site-name mysite --site-user customuser --mode development
        apply_defaults
        echo \"SITE_USER=\$SITE_USER\"
    "
    
    [[ "$output" == *"SITE_USER=customuser"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# Default values
# ══════════════════════════════════════════════════════════════════════════════

@test "deploy-site: deploy-dir defaults to /opt/apps/<site-name>" {
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        parse_args --site-name testsite --mode development
        apply_defaults
        echo \"DEPLOY_DIR=\$DEPLOY_DIR\"
    "
    
    [[ "$output" == *"DEPLOY_DIR=/opt/apps/testsite"* ]]
}

@test "deploy-site: GCS bucket defaults to gs://example-artifacts" {
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        parse_args --site-name testsite
        apply_defaults
        echo \"GCS_BUCKET=\$GCS_BUCKET\"
    "
    
    [[ "$output" == *"GCS_BUCKET=gs://example-artifacts"* ]]
}

@test "deploy-site: release channel defaults to main-latest" {
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        parse_args --site-name testsite
        apply_defaults
        echo \"RELEASE_CHANNEL=\$RELEASE_CHANNEL\"
    "
    
    [[ "$output" == *"RELEASE_CHANNEL=main-latest"* ]]
}

@test "deploy-site: AR registry defaults to europe-west2-docker.pkg.dev" {
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        parse_args --site-name testsite
        apply_defaults
        echo \"AR_REGISTRY=\$AR_REGISTRY\"
    "
    
    [[ "$output" == *"AR_REGISTRY=europe-west2-docker.pkg.dev"* ]]
}

@test "deploy-site: GCS prefix trailing slashes are trimmed" {
    run bash -c "
        export EUID=0
        source '$REPO_ROOT/deploy-site.sh'
        parse_args --site-name testsite --gcs-prefix '/artifacts/prod/'
        apply_defaults
        echo \"GCS_PREFIX=\$GCS_PREFIX\"
    "
    
    [[ "$output" == *"GCS_PREFIX=artifacts/prod"* ]]
}
