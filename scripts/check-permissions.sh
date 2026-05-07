#!/usr/bin/env bash
# Verify all .sh files are executable

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXIT_CODE=0

echo "Checking script permissions..."

# Find all .sh files that are not executable
while IFS= read -r script; do
    if [ ! -x "$script" ]; then
        echo "✗ Not executable: $script"
        EXIT_CODE=1
    fi
done < <(find "$SCRIPTS_DIR" -name "*.sh" -type f ! -path "*/node_modules/*" ! -path "*/.git/*")

if [ $EXIT_CODE -eq 0 ]; then
    echo "✓ All shell scripts are executable"
fi

exit $EXIT_CODE
