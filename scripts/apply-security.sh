#!/usr/bin/env bash
#
# Deep-merge one or more security fragments into a stack's collector config.
#
#   scripts/apply-security.sh <stack> <fragment> [fragment...]
#
#   stack     standalone | ha
#   fragment  basic-auth | bearer-auth | tls | mtls | persistent-queue
#
# Examples
#   scripts/apply-security.sh standalone bearer-auth
#   scripts/apply-security.sh ha tls basic-auth
#   scripts/apply-security.sh standalone --reset
#
# Writes deploy/<stack>/collector/config.generated.yaml, which the
# compose.security.yaml overlay mounts in place of the base config:
#
#   cd deploy/standalone
#   docker compose -f docker-compose.yaml -f compose.security.yaml up -d
#
# The base config is never modified, so re-running with a different set of
# fragments always starts from a clean slate rather than layering on the last
# run's output.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAGMENT_DIR="${REPO_ROOT}/deploy/security/fragments"

usage() {
    sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-1}"
}

[ $# -ge 1 ] || usage 1
case "$1" in -h|--help) usage 0 ;; esac

STACK="$1"; shift
STACK_DIR="${REPO_ROOT}/deploy/${STACK}"
BASE="${STACK_DIR}/collector/config.yaml"
OUT="${STACK_DIR}/collector/config.generated.yaml"

[ -f "$BASE" ] || { echo "error: no such stack '${STACK}' (expected ${BASE})" >&2; exit 1; }

if [ "${1:-}" = "--reset" ]; then
    rm -f "$OUT"
    echo "removed ${OUT#"${REPO_ROOT}/"} — the stack falls back to its base config"
    exit 0
fi

[ $# -ge 1 ] || usage 1

FRAGMENTS=()
for name in "$@"; do
    f="${FRAGMENT_DIR}/${name}.yaml"
    [ -f "$f" ] || {
        echo "error: unknown fragment '${name}'. Available:" >&2
        ls -1 "$FRAGMENT_DIR" | sed 's/\.yaml$/  /;s/^/  /' >&2
        exit 1
    }
    FRAGMENTS+=("$f")
done

# tls and mtls both define receivers.otlp.*.tls; mtls is a superset, so
# applying both just means the later one wins — confusing rather than broken,
# but worth refusing outright.
if printf '%s\n' "$@" | grep -qx tls && printf '%s\n' "$@" | grep -qx mtls; then
    echo "error: 'mtls' already includes everything in 'tls' — pick one" >&2
    exit 1
fi

python3 - "$BASE" "$OUT" "${FRAGMENTS[@]}" <<'PY'
import sys, yaml

base_path, out_path, *fragment_paths = sys.argv[1:]

def merge(dst, src):
    """Recursive dict merge. Lists of component names (service.extensions and
    the pipeline lists) are unioned rather than replaced, so a fragment adding
    an authenticator cannot silently drop signoz_health_check."""
    for key, value in src.items():
        if isinstance(value, dict) and isinstance(dst.get(key), dict):
            merge(dst[key], value)
        elif isinstance(value, list) and isinstance(dst.get(key), list):
            dst[key] = dst[key] + [v for v in value if v not in dst[key]]
        else:
            dst[key] = value
    return dst

with open(base_path) as fh:
    config = yaml.safe_load(fh)

applied = []
for path in fragment_paths:
    with open(path) as fh:
        merge(config, yaml.safe_load(fh))
    applied.append(path.rsplit("/", 1)[-1].removesuffix(".yaml"))

header = (
    "# GENERATED FILE - do not edit.\n"
    "# Produced by scripts/apply-security.sh from collector/config.yaml plus:\n"
    + "".join(f"#   - {name}\n" for name in applied)
    + "# Re-run that script to regenerate, or --reset to remove.\n\n"
)

with open(out_path, "w") as fh:
    fh.write(header)
    yaml.safe_dump(config, fh, sort_keys=False, default_flow_style=False, width=100)

print("applied: " + ", ".join(applied))
PY

echo "wrote ${OUT#"${REPO_ROOT}/"}"
echo
echo "next:"
echo "  cd deploy/${STACK}"
echo "  docker compose -f docker-compose.yaml -f compose.security.yaml up -d"
