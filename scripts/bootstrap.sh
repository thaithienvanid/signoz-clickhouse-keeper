#!/usr/bin/env bash
#
# Create the first SigNoz organization and admin user.
#
#   scripts/bootstrap.sh [stack]
#
#   stack   standalone (default) | ha
#
# Environment
#   SIGNOZ_ENDPOINT     default http://localhost:8080
#   SIGNOZ_ADMIN_EMAIL  default admin@example.com
#   SIGNOZ_ADMIN_NAME   default admin
#   SIGNOZ_ADMIN_PASSWORD  generated if unset, and printed once
#   SIGNOZ_ORG_NAME     default signoz
#
# THIS IS NOT OPTIONAL SETUP. Until an organization exists, the collector
# cannot register over OpAMP, and the SigNoz collector deliberately stays in
# "no-op" mode when it is started with --manager-config: every receiver is
# replaced with a nop receiver, so **nothing is ingested at all**. The
# container still reports healthy — no-op mode exists specifically so health
# checks pass while the agent waits for its first server config.
#
# Doing this in the UI on first visit has exactly the same effect. This script
# is for unattended installs and CI.
#
# Passwords must be at least 12 characters with an uppercase letter, a
# lowercase letter, a digit and a symbol, or SigNoz rejects them.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

STACK="${1:-standalone}"
[ -d "deploy/${STACK}" ] || { echo "error: no such stack '${STACK}'" >&2; exit 1; }

SIGNOZ_ENDPOINT="${SIGNOZ_ENDPOINT:-http://localhost:8080}"
SIGNOZ_ADMIN_EMAIL="${SIGNOZ_ADMIN_EMAIL:-admin@example.com}"
SIGNOZ_ADMIN_NAME="${SIGNOZ_ADMIN_NAME:-admin}"
SIGNOZ_ORG_NAME="${SIGNOZ_ORG_NAME:-signoz}"

GENERATED=false
if [ -z "${SIGNOZ_ADMIN_PASSWORD:-}" ]; then
    # 12+ chars with the required character classes.
    SIGNOZ_ADMIN_PASSWORD="Sz$(openssl rand -hex 12)!A9"
    GENERATED=true
fi

echo "bootstrapping SigNoz at ${SIGNOZ_ENDPOINT}"

# Wait for the API before trying to register against it.
for _ in $(seq 1 30); do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
        "${SIGNOZ_ENDPOINT}/api/v1/health" 2>/dev/null)
    [ "$code" = "200" ] && break
    sleep 2
done
if [ "${code:-000}" != "200" ]; then
    echo "error: SigNoz API never became reachable at ${SIGNOZ_ENDPOINT}" >&2
    exit 1
fi

body=$(printf '{"name":"%s","email":"%s","password":"%s","orgDisplayName":"%s","orgName":"%s"}' \
    "$SIGNOZ_ADMIN_NAME" "$SIGNOZ_ADMIN_EMAIL" "$SIGNOZ_ADMIN_PASSWORD" \
    "$SIGNOZ_ORG_NAME" "$SIGNOZ_ORG_NAME")

resp_file="$(mktemp)"
code=$(curl -sS -o "$resp_file" -w '%{http_code}' --max-time 30 \
    -X POST "${SIGNOZ_ENDPOINT}/api/v1/register" \
    -H 'Content-Type: application/json' \
    --data-binary "$body" 2>/dev/null)
resp="$(cut -c1-400 < "$resp_file")"
rm -f "$resp_file"

case "$code" in
    200|201)
        echo "created organization '${SIGNOZ_ORG_NAME}' and admin '${SIGNOZ_ADMIN_EMAIL}'"
        if [ "$GENERATED" = true ]; then
            echo
            echo "  email:    ${SIGNOZ_ADMIN_EMAIL}"
            echo "  password: ${SIGNOZ_ADMIN_PASSWORD}"
            echo
            echo "Store it now — it is not shown again."
        fi
        ;;
    *)
        # Already set up is a normal, idempotent outcome.
        if printf '%s' "$resp" | grep -qi 'self-registration is disabled\|already'; then
            echo "already bootstrapped — nothing to do"
            exit 0
        fi
        echo "error: registration failed (HTTP ${code})" >&2
        echo "  ${resp}" >&2
        exit 1
        ;;
esac

# The collector only leaves no-op mode once the server pushes it a config,
# which happens on its next OpAMP poll. Wait for the OTLP port to start
# accepting so callers know ingestion is actually live.
OTLP_HOST="${OTLP_HOST:-localhost}"
OTLP_PORT="${OTLP_PORT:-4318}"
echo "waiting for the collector to leave no-op mode and open ${OTLP_HOST}:${OTLP_PORT} ..."
for _ in $(seq 1 30); do
    if (exec 3<>"/dev/tcp/${OTLP_HOST}/${OTLP_PORT}") 2>/dev/null; then
        echo "OTLP endpoint is accepting connections — ingestion is live"
        exit 0
    fi
    sleep 5
done

echo "warning: ${OTLP_HOST}:${OTLP_PORT} is still closed after 150s." >&2
echo "The collector polls OpAMP every 30s; check 'docker compose logs otel-collector'." >&2
exit 1
