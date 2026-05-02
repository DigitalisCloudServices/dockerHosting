#!/usr/bin/env bats
# YAML validity checks for all YAML assets in the repository.
# Uses yamllint with project-level .yamllint.yml config.
# For .yml.template files, placeholders are substituted before linting.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
YAMLLINT_CONFIG="$REPO_ROOT/.yamllint.yml"

_yamllint() {
    yamllint -c "$YAMLLINT_CONFIG" "$@"
}

# ── Traefik templates ─────────────────────────────────────────────────────────

@test "yaml: templates/traefik/traefik.yml is valid" {
    run _yamllint "$REPO_ROOT/templates/traefik/traefik.yml"
    [ "$status" -eq 0 ]
}

@test "yaml: templates/traefik/middleware.yml is valid" {
    run _yamllint "$REPO_ROOT/templates/traefik/middleware.yml"
    [ "$status" -eq 0 ]
}

@test "yaml: templates/traefik/site.yml.template produces valid YAML after substitution" {
    run bash -c "sed 's/{{[A-Z_]*}}/placeholder/g' \
        '$REPO_ROOT/templates/traefik/site.yml.template' \
        | yamllint -c '$YAMLLINT_CONFIG' -"
    [ "$status" -eq 0 ]
}

# ── CI / GitHub Actions ───────────────────────────────────────────────────────

@test "yaml: .github/workflows/ci.yml is valid" {
    run _yamllint "$REPO_ROOT/.github/workflows/ci.yml"
    [ "$status" -eq 0 ]
}
