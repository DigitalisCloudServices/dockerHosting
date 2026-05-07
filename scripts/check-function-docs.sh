#!/usr/bin/env bash
# Check that all non-trivial functions have documentation comments
# Functions > 10 lines should have a comment describing their purpose

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIN_LINES_FOR_DOC=10
EXIT_CODE=0

check_function_docs() {
    local script="$1"

    awk -v min="$MIN_LINES_FOR_DOC" -v script="$script" '
    # Track if we saw a comment before the function
    /^[[:space:]]*#/ {
        saw_comment=1
        comment_line=NR
    }
    
    # Function definition
    /^[a-zA-Z_][a-zA-Z0-9_]*\s*\(\)/ {
        start=NR
        fname=$1
        gsub(/\(\)/, "", fname)
        
        # Skip private functions
        if (fname ~ /^_/) {
            start=0
            next
        }
        
        # Check if comment was within 2 lines before function
        if (saw_comment && (start - comment_line) <= 2) {
            has_doc[fname]=1
        }
        saw_comment=0
    }
    
    /^}$/ && start {
        len=NR-start-1
        if (len >= min && !has_doc[fname]) {
            print script":"start": Function \047"fname"\047 ("len" lines) lacks documentation comment"
            exit 1
        }
        start=0
    }' "$script"
}

# Check all shell scripts
for script in "$SCRIPTS_DIR"/{setup.sh,deploy-site.sh} "$SCRIPTS_DIR"/scripts/*.sh "$SCRIPTS_DIR"/lib/*.sh; do
    [ -f "$script" ] || continue

    if ! check_function_docs "$script"; then
        EXIT_CODE=1
    fi
done

if [ $EXIT_CODE -eq 0 ]; then
    echo "✓ Function documentation checks passed"
else
    echo "✗ Some functions lack documentation"
fi

exit $EXIT_CODE
