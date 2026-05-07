#!/usr/bin/env bash
# Check script complexity: function length and nesting depth
# Enforces: functions ≤30 lines, max nesting depth 3

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAX_FUNCTION_LENGTH=30
MAX_NESTING_DEPTH=3
EXIT_CODE=0

check_function_length() {
    local script="$1"

    awk -v max="$MAX_FUNCTION_LENGTH" -v script="$script" '
    /^[a-zA-Z_][a-zA-Z0-9_]*\s*\(\)/ {
        start=NR
        fname=$1
        gsub(/\(\)/, "", fname)
    }
    /^}$/ && start {
        len=NR-start-1
        if (len > max) {
            print script":"start": Function \047"fname"\047 is "len" lines (max "max")"
            exit 1
        }
        start=0
    }' "$script"
}

check_nesting_depth() {
    local script="$1"

    awk -v max="$MAX_NESTING_DEPTH" -v script="$script" '
    {
        # Count opening braces
        for (i=1; i<=length($0); i++) {
            c = substr($0, i, 1)
            if (c == "{") depth++
            if (c == "}") depth--
            if (depth > max) {
                print script":"NR": Nesting depth "depth" exceeds maximum "max
                exit 1
            }
        }
    }' "$script"
}

# Check all shell scripts
for script in "$SCRIPTS_DIR"/{setup.sh,deploy-site.sh} "$SCRIPTS_DIR"/scripts/*.sh "$SCRIPTS_DIR"/lib/*.sh; do
    [ -f "$script" ] || continue

    if ! check_function_length "$script"; then
        EXIT_CODE=1
    fi

    if ! check_nesting_depth "$script"; then
        EXIT_CODE=1
    fi
done

if [ $EXIT_CODE -eq 0 ]; then
    echo "✓ Complexity checks passed"
else
    echo "✗ Complexity checks failed"
fi

exit $EXIT_CODE
