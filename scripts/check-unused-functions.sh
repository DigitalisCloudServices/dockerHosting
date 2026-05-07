#!/usr/bin/env bash
# Detect functions that are defined but never called
# Ignores main() and _*() private functions

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXIT_CODE=0

# Extract all function definitions
declare -A defined_functions
declare -A called_functions

# Find all function definitions
while IFS= read -r line; do
    if [[ $line =~ ^([a-zA-Z_][a-zA-Z0-9_]*)\(\) ]]; then
        func="${BASH_REMATCH[1]}"
        file=$(echo "$line" | cut -d: -f1)

        # Skip private functions (starting with _) and main
        if [[ ! $func =~ ^_ ]] && [[ $func != "main" ]]; then
            defined_functions["$func"]="$file"
        fi
    fi
done < <(grep -rn '^[a-zA-Z_][a-zA-Z0-9_]*()' "$SCRIPTS_DIR"/{setup.sh,deploy-site.sh,scripts,lib} 2> /dev/null || true)

# Find all function calls (including sourced files)
for func in "${!defined_functions[@]}"; do
    if grep -rq "\b$func\b" "$SCRIPTS_DIR"/{setup.sh,deploy-site.sh,scripts,lib} 2> /dev/null; then
        # Check if it's actually called (not just defined)
        call_count=$(grep -r "\b$func\b" "$SCRIPTS_DIR"/{setup.sh,deploy-site.sh,scripts,lib} 2> /dev/null | grep -v "^[^:]*:${func}()" | wc -l || echo 0)
        if [ "$call_count" -gt 0 ]; then
            called_functions["$func"]=1
        fi
    fi
done

# Report unused functions
for func in "${!defined_functions[@]}"; do
    if [[ -z "${called_functions[$func]:-}" ]]; then
        echo "${defined_functions[$func]}: Unused function: $func"
        EXIT_CODE=1
    fi
done

if [ $EXIT_CODE -eq 0 ]; then
    echo "✓ No unused functions detected"
else
    echo "✗ Unused functions found"
fi

exit $EXIT_CODE
