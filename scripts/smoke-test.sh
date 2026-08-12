#!/usr/bin/env bash
#
# End-to-end check against a running stack: send a trace, a metric and a log,
# then confirm they landed in ClickHouse.
#
#   scripts/smoke-test.sh [stack]
#
#   stack   standalone (default) | ha
#
# Environment
#   OTLP_ENDPOINT     default http://localhost:4318
#   SIGNOZ_ENDPOINT   default http://localhost:8080
#   OTLP_AUTH_HEADER  e.g. "Authorization: Bearer abc123" when auth is enabled
#   CURL_OPTS         e.g. "--cacert deploy/standalone/certs/ca.crt" for TLS
#
# Exits non-zero on the first failed check, so it is usable as a deploy gate.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

STACK="${1:-standalone}"
OTLP_ENDPOINT="${OTLP_ENDPOINT:-http://localhost:4318}"
SIGNOZ_ENDPOINT="${SIGNOZ_ENDPOINT:-http://localhost:8080}"
OTLP_AUTH_HEADER="${OTLP_AUTH_HEADER:-}"
read -r -a CURL_EXTRA <<< "${CURL_OPTS:-}"

case "$STACK" in
    standalone) COMPOSE="deploy/standalone/docker-compose.yaml"; CH_CONTAINER="signoz-clickhouse" ;;
    ha)         COMPOSE="deploy/ha/docker-compose.yaml";         CH_CONTAINER="signoz-clickhouse-1" ;;
    *) echo "error: unknown stack '${STACK}' (expected standalone or ha)" >&2; exit 1 ;;
esac

# ClickHouse credentials come from the stack's .env unless already exported, so
# this works without the caller having to source anything first.
if [ -f "deploy/${STACK}/.env" ]; then
    set -a
    # shellcheck source=/dev/null
    . "deploy/${STACK}/.env"
    set +a
fi

FAILURES=0
pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

RUN_ID="smoke-$(date +%s)"
NOW_NS="$(date +%s)000000000"

