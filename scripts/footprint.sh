#!/usr/bin/env bash
#
# What a running stack actually uses: memory and CPU per container against its
# limits, restarts and OOM kills, and ClickHouse's on-disk data.
#
#   scripts/footprint.sh [stack] [--check]
#
#   stack     standalone (default) | ha
#   --check   exit non-zero if a long-running container is not running, has
#             restarted or was OOM-killed, or a one-shot job did not exit 0.
#             Run it after scripts/load-test.py to show the limits held.
#
# Memory columns, read from each container's cgroup:
#   RSS    anonymous memory now: what the processes hold, without page cache
#   PEAK   the cgroup's high-water mark since the container started. It
#          includes page cache, which the kernel reclaims before it OOM-kills,
#          so it is an upper bound on what the container needed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

STACK=standalone CHECK=false
for arg in "$@"; do
    case "$arg" in
        --check) CHECK=true ;;
        standalone|ha) STACK="$arg" ;;
        *) echo "usage: $0 [standalone|ha] [--check]" >&2; exit 1 ;;
    esac
done
case "$STACK" in
    standalone) PROJECT=signoz;    CH=signoz-clickhouse ;;
    ha)         PROJECT=signoz-ha; CH=signoz-clickhouse-1 ;;
esac

if [ -f "deploy/${STACK}/.env" ]; then
    set -a
    # shellcheck source=/dev/null
    . "deploy/${STACK}/.env"
    set +a
fi

mapfile -t CONTAINERS < <(docker ps -a --filter "label=com.docker.compose.project=${PROJECT}" \
                              --format '{{.Names}}' | sort)
if [ ${#CONTAINERS[@]} -eq 0 ]; then
    echo "no containers for compose project '${PROJECT}'; is the stack up?" >&2
    exit 1
fi

mib() { awk -v b="$1" 'BEGIN { if (b == "" || b == "-") print "-"; else printf "%.0f", b / 1048576 }'; }

# cgroup v2 first (memory.stat "anon", memory.peak), then v1 (memory.stat
# "total_rss", memory.max_usage_in_bytes). memory.peak needs Linux 5.19+.
read_mem() {
    docker exec "$1" sh -c '
        if [ -r /sys/fs/cgroup/memory.stat ]; then
            awk "/^anon /{print \$2}" /sys/fs/cgroup/memory.stat
            cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo -
        else
            awk "/^total_rss /{print \$2}" /sys/fs/cgroup/memory/memory.stat
            cat /sys/fs/cgroup/memory/memory.max_usage_in_bytes
        fi' 2>/dev/null | tr '\n' ' '
}

declare -A CPU_NOW
while read -r name cpu; do CPU_NOW["$name"]="$cpu"; done < <(
    docker stats --no-stream --format '{{.Name}} {{.CPUPerc}}' "${CONTAINERS[@]}" 2>/dev/null)

PROBLEMS=()
total_rss=0 total_peak=0 total_limit=0
printf '\n\033[1m%s containers\033[0m\n' "$STACK"
printf '%-26s %-10s %8s %8s %8s %7s %6s %4s %4s\n' \
    CONTAINER STATE "RSS MiB" "PEAK MiB" "LIMIT" "CPU" "CPUMAX" RST OOM
for c in "${CONTAINERS[@]}"; do
    read -r state exit_code restarts oom mem_limit nano_cpus policy < <(docker inspect -f \
        '{{.State.Status}} {{.State.ExitCode}} {{.RestartCount}} {{.State.OOMKilled}} {{.HostConfig.Memory}} {{.HostConfig.NanoCpus}} {{.HostConfig.RestartPolicy.Name}}' "$c")
    rss=- peak=-
    if [ "$state" = running ]; then
        read -r rss peak < <(read_mem "$c")
        # Empty if the container stopped since it was listed.
        rss=${rss:--} peak=${peak:--}
    fi
    limit=$([ "$mem_limit" -gt 0 ] && mib "$mem_limit" || echo none)
    cpumax=$([ "$nano_cpus" -gt 0 ] && awk -v n="$nano_cpus" 'BEGIN{printf "%g", n/1e9}' || echo none)
    printf '%-26s %-10s %8s %8s %8s %7s %6s %4s %4s\n' "$c" "$state" "$(mib "$rss")" "$(mib "$peak")" \
        "$limit" "${CPU_NOW[$c]:--}" "$cpumax" "$restarts" "$oom"
    [ "$rss" != - ] && total_rss=$((total_rss + rss))
    [ "$peak" != - ] && total_peak=$((total_peak + peak))
    [ "$state" = running ] && [ "$mem_limit" -gt 0 ] && total_limit=$((total_limit + mem_limit))

    [ "$oom" = true ] && PROBLEMS+=("$c was OOM-killed")
    # init-clickhouse and schema-migrator are one-shot jobs (restart: on-failure).
    if [ "$policy" = on-failure ]; then
        [ "$state" = exited ] && [ "$exit_code" = 0 ] || PROBLEMS+=("$c: one-shot job is ${state}, exit code ${exit_code}")
    else
        [ "$state" = running ] || PROBLEMS+=("$c is ${state}")
        [ "$restarts" = 0 ] || PROBLEMS+=("$c restarted ${restarts} time(s)")
    fi
done
printf '%-26s %-10s %8s %8s %8s\n' "total (running)" "" "$(mib "$total_rss")" "$(mib "$total_peak")" "$(mib "$total_limit")"

printf '\n\033[1mClickHouse\033[0m\n'
if docker exec "$CH" true 2>/dev/null; then
    # UNION ALL has no order of its own; the first column fixes one.
    docker exec "$CH" clickhouse-client --user "${CLICKHOUSE_USER:-default}" --password "${CLICKHOUSE_PASSWORD:-}" -q "
        SELECT k, v FROM (
            SELECT 1 AS o, 'server memory tracked' AS k, formatReadableSize(value) AS v
              FROM system.metrics WHERE metric = 'MemoryTracking'
            UNION ALL
            SELECT 2, 'server memory cap', formatReadableSize(toUInt64(value))
              FROM system.server_settings WHERE name = 'max_server_memory_usage' AND value != '0'
            UNION ALL
            SELECT 3, concat('data: ', database), formatReadableSize(sum(bytes_on_disk))
              FROM system.parts WHERE active GROUP BY database
        ) ORDER BY o, k
        FORMAT TSV" 2>&1 | awk -F'\t' '{ printf "  %-28s %s\n", $1, $2 }'
else
    echo "  ${CH} is not running"
fi

if [ "$CHECK" = true ]; then
    echo
    if [ ${#PROBLEMS[@]} -eq 0 ]; then
        printf '\033[32mok\033[0m    every container within its limits: no OOM kills, no restarts\n'
    else
        for p in "${PROBLEMS[@]}"; do printf '\033[31mFAIL\033[0m  %s\n' "$p"; done
        exit 1
    fi
fi
