#!/usr/bin/env bats
# Tests for lib/decrypt.sh — artifact verification and decryption helper.
#
# All tests run in skip-encryption mode (SKIP_ENCRYPTION=true, the default)
# so no real AES/RSA keys are required.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
DECRYPT="${REPO_ROOT}/lib/decrypt.sh"

# Build a minimal plain tar.gz with a manifest.json for skip-encryption tests.
_make_bundle() {
    local dir="$BATS_TEST_TMPDIR/bundle_src_$$"
    mkdir -p "$dir"
    printf '{"git_hash":"abc123def456"}' > "$dir/manifest.json"
    tar czf "$BATS_TEST_TMPDIR/bundle_$$.tar.gz" -C "$dir" manifest.json
    echo "$BATS_TEST_TMPDIR/bundle_$$.tar.gz"
}

# ── Argument validation (exit 2) ──────────────────────────────────────────────

@test "decrypt: no args exits 2" {
    run bash "$DECRYPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--bundle is required"* ]]
}

@test "decrypt: --bundle with no --out or --out-tar exits 2" {
    run bash "$DECRYPT" --bundle /some/path
    [ "$status" -eq 2 ]
    [[ "$output" == *"--out or --out-tar required"* ]]
}

@test "decrypt: --out and --out-tar together exits 2" {
    run bash "$DECRYPT" --bundle /some/path --out /some/dir --out-tar /some/file
    [ "$status" -eq 2 ]
    [[ "$output" == *"mutually exclusive"* ]]
}

@test "decrypt: unknown argument exits 2" {
    run bash "$DECRYPT" --unknown-flag
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown argument"* ]]
}

@test "decrypt: --bundle path that does not exist exits 2" {
    run bash "$DECRYPT" --bundle /nonexistent/bundle.tar.gz --dry-run
    [ "$status" -eq 2 ]
    [[ "$output" == *"bundle not found"* ]]
}

# ── Skip-encryption mode (SKIP_ENCRYPTION=true, the default) ─────────────────

@test "decrypt: --dry-run on a plain tar.gz exits 0 and reports Dry-run" {
    local bundle
    bundle="$(_make_bundle)"
    run bash "$DECRYPT" --bundle "$bundle" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dry-run"* ]]
}

@test "decrypt: --dry-run output contains git_hash from manifest" {
    local bundle
    bundle="$(_make_bundle)"
    run bash "$DECRYPT" --bundle "$bundle" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"abc123def456"* ]]
}

@test "decrypt: --out-tar copies bundle to output file and exits 0" {
    local bundle out_tar
    bundle="$(_make_bundle)"
    out_tar="$BATS_TEST_TMPDIR/output_$$.tar.gz"
    run bash "$DECRYPT" --bundle "$bundle" --out-tar "$out_tar"
    [ "$status" -eq 0 ]
    [ -f "$out_tar" ]
}

@test "decrypt: --out extracts bundle to output directory and exits 0" {
    local bundle out_dir
    bundle="$(_make_bundle)"
    out_dir="$BATS_TEST_TMPDIR/extracted_$$"
    run bash "$DECRYPT" --bundle "$bundle" --out "$out_dir"
    [ "$status" -eq 0 ]
    [ -d "$out_dir" ]
    [ -f "$out_dir/manifest.json" ]
}

# ── Full-crypto mode error path ───────────────────────────────────────────────

@test "decrypt: SKIP_ENCRYPTION=false exits 1 when bundle lacks encrypted payload files" {
    # A plain tar.gz (no payload.enc/signature.sig) fails signature checks → exit 1
    local bundle
    bundle="$(_make_bundle)"
    run env SKIP_ENCRYPTION=false \
        ARTIFACT_SIGNING_PUBLIC_KEY='dummy' \
        bash "$DECRYPT" --bundle "$bundle" --dry-run
    [ "$status" -eq 1 ]
    [[ "$output" == *"bundle missing"* ]]
}