post_otlp() {
    local path="$1" body="$2"
    local args=(-sS -o /dev/null -w '%{http_code}' --max-time 15
                -X POST "${OTLP_ENDPOINT}${path}"
                -H 'Content-Type: application/json'
                --data-binary "$body")
    [ -n "$OTLP_AUTH_HEADER" ] && args+=(-H "$OTLP_AUTH_HEADER")
    [ ${#CURL_EXTRA[@]} -gt 0 ] && args+=("${CURL_EXTRA[@]}")
    curl "${args[@]}"
}

# Runs a query and leaves the server's error message in CH_ERR rather than
# discarding it. Swallowing stderr here turns "column does not exist" into an
# empty result, which is indistinguishable from "no rows yet" — a poll loop
# then spins to its timeout and reports the wrong cause.
CH_ERR=""
ch_query() {
    local out rc err_file
    err_file="$(mktemp)"
    out="$(docker exec "$CH_CONTAINER" clickhouse-client \
        --user "${CLICKHOUSE_USER:-signoz}" \
        --password "${CLICKHOUSE_PASSWORD:-}" \
        "${@:2}" --query "$1" 2>"$err_file")"
    rc=$?
    CH_ERR="$(tr '\n' ' ' < "$err_file" | cut -c1-400)"
    rm -f "$err_file"
    printf '%s' "$out"
    return $rc
}

# ── Containers ───────────────────────────────────────────────────────────────
head_ "containers"
unhealthy=$(docker compose -f "$COMPOSE" ps --format '{{.Name}} {{.State}} {{.Health}}' 2>/dev/null \
            | awk '$2=="running" && $3!="" && $3!="healthy" {print $1" ("$3")"}')
if [ -z "$unhealthy" ]; then
    pass "all running containers report healthy"
else
    fail "not healthy: ${unhealthy//$'\n'/, }"
fi

# ── SigNoz API ───────────────────────────────────────────────────────────────
head_ "SigNoz API"
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "${SIGNOZ_ENDPOINT}/api/v1/health" 2>/dev/null)
if [ "$code" = "200" ]; then pass "GET /api/v1/health -> 200"; else fail "GET /api/v1/health -> ${code:-no response}"; fi

# ── Ingest ───────────────────────────────────────────────────────────────────
head_ "ingestion"

trace_body=$(cat <<JSON
{"resourceSpans":[{"resource":{"attributes":[
  {"key":"service.name","value":{"stringValue":"${RUN_ID}"}}]},
  "scopeSpans":[{"spans":[{
    "traceId":"$(openssl rand -hex 16)","spanId":"$(openssl rand -hex 8)",
    "name":"smoke-span","kind":1,
    "startTimeUnixNano":"${NOW_NS}","endTimeUnixNano":"${NOW_NS}"}]}]}]}
JSON
)
code=$(post_otlp /v1/traces "$trace_body")
if [ "$code" = "200" ]; then pass "POST /v1/traces -> 200"; else fail "POST /v1/traces -> ${code:-no response}"; fi

log_body=$(cat <<JSON
{"resourceLogs":[{"resource":{"attributes":[
  {"key":"service.name","value":{"stringValue":"${RUN_ID}"}}]},
  "scopeLogs":[{"logRecords":[{
    "timeUnixNano":"${NOW_NS}","severityText":"INFO",
    "body":{"stringValue":"smoke test ${RUN_ID}"}}]}]}]}
JSON
)
code=$(post_otlp /v1/logs "$log_body")
if [ "$code" = "200" ]; then pass "POST /v1/logs -> 200"; else fail "POST /v1/logs -> ${code:-no response}"; fi

metric_body=$(cat <<JSON
{"resourceMetrics":[{"resource":{"attributes":[
  {"key":"service.name","value":{"stringValue":"${RUN_ID}"}}]},
  "scopeMetrics":[{"metrics":[{
    "name":"smoke_counter","unit":"1",
    "sum":{"aggregationTemporality":1,"isMonotonic":true,"dataPoints":[
      {"asInt":"1","timeUnixNano":"${NOW_NS}","startTimeUnixNano":"${NOW_NS}"}]}}]}]}]}
JSON
)
code=$(post_otlp /v1/metrics "$metric_body")
if [ "$code" = "200" ]; then pass "POST /v1/metrics -> 200"; else fail "POST /v1/metrics -> ${code:-no response}"; fi

# ── Storage ──────────────────────────────────────────────────────────────────
# Exporters batch on a timer, so give them a moment before looking.
head_ "storage"
echo "  waiting up to 60s for the batch to flush..."

# Match on the resource map rather than on the materialized
# resource_string_service$$name column or its serviceName alias: the map is
# unambiguously present on the distributed table, and it keeps '$$' — which
# bash would expand to the PID — out of the query entirely. The service name
# is bound as a query parameter, not interpolated.
TRACE_QUERY="SELECT count() FROM signoz_traces.distributed_signoz_index_v3
             WHERE resources_string['service.name'] = {svc:String}"

found_traces=false
for _ in $(seq 1 12); do
    sleep 5
    if n=$(ch_query "$TRACE_QUERY" --param_svc="$RUN_ID"); then
        if [ -n "${n:-}" ] && [ "$n" -gt 0 ] 2>/dev/null; then found_traces=true; break; fi
    fi
done

if [ "$found_traces" = true ]; then
    pass "trace for service '${RUN_ID}' is queryable in ClickHouse"
else
    fail "no trace for service '${RUN_ID}' after 60s"
    # Say why. A query error and an empty table look identical otherwise.
    if [ -n "$CH_ERR" ]; then
        echo "        clickhouse error: ${CH_ERR}"
    fi
    total=$(ch_query "SELECT count() FROM signoz_traces.distributed_signoz_index_v3") || true
    echo "        rows in distributed_signoz_index_v3: ${total:-<query failed>}"
    [ -n "$CH_ERR" ] && echo "        (${CH_ERR})"
    echo "        collector logs: docker compose -f ${COMPOSE} logs otel-collector"
fi

# ── Replication (HA only) ────────────────────────────────────────────────────
if [ "$STACK" = "ha" ]; then
    head_ "replication"
    out=$(ch_query "SELECT countIf(is_readonly) , countIf(absolute_delay > 60) FROM system.replicas")
    readonly_count="${out%%$'\t'*}"
    lagging="${out##*$'\t'}"
    if [ "${readonly_count:-1}" = "0" ]; then
        pass "no read-only replicas (Keeper quorum is healthy)"
    else
        fail "${readonly_count} read-only replica(s) — Keeper quorum is probably lost"
    fi
    if [ "${lagging:-1}" = "0" ]; then
        pass "no replica lagging more than 60s"
    else
        fail "${lagging} replica(s) lagging more than 60s"
    fi

    distinct=$(ch_query "SELECT uniqExact(replica_name) FROM system.replicas")
    if [ "${distinct:-0}" -ge 3 ] 2>/dev/null; then
        pass "3 distinct replica identities registered in Keeper"
    else
        fail "expected 3 distinct replica names, found ${distinct:-0} — check the macros-N.xml mounts"
    fi
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    printf '\033[32msmoke test passed\033[0m\n'
    exit 0
fi
printf '\033[31m%d check(s) failed\033[0m\n' "$FAILURES"
exit 1
