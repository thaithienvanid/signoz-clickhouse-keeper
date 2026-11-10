#!/usr/bin/env python3
"""Steady OTLP/HTTP load against a running stack, for sizing a host.

    scripts/load-test.py [--stack standalone] [--duration 300] [--rate 200]

Sends traces, logs and metrics at a fixed rate for a fixed time, then checks
that every span and log record it sent reached ClickHouse. Run
scripts/footprint.sh afterwards to see what the stack used to absorb it.

--rate is per signal and per second: --rate 200 sends 200 spans, 200 log
records and 200 metric data points every second. Spans come in traces of 5,
each log record carries a trace id, and the metric series are fixed (10 gauge
and 10 counter series plus 1 histogram), so a longer run adds rows, not
cardinality.

--query also queries through the SigNoz API while the data streams in, the
way an open dashboard does: every 10 seconds, a p99 latency series over
traces, an error-count series over logs, a rate over the counter metric, and
a page of raw logs, each over the last hour. Every query must succeed and
return data at least once. It logs in with the admin account
scripts/bootstrap.sh created, and needs --duration 120 or more.

Exits non-zero if a request failed, a query failed, or rows went missing. A
429 or 503 is a failure here: it means the collector's memory_limiter refused
data, so the stack is too small for this rate.

Environment, as in scripts/smoke-test.sh and scripts/bootstrap.sh:
    OTLP_ENDPOINT          default http://localhost:4318
    OTLP_AUTH_HEADER       e.g. "Authorization: Bearer abc123"
    SIGNOZ_ENDPOINT        default http://localhost:8080 (--query)
    SIGNOZ_ADMIN_EMAIL     default admin@example.com (--query)
    SIGNOZ_ADMIN_PASSWORD  required for --query
Only the Python standard library is used.
"""
import argparse
import http.client
import json
import os
import random
import ssl
import subprocess
import statistics
import sys
import threading
import time
import urllib.parse

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CH_CONTAINER = {"standalone": "signoz-clickhouse", "ha": "signoz-clickhouse-1"}
SPANS_PER_TRACE = 5
ROUTES = ["/api/orders", "/api/cart", "/api/users/:id", "/healthz", "/api/search"]
SEVERITIES = [(9, "INFO"), (9, "INFO"), (9, "INFO"), (13, "WARN"), (17, "ERROR")]


def attr(key, value):
    if isinstance(value, bool):
        return {"key": key, "value": {"boolValue": value}}
    if isinstance(value, int):
        return {"key": key, "value": {"intValue": str(value)}}
    return {"key": key, "value": {"stringValue": str(value)}}


def resource(service):
    return {"attributes": [attr("service.name", service),
                           attr("deployment.environment", "load-test"),
                           attr("host.name", "load-generator")]}


