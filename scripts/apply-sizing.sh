#!/usr/bin/env bash
#
# Switch a stack between sizing profiles: sets SIZING_PROFILE and the container
# limits in its .env from deploy/<stack>/sizing/<profile>/limits.env.
#
#   scripts/apply-sizing.sh standalone dev       # one machine, low ingest
#   scripts/apply-sizing.sh standalone default   # back to the defaults
#
# Only the keys in limits.env change. Everything else in .env (the password,
# ports, image versions) is kept. .env is created from .env.example if it does
# not exist yet. Apply it with `make up` (or `docker compose up -d`): compose
# recreates the containers whose limits or mounts changed, and the data
# volumes are untouched.
#
# Only the standalone stack has profiles. The HA stack is for testing
# failover, and each of its replicas already needs the room the default gives.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

usage() {
    echo "usage: $0 standalone <profile>" >&2
    echo "profiles: $(cd deploy/standalone/sizing && ls -d -- */ | tr -d / | tr '\n' ' ')" >&2
    exit 1
}

[ $# -eq 2 ] || usage
STACK="$1" PROFILE="$2"
[ "$STACK" = standalone ] || { echo "error: only the standalone stack has sizing profiles" >&2; exit 1; }
DIR="deploy/${STACK}"
LIMITS="${DIR}/sizing/${PROFILE}/limits.env"
[ -f "$LIMITS" ] || { echo "error: no profile '${PROFILE}' (${LIMITS} not found)" >&2; usage; }

ENV_FILE="${DIR}/.env"
if [ ! -f "$ENV_FILE" ]; then
    cp "${DIR}/.env.example" "$ENV_FILE"
    echo "created ${ENV_FILE} from the example; set CLICKHOUSE_PASSWORD before exposing it"
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
# Replace each KEY=... line that limits.env defines, in place, and append the
# ones .env does not have yet (an .env from before SIZING_PROFILE existed).
awk '
    FNR == NR {
        if ($0 ~ /^[A-Z_]+=/) { k = substr($0, 1, index($0, "=") - 1); want[k] = $0; order[++n] = k }
        next
    }
    /^[A-Z_]+=/ {
        k = substr($0, 1, index($0, "=") - 1)
        if (k in want) { print want[k]; seen[k] = 1; next }
    }
    { print }
    END { for (i = 1; i <= n; i++) if (!(order[i] in seen)) print want[order[i]] }
' "$LIMITS" "$ENV_FILE" > "$tmp"
cat "$tmp" > "$ENV_FILE"

echo "${ENV_FILE}: sizing profile '${PROFILE}'"
grep -E '^[A-Z_]+=' "$LIMITS" | sed 's/^/  /'

# docker compose prefers the shell's environment over .env, so an exported
# value would silently keep the old setting.
while IFS= read -r key; do
    if [ -n "${!key+set}" ]; then
        echo "warning: ${key} is set in your shell and overrides .env for docker compose; unset it" >&2
    fi
done < <(grep -oE '^[A-Z_]+' "$LIMITS")
echo "apply with: make up"
