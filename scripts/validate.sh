#!/usr/bin/env bash
#
# Static validation of everything in this repo that can be checked without a
# running Docker daemon. This is what CI runs.
#
#   scripts/validate.sh
#
# Checks:
#   - every compose file resolves (`docker compose config`)
#   - every XML config is well-formed
#   - every YAML config parses
#   - security fragments merge cleanly onto both stacks
#   - image tags in .env.example actually exist on Docker Hub (needs network;
#     skipped with --offline)
#   - shell scripts pass shellcheck, if it is installed
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

OFFLINE=false
[ "${1:-}" = "--offline" ] && OFFLINE=true

FAILURES=0
pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
skip() { printf '  \033[33mskip\033[0m  %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── Compose files ────────────────────────────────────────────────────────────
head_ "docker compose"
if ! command -v docker >/dev/null 2>&1; then
    skip "docker not installed"
else
    for stack in standalone ha; do
        dir="deploy/${stack}"
        # `docker compose config` needs a .env for the required variables, and
        # .env is git-ignored, so validate against .env.example.
        tmp_env="${dir}/.env"
        created_env=false
        if [ ! -f "$tmp_env" ]; then
            cp "${dir}/.env.example" "$tmp_env"
            created_env=true
        fi

        if out=$(docker compose -f "${dir}/docker-compose.yaml" config 2>&1 >/dev/null); then
            pass "${dir}/docker-compose.yaml"
        else
            fail "${dir}/docker-compose.yaml"
            echo "$out" | sed 's/^/        /'
        fi

        # The security overlay references a generated file, so generate one
        # first or the overlay validates against a path that does not exist.
        ./scripts/apply-security.sh "$stack" tls basic-auth >/dev/null 2>&1
        if out=$(docker compose -f "${dir}/docker-compose.yaml" -f "${dir}/compose.security.yaml" config 2>&1 >/dev/null); then
            pass "${dir}/compose.security.yaml overlay"
        else
            fail "${dir}/compose.security.yaml overlay"
            echo "$out" | sed 's/^/        /'
        fi
        ./scripts/apply-security.sh "$stack" --reset >/dev/null 2>&1

        [ "$created_env" = true ] && rm -f "$tmp_env"
    done
fi

# ── XML ──────────────────────────────────────────────────────────────────────
head_ "XML config"
if ! command -v xmllint >/dev/null 2>&1; then
    skip "xmllint not installed (apt-get install libxml2-utils)"
else
    while IFS= read -r f; do
        if out=$(xmllint --noout "$f" 2>&1); then
            pass "$f"
        else
            fail "$f"
            echo "$out" | sed 's/^/        /'
        fi
    done < <(find deploy -name '*.xml' | sort)
fi

# ── YAML ─────────────────────────────────────────────────────────────────────
head_ "YAML config"
while IFS= read -r f; do
    if out=$(python3 -c "import sys,yaml; yaml.safe_load(open(sys.argv[1]))" "$f" 2>&1); then
        pass "$f"
    else
        fail "$f"
        echo "$out" | sed 's/^/        /'
    fi
done < <(find deploy -name '*.yaml' -not -name 'docker-compose.yaml' -not -name 'compose.*.yaml' -not -name '*.generated.yaml' | sort)

# ── Per-node macros must be unique ───────────────────────────────────────────
# The classic HA misconfiguration: one macros file mounted on every node, so
# all replicas claim the same identity and replication silently does nothing.
head_ "HA replica identity"
replicas=$(grep -h -o '<replica>[^<]*</replica>' deploy/ha/clickhouse/config.d/macros-*.xml | sort)
unique=$(printf '%s\n' "$replicas" | sort -u | wc -l)
total=$(printf '%s\n' "$replicas" | wc -l)
if [ "$unique" -eq "$total" ] && [ "$total" -eq 3 ]; then
    pass "3 ClickHouse nodes, 3 distinct <replica> macros"
else
    fail "expected 3 distinct <replica> macros, found ${unique} distinct of ${total}"
fi

# Every stack must name its cluster `cluster` — the schema migrator and the
# SigNoz backend both default to that exact name.
head_ "ClickHouse cluster name"
for f in deploy/standalone/clickhouse/config.d/signoz.xml deploy/ha/clickhouse/config.d/cluster.xml; do
    if xmllint --xpath 'boolean(/clickhouse/remote_servers/cluster)' "$f" 2>/dev/null | grep -q true; then
        pass "$f declares <remote_servers><cluster>"
    else
        fail "$f must declare a cluster literally named 'cluster'"
    fi
done

# SigNoz v0.143.0+ pushes LLM-observability config over OpAMP into the
# signozspanmapper and signozllmpricing processors, and expects the base config
# to already have them in the traces pipeline.
head_ "collector traces pipeline"
for stack in standalone ha; do
    f="deploy/${stack}/collector/config.yaml"
    if out=$(python3 - "$f" <<'PY' 2>&1
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
procs = d["service"]["pipelines"]["traces"]["processors"]
for name in ("signozspanmapper", "signozllmpricing"):
    if name not in d["processors"]:
        sys.exit(f"processors.{name} is not defined")
    if name not in procs:
        sys.exit(f"{name} is missing from the traces pipeline")
# The pricer reads the gen_ai.* attributes the mapper writes.
if procs.index("signozspanmapper") > procs.index("signozllmpricing"):
    sys.exit(f"signozspanmapper must run before signozllmpricing: {procs}")
if procs[0] != "memory_limiter" or procs[-1] != "batch":
    sys.exit(f"traces processors must start with memory_limiter and end with batch: {procs}")
PY
    ); then
        pass "$f"
    else
        fail "$f"
        echo "$out" | sed 's/^/        /'
    fi
done

# ── Security fragments ───────────────────────────────────────────────────────
head_ "security fragments"
for stack in standalone ha; do
    for frag in basic-auth bearer-auth tls mtls persistent-queue; do
        if out=$(./scripts/apply-security.sh "$stack" "$frag" 2>&1); then
            # The health-check extension must survive every merge, or the
            # container health check breaks the moment security is enabled.
            if python3 -c "
import sys, yaml
d = yaml.safe_load(open('deploy/${stack}/collector/config.generated.yaml'))
sys.exit(0 if 'signoz_health_check' in d['service']['extensions'] else 1)
"; then
                pass "${stack} + ${frag}"
            else
                fail "${stack} + ${frag}: dropped signoz_health_check from service.extensions"
            fi
        else
            fail "${stack} + ${frag}"
            echo "$out" | sed 's/^/        /'
        fi
    done
    ./scripts/apply-security.sh "$stack" --reset >/dev/null 2>&1
done

# ── Image tags ───────────────────────────────────────────────────────────────
head_ "image tags on Docker Hub"
if [ "$OFFLINE" = true ]; then
    skip "--offline"
else
    check_tag() {
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
            "https://hub.docker.com/v2/repositories/$1/tags/$2" 2>/dev/null)
        [ "$code" = "200" ]
    }
    while IFS= read -r line; do
        case "$line" in
            CLICKHOUSE_VERSION=*)             repo=clickhouse/clickhouse-server ;;
            CLICKHOUSE_KEEPER_VERSION=*)      repo=clickhouse/clickhouse-keeper ;;
            SIGNOZ_VERSION=*)                 repo=signoz/signoz ;;
            SIGNOZ_OTEL_COLLECTOR_VERSION=*)  repo=signoz/signoz-otel-collector ;;
            POSTGRES_VERSION=*)               repo=library/postgres ;;
            NGINX_VERSION=*)                  repo=library/nginx ;;
            *) continue ;;
        esac
        tag="${line#*=}"
        if check_tag "$repo" "$tag"; then
            pass "${repo}:${tag}"
        else
            fail "${repo}:${tag} not found on Docker Hub"
        fi
    done < <(cat deploy/standalone/.env.example deploy/ha/.env.example | grep -E '^[A-Z_]+_VERSION=' | sort -u)
fi

# ── Shell ────────────────────────────────────────────────────────────────────
head_ "shell scripts"
if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed"
else
    for f in scripts/*.sh; do
        if out=$(shellcheck -S warning "$f" 2>&1); then
            pass "$f"
        else
            fail "$f"
            echo "$out" | sed 's/^/        /'
        fi
    done
fi

# ── Result ───────────────────────────────────────────────────────────────────
echo
if [ "$FAILURES" -eq 0 ]; then
    printf '\033[32mall checks passed\033[0m\n'
    exit 0
fi
printf '\033[31m%d check(s) failed\033[0m\n' "$FAILURES"
exit 1