def traces_body(service, n, now_ns):
    spans = []
    for _ in range(n // SPANS_PER_TRACE):
        trace_id = os.urandom(16).hex()
        route = random.choice(ROUTES)
        status = 500 if random.random() < 0.02 else 200
        root_id = os.urandom(8).hex()
        root_ms = random.randint(5, 400)
        start = now_ns - root_ms * 1_000_000
        spans.append({
            "traceId": trace_id, "spanId": root_id, "name": f"GET {route}",
            "kind": 2, "startTimeUnixNano": str(start),
            "endTimeUnixNano": str(now_ns),
            "attributes": [attr("http.request.method", "GET"),
                           attr("http.route", route),
                           attr("http.response.status_code", status)],
            "status": {"code": 2 if status >= 500 else 0},
        })
        for i in range(SPANS_PER_TRACE - 1):
            child_start = start + i * root_ms * 1_000_000 // SPANS_PER_TRACE
            spans.append({
                "traceId": trace_id, "spanId": os.urandom(8).hex(),
                "parentSpanId": root_id, "name": f"db.query {i}", "kind": 3,
                "startTimeUnixNano": str(child_start),
                "endTimeUnixNano": str(child_start + random.randint(1, 20) * 1_000_000),
                "attributes": [attr("db.system.name", "postgresql"),
                               attr("db.operation.name", "SELECT")],
            })
    return {"resourceSpans": [{"resource": resource(service),
                               "scopeSpans": [{"scope": {"name": "load-test"},
                                               "spans": spans}]}]}


def logs_body(service, n, now_ns):
    records = []
    for _ in range(n):
        number, text = random.choice(SEVERITIES)
        records.append({
            "timeUnixNano": str(now_ns), "observedTimeUnixNano": str(now_ns),
            "severityNumber": number, "severityText": text,
            "body": {"stringValue": f"{text.lower()} handling {random.choice(ROUTES)} "
                                    f"user={random.randint(1, 5000)} took={random.randint(1, 900)}ms"},
            "traceId": os.urandom(16).hex(), "spanId": os.urandom(8).hex(),
            "attributes": [attr("code.function.name", "handle"),
                           attr("user.id", random.randint(1, 5000))],
        })
    return {"resourceLogs": [{"resource": resource(service),
                              "scopeLogs": [{"scope": {"name": "load-test"},
                                             "logRecords": records}]}]}


def metrics_body(service, n, now_ns, start_ns, counters):
    # 10 gauge series, 10 cumulative counter series, 1 histogram. n is spread
    # over them, so each request carries at most a few points per series.
    per = max(1, n // 21)
    gauges, sums = [], []
    for s in range(10):
        for k in range(per):
            ts = now_ns - (per - 1 - k) * 1_000_000  # oldest first, as the counter rises
            gauges.append({"timeUnixNano": str(ts), "asDouble": random.uniform(0, 100),
                           "attributes": [attr("series", s)]})
            counters[s] += random.randint(1, 10)
            sums.append({"startTimeUnixNano": str(start_ns), "timeUnixNano": str(ts),
                         "asInt": str(counters[s]), "attributes": [attr("series", s)]})
    counts = [random.randint(0, 50) for _ in range(5)]
    hist = [{"startTimeUnixNano": str(start_ns), "timeUnixNano": str(now_ns),
             "count": str(sum(counts)), "sum": float(sum(counts) * 37),
             "bucketCounts": [str(c) for c in counts],
             "explicitBounds": [10.0, 50.0, 100.0, 500.0]}]
    metrics = [
        {"name": "load_test.gauge", "unit": "1", "gauge": {"dataPoints": gauges}},
        {"name": "load_test.requests", "unit": "1",
         "sum": {"aggregationTemporality": 2, "isMonotonic": True, "dataPoints": sums}},
        {"name": "load_test.latency", "unit": "ms",
         "histogram": {"aggregationTemporality": 2, "dataPoints": hist}},
    ]
    return {"resourceMetrics": [{"resource": resource(service),
                                 "scopeMetrics": [{"scope": {"name": "load-test"},
                                                   "metrics": metrics}]}]}


def query_specs(service):
    """The builder queries a dashboard over this service's data would run."""
    svc = f"service.name = '{service}'"
    group = [{"name": "service.name", "fieldContext": "resource"}]
    return {
        "traces p99 by route": ("time_series", {
            "name": "A", "signal": "traces", "stepInterval": "60s", "filter": {"expression": svc},
            "aggregations": [{"expression": "p99(duration_nano)"}],
            "groupBy": [{"name": "http.route", "fieldContext": "attribute"}], "limit": 10}),
        "error logs per minute": ("time_series", {
            "name": "A", "signal": "logs", "stepInterval": "60s",
            "filter": {"expression": f"{svc} AND severity_text = 'ERROR'"},
            "aggregations": [{"expression": "count()"}], "groupBy": group}),
        "request rate": ("time_series", {
            "name": "A", "signal": "metrics", "stepInterval": "60s", "filter": {"expression": svc},
            "aggregations": [{"metricName": "load_test.requests", "timeAggregation": "rate",
                              "spaceAggregation": "sum"}]}),
        "latest logs": ("raw", {
            "name": "A", "signal": "logs", "filter": {"expression": svc}, "limit": 100,
            "order": [{"key": {"name": "timestamp"}, "direction": "desc"}]}),
    }


class Querier(threading.Thread):
    """Runs query_specs() through the SigNoz API every `interval` seconds."""

    def __init__(self, endpoint, email, password, service, interval):
        super().__init__(daemon=True)
        self.endpoint, self.service, self.interval = endpoint.rstrip("/"), service, interval
        self.stop = threading.Event()
        self.latency = {name: [] for name in query_specs(service)}
        self.returned_data = {name: False for name in query_specs(service)}
        self.errors = {}
        self.email, self.password = email, password
        self.login()

    def login(self):
        ctx = self.call("GET", "/api/v2/sessions/context?" + urllib.parse.urlencode(
            {"email": self.email, "ref": self.endpoint}))
        org = ctx["data"]["orgs"][0]["id"]
        session = self.call("POST", "/api/v2/sessions/email_password",
                            {"email": self.email, "password": self.password, "orgId": org})
        self.token = session["data"]["accessToken"]

    def call(self, method, path, body=None, token=None):
        url = urllib.parse.urlparse(self.endpoint + path)
        conn_cls = http.client.HTTPSConnection if url.scheme == "https" else http.client.HTTPConnection
        conn = conn_cls(url.hostname, url.port, timeout=60)
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        path = url.path + ("?" + url.query if url.query else "")
        conn.request(method, path, body=json.dumps(body) if body is not None else None, headers=headers)
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
        if resp.status != 200:
            raise RuntimeError(f"HTTP {resp.status}: {data[:200]!r}")
        return json.loads(data)

    def query(self, body):
        try:
            return self.call("POST", "/api/v5/query_range", body, self.token)
        except RuntimeError as e:
            # Sessions last 30 minutes; log in again once and retry.
            if not str(e).startswith("HTTP 401"):
                raise
            self.login()
            return self.call("POST", "/api/v5/query_range", body, self.token)

    @staticmethod
    def has_data(out):
        result = out["data"]["data"]["results"][0]
        if result.get("rows"):
            return True
        return any(a.get("series") for a in result.get("aggregations") or [])

    def run(self):
        while not self.stop.wait(self.interval):
            end = int(time.time() * 1000)
            for name, (request_type, spec) in query_specs(self.service).items():
                body = {"schemaVersion": "v1", "start": end - 3_600_000, "end": end,
                        "requestType": request_type,
                        "compositeQuery": {"queries": [{"type": "builder_query", "spec": spec}]}}
                t0 = time.monotonic()
                try:
                    out = self.query(body)
                    if out.get("status") != "success":
                        raise RuntimeError(str(out)[:200])
                    self.latency[name].append(time.monotonic() - t0)
                    self.returned_data[name] |= self.has_data(out)
                except (OSError, RuntimeError, ValueError, KeyError, IndexError,
                        http.client.HTTPException) as e:
                    self.errors[f"{name}: {e}"] = self.errors.get(f"{name}: {e}", 0) + 1


class Sender:
    def __init__(self, endpoint, auth_header, cafile):
        url = urllib.parse.urlparse(endpoint)
        self.base = url.path.rstrip("/")
        if url.scheme == "https":
            ctx = ssl.create_default_context(cafile=cafile)
            self.conn = http.client.HTTPSConnection(url.hostname, url.port or 443, timeout=30, context=ctx)
        else:
            self.conn = http.client.HTTPConnection(url.hostname, url.port or 80, timeout=30)
        self.headers = {"Content-Type": "application/json"}
        if auth_header:
            name, _, value = auth_header.partition(":")
            self.headers[name.strip()] = value.strip()
        self.errors = {}

    def post(self, path, body):
        data = json.dumps(body).encode()
        for attempt in (1, 2):
            try:
                self.conn.request("POST", self.base + path, body=data, headers=self.headers)
                resp = self.conn.getresponse()
                resp.read()
                if resp.status == 200:
                    return True
                key = f"{path} HTTP {resp.status}"
                break
            except (OSError, http.client.HTTPException) as e:
                # A keep-alive connection the server closed; reconnect once.
                self.conn.close()
                key = f"{path} {type(e).__name__}"
                if attempt == 2:
                    break
        self.errors[key] = self.errors.get(key, 0) + 1
        return False


def clickhouse(stack, query):
    env = {}
    with open(os.path.join(REPO_ROOT, "deploy", stack, ".env")) as f:
        for line in f:
            if "=" in line and not line.lstrip().startswith("#"):
                k, _, v = line.strip().partition("=")
                env[k] = v
    out = subprocess.run(
        ["docker", "exec", CH_CONTAINER[stack], "clickhouse-client",
         "--user", env["CLICKHOUSE_USER"], "--password", env["CLICKHOUSE_PASSWORD"], "-q", query],
        capture_output=True, text=True, check=True)
    return out.stdout.strip()


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--stack", default="standalone", choices=sorted(CH_CONTAINER))
    p.add_argument("--duration", type=int, default=300, help="seconds (default 300)")
    p.add_argument("--rate", type=int, default=200, help="items per signal per second (default 200)")
    p.add_argument("--batch", type=int, default=100, help="items per request (default 100)")
    p.add_argument("--cacert", help="CA file for an https OTLP endpoint")
    p.add_argument("--query", action="store_true",
                   help="also run dashboard queries through the SigNoz API")
    p.add_argument("--no-verify", action="store_true", help="skip the ClickHouse row count check")
    args = p.parse_args()
    if args.rate < SPANS_PER_TRACE or args.batch < SPANS_PER_TRACE:
        p.error(f"--rate and --batch must be at least {SPANS_PER_TRACE}")
    if args.query and args.duration < 120:
        # The rate query uses one-minute steps, as a dashboard does, and a
        # rate needs two of them.
        p.error("--query needs --duration 120 or more")

    endpoint = os.environ.get("OTLP_ENDPOINT", "http://localhost:4318")
    sender = Sender(endpoint, os.environ.get("OTLP_AUTH_HEADER", ""), args.cacert)
    service = f"load-{int(time.time())}"
    # Spans are sent in whole traces, so round the per-second span count down.
    batch_spans = args.batch - args.batch % SPANS_PER_TRACE
    print(f"sending {args.rate}/s each of spans, log records and metric points "
          f"to {endpoint} for {args.duration}s as service '{service}'")

    querier = None
    if args.query:
        password = os.environ.get("SIGNOZ_ADMIN_PASSWORD")
        if not password:
            p.error("--query needs SIGNOZ_ADMIN_PASSWORD (the admin account bootstrap.sh created)")
        querier = Querier(os.environ.get("SIGNOZ_ENDPOINT", "http://localhost:8080"),
                          os.environ.get("SIGNOZ_ADMIN_EMAIL", "admin@example.com"),
                          password, service, interval=10)
        querier.start()

    start_ns = time.time_ns()
    counters = [0] * 10
    sent = {"spans": 0, "logs": 0, "points": 0}
    start = time.monotonic()
    behind = 0
    for second in range(args.duration):
        left = {"spans": args.rate - args.rate % SPANS_PER_TRACE, "logs": args.rate, "points": args.rate}
        while any(left.values()):
            now_ns = time.time_ns()
            if left["spans"]:
                n = min(batch_spans, left["spans"])
                if sender.post("/v1/traces", traces_body(service, n, now_ns)):
                    sent["spans"] += n
                left["spans"] -= n
            if left["logs"]:
                n = min(args.batch, left["logs"])
                if sender.post("/v1/logs", logs_body(service, n, now_ns)):
                    sent["logs"] += n
                left["logs"] -= n
            if left["points"]:
                n = min(args.batch, left["points"])
                body = metrics_body(service, n, now_ns, start_ns, counters)
                if sender.post("/v1/metrics", body):
                    sent["points"] += n
                left["points"] -= n
        wait = start + second + 1 - time.monotonic()
        if wait > 0:
            time.sleep(wait)
        else:
            behind += 1
        if (second + 1) % 30 == 0:
            print(f"  {second + 1}s: {sent['spans']} spans, {sent['logs']} logs, "
                  f"{sent['points']} points, {sum(sender.errors.values())} failed requests")

    elapsed = time.monotonic() - start
    print(f"sent {sent['spans']} spans, {sent['logs']} log records, {sent['points']} metric points "
          f"in {elapsed:.0f}s")
    ok = True
    if querier:
        querier.stop.set()
        querier.join()
        for name, times in querier.latency.items():
            if times:
                print(f"query {name}: {len(times)} runs, median {statistics.median(times):.2f}s, "
                      f"max {max(times):.2f}s")
        for key, count in sorted(querier.errors.items()):
            print(f"FAIL  {count} x query {key}")
            ok = False
        for name, seen in querier.returned_data.items():
            if querier.latency[name] and not seen:
                print(f"FAIL  query {name} never returned data")
                ok = False
        if not any(querier.latency.values()):
            print("FAIL  no query completed")
            ok = False
    if behind > args.duration // 10:
        print(f"warning: fell behind the target rate in {behind} of {args.duration} seconds; "
              f"the generator, not the stack, may be the limit")
    for key, count in sorted(sender.errors.items()):
        print(f"FAIL  {count} x {key}")
        ok = False

    if not args.no_verify:
        # The collector batches for up to a few seconds before it writes.
        want = {"spans": sent["spans"], "logs": sent["logs"]}
        queries = {
            "spans": f"SELECT count() FROM signoz_traces.distributed_signoz_index_v3 "
                     f"WHERE serviceName = '{service}'",
            "logs": f"SELECT count() FROM signoz_logs.distributed_logs_v2 "
                    f"WHERE resources_string['service.name'] = '{service}'",
        }
        got = {}
        for _ in range(24):
            got = {k: int(clickhouse(args.stack, q)) for k, q in queries.items()}
            if got == want:
                break
            time.sleep(5)
        for k in want:
            if got[k] == want[k]:
                print(f"ok    all {want[k]} {k} are in ClickHouse")
            elif got[k] > want[k]:
                # Sender.post retries once on a dropped connection; if the
                # first attempt had been written, its batch is there twice.
                print(f"FAIL  {got[k]} {k} in ClickHouse for {want[k]} sent: "
                      f"a retried request was written twice")
                ok = False
            else:
                print(f"FAIL  {got[k]} of {want[k]} {k} reached ClickHouse")
                ok = False

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
