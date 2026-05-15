#!/bin/bash
# Key-format validator for the New Relic observability provider.
# Called as: bash newrelic.validate.sh "<key>"
# Exit 0 if the key matches the expected format; non-zero with a message on stderr otherwise.
#
# New Relic licence keys are 40 alphanumeric characters (typically the last
# four are "NRAL" or "NRAK" for an ingest licence). We validate format only —
# correctness is verified by the agent connecting to the API at runtime.

set -e

key="${1:-}"

if [[ -z "$key" ]]; then
    echo "ERROR: New Relic licence key is empty" >&2
    exit 1
fi

if [[ ! "$key" =~ ^[A-Za-z0-9]{40}$ ]]; then
    echo "ERROR: New Relic licence key must be exactly 40 alphanumeric characters (got ${#key})" >&2
    exit 1
fi

exit 0
