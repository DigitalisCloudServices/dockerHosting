#!/bin/bash
# Validator for the OpenTelemetry Collector provider.
# Called as: bash opentelemetry.validate.sh "<auth-header>" "<endpoint-url>"
# Exit 0 if both values are well-formed; non-zero with a message on stderr.
#
# Unlike NR (single licence key), OTel needs two operator-supplied values:
#   $1 — the value for the OTLP Authorization header (e.g. "Bearer xxx",
#        "Basic xxx", "api-key xxx"). We validate that it's non-empty and
#        contains only printable ASCII (no CR/LF, no controls — those would
#        forge headers).
#   $2 — the OTLP/HTTPS endpoint URL. Must be https://<host>[:port][/path].
#        http:// is rejected — egress allowlist is 443/tcp only.

set -e

auth="${1:-}"
endpoint="${2:-}"

if [[ -z "$auth" ]]; then
    echo "ERROR: OTLP auth header value is empty (--observability-key=...)" >&2
    exit 1
fi

# Reject CR/LF and other controls (header-injection guard); require printable.
if [[ "$auth" =~ [[:cntrl:]] ]]; then
    echo "ERROR: OTLP auth header contains control characters" >&2
    exit 1
fi
if [[ ! "$auth" =~ ^[[:print:]]+$ ]]; then
    echo "ERROR: OTLP auth header must be printable ASCII" >&2
    exit 1
fi

if [[ -z "$endpoint" ]]; then
    echo "ERROR: OTLP endpoint URL is empty (--observability-endpoint=...)" >&2
    exit 1
fi

if [[ ! "$endpoint" =~ ^https://[A-Za-z0-9._-]+(:[0-9]+)?(/.*)?$ ]]; then
    echo "ERROR: OTLP endpoint must be https://<host>[:port][/path] (got: $endpoint)" >&2
    exit 1
fi

exit 0
