#!/usr/bin/env bats
# Tests for lib/gcs.sh — GCS authentication helper functions.
#
# All tests run without real GCS credentials.  The _gcs_access_token_uncached
# function is overridden in-process where needed; the token-exchange network
# call is never made.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
GCS_LIB="${REPO_ROOT}/lib/gcs.sh"

# ── _gcs_https_url ────────────────────────────────────────────────────────────

@test "_gcs_https_url: converts gs:// URL to https storage URL" {
    run bash -c "source '$GCS_LIB'; _gcs_https_url 'gs://mybucket/some/path'"
    [ "$status" -eq 0 ]
    [ "$output" = "https://storage.googleapis.com/mybucket/some/path" ]
}

@test "_gcs_https_url: handles bucket root with no path component" {
    run bash -c "source '$GCS_LIB'; _gcs_https_url 'gs://mybucket'"
    [ "$status" -eq 0 ]
    [ "$output" = "https://storage.googleapis.com/mybucket" ]
}

@test "_gcs_https_url: preserves nested path components and filename" {
    run bash -c "source '$GCS_LIB'; _gcs_https_url 'gs://my-bucket/a/b/c/file.tar.gz'"
    [ "$status" -eq 0 ]
    [ "$output" = "https://storage.googleapis.com/my-bucket/a/b/c/file.tar.gz" ]
}

# ── _gcs_access_token cache behaviour ────────────────────────────────────────

@test "_gcs_access_token: returns cached value when cache file is fresh" {
    # _gcs_access_token uses 'stat -c %Y' (GNU/Linux only) for mtime; skip on macOS
    [ "$(uname)" = "Linux" ] || skip "stat -c not available on macOS"

    local sa_path="$BATS_TEST_TMPDIR/fake_sa.json"
    local cache_key
    cache_key="$(printf '%s' "${sa_path}" | md5sum | cut -c1-16)"
    local cache_file="/tmp/.gcs_token_${cache_key}"

    printf 'cached-token-value' > "$cache_file"
    touch "$cache_file"

    run bash -c "
        source '$GCS_LIB'
        _gcs_access_token_uncached() { echo 'FAIL: uncached should not be called'; return 1; }
        _gcs_access_token '$sa_path'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "cached-token-value" ]

    rm -f "$cache_file"
}

@test "_gcs_access_token: calls uncached function when no cache file exists" {
    local sa_path="$BATS_TEST_TMPDIR/fake_sa_nocache.json"
    local cache_key
    cache_key="$(printf '%s' "${sa_path}" | md5sum | cut -c1-16)"
    local cache_file="/tmp/.gcs_token_${cache_key}"
    rm -f "$cache_file"

    run bash -c "
        source '$GCS_LIB'
        _gcs_access_token_uncached() { printf 'fresh-token'; }
        _gcs_access_token '$sa_path'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "fresh-token" ]

    rm -f "$cache_file"
}

@test "_gcs_access_token: calls uncached function when cache file is stale" {
    # _gcs_access_token uses 'stat -c %Y' (GNU/Linux only) for mtime; skip on macOS
    [ "$(uname)" = "Linux" ] || skip "stat -c not available on macOS"

    local sa_path="$BATS_TEST_TMPDIR/fake_sa_stale.json"
    local cache_key
    cache_key="$(printf '%s' "${sa_path}" | md5sum | cut -c1-16)"
    local cache_file="/tmp/.gcs_token_${cache_key}"

    # Use epoch-0 mtime → age ≈ 55 years, always older than 3300s TTL
    printf 'old-token' > "$cache_file"
    touch -t 197001010000.00 "$cache_file"

    run bash -c "
        source '$GCS_LIB'
        _gcs_access_token_uncached() { printf 'refreshed-token'; }
        _gcs_access_token '$sa_path'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "refreshed-token" ]

    rm -f "$cache_file"
}

# ── _gcs_access_token_uncached error handling ─────────────────────────────────

@test "_gcs_access_token_uncached: exits non-zero when SA file does not exist" {
    run bash -c "source '$GCS_LIB'; _gcs_access_token_uncached '/nonexistent/sa.json'"
    [ "$status" -ne 0 ]
}

@test "_gcs_access_token_uncached: exits non-zero when SA file is not valid JSON" {
    local bad_sa="$BATS_TEST_TMPDIR/bad_sa.json"
    printf 'not-json' > "$bad_sa"
    run bash -c "source '$GCS_LIB'; _gcs_access_token_uncached '$bad_sa'"
    [ "$status" -ne 0 ]
}
