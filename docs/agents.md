# Connecting application agents

Pointing OpenTelemetry SDKs at the collector. All of these assume the default
`http://localhost:4318`; substitute your gateway address.

---

## Environment variables first

Every OpenTelemetry SDK reads the same standard variables, so this usually needs
no code at all:

```bash
export OTEL_SERVICE_NAME=payments-api
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_RESOURCE_ATTRIBUTES=deployment.environment=production,service.version=1.4.2
```

Set `deployment.environment` and `service.version`. SigNoz's span metrics use
both as dimensions, and without them every environment collapses into one set
of RED metrics.

### With authentication

```bash
# Bearer token
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer ${TOKEN}"

# Basic auth
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic $(printf 'ingest:%s' "$PASSWORD" | base64 -w0)"
```

### With TLS

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://otel.example.com:4318
export OTEL_EXPORTER_OTLP_CERTIFICATE=/etc/ssl/certs/signoz-ca.crt
```

### With mTLS

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://otel.example.com:4318
export OTEL_EXPORTER_OTLP_CERTIFICATE=/etc/ssl/certs/signoz-ca.crt
export OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE=/etc/ssl/certs/client-payments-api.crt
export OTEL_EXPORTER_OTLP_CLIENT_KEY=/etc/ssl/private/client-payments-api.key
```

---

## gRPC or HTTP

| | gRPC (4317) | HTTP (4318) |
|---|---|---|
| Throughput | Higher | Good |
| Proxy support | Needs HTTP/2 end to end | Works through anything |
| Browsers | No | Yes (CORS) |
| Debugging | `grpcurl` | `curl` |

Default to HTTP unless you have measured a reason not to. It survives
misconfigured intermediaries that silently break gRPC.

---

## Node.js

```javascript
const { NodeSDK } = require('@opentelemetry/sdk-node');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-proto');
const { OTLPMetricExporter } = require('@opentelemetry/exporter-metrics-otlp-proto');
const { PeriodicExportingMetricReader } = require('@opentelemetry/sdk-metrics');

// Endpoint, headers and resource attributes come from OTEL_* env vars.
const sdk = new NodeSDK({
  traceExporter: new OTLPTraceExporter(),
  metricReader: new PeriodicExportingMetricReader({
    exporter: new OTLPMetricExporter(),
    exportIntervalMillis: 60000,
  }),
  instrumentations: [getNodeAutoInstrumentations()],
});

sdk.start();
process.on('SIGTERM', () => sdk.shutdown().finally(() => process.exit(0)));
```

Register this before anything else — auto-instrumentation patches modules at
require time, so libraries loaded first are not traced. Use
`node --require ./tracing.js app.js`.

Setting credentials in code instead:

```javascript
new OTLPTraceExporter({
  url: 'https://otel.example.com:4318/v1/traces',
  headers: { Authorization: `Bearer ${process.env.SIGNOZ_TOKEN}` },
});
```

---

## Python

The zero-code path is usually best:

```bash
pip install opentelemetry-distro opentelemetry-exporter-otlp
opentelemetry-bootstrap --action=install
opentelemetry-instrument python app.py
```

Explicitly:

```python
from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

resource = Resource.create({
    "service.name": "payments-api",
    "deployment.environment": "production",
    "service.version": "1.4.2",
})

provider = TracerProvider(resource=resource)
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(
    endpoint="http://localhost:4318/v1/traces",
    headers={"Authorization": f"Bearer {os.environ['SIGNOZ_TOKEN']}"},
)))
trace.set_tracer_provider(provider)
```

`BatchSpanProcessor`, not `SimpleSpanProcessor` — the latter exports one span
per network call and will dominate your latency.

---

## Java

The agent needs no code changes:

```bash
java -javaagent:/path/to/opentelemetry-javaagent.jar \
     -Dotel.service.name=payments-api \
     -Dotel.exporter.otlp.endpoint=http://localhost:4318 \
     -Dotel.exporter.otlp.protocol=http/protobuf \
     -Dotel.exporter.otlp.headers=Authorization=Bearer\ ${SIGNOZ_TOKEN} \
     -jar app.jar
```

For mTLS the agent reads PEM files directly — no keystore conversion needed:

```bash
-Dotel.exporter.otlp.certificate=/etc/ssl/certs/signoz-ca.crt
-Dotel.exporter.otlp.client.certificate=/etc/ssl/certs/client.crt
-Dotel.exporter.otlp.client.key=/etc/ssl/private/client.key
```

The client key must be PKCS#8. `scripts/gen-certs.sh` emits that already; to
convert an existing key:

```bash
openssl pkcs8 -topk8 -nocrypt -in client.key -out client-pkcs8.key
```

---

## Go

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
    "go.opentelemetry.io/otel/sdk/resource"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
    semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

func initTracing(ctx context.Context) (func(context.Context) error, error) {
    exp, err := otlptracehttp.New(ctx) // reads OTEL_EXPORTER_OTLP_* from the env
    if err != nil {
        return nil, err
    }

    res, err := resource.New(ctx,
        resource.WithFromEnv(),
        resource.WithAttributes(semconv.ServiceName("payments-api")),
    )
    if err != nil {
        return nil, err
    }

    tp := sdktrace.NewTracerProvider(
        sdktrace.WithBatcher(exp),
        sdktrace.WithResource(res),
    )
    otel.SetTracerProvider(tp)
    return tp.Shutdown, nil
}
```

Call the returned shutdown on exit, or the last batch never leaves the process.

---

## Containers and Kubernetes

Compose:

```yaml
services:
  payments-api:
    environment:
      OTEL_SERVICE_NAME: payments-api
      OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector:4318
      OTEL_EXPORTER_OTLP_PROTOCOL: http/protobuf
      OTEL_RESOURCE_ATTRIBUTES: deployment.environment=production
    networks: [signoz-net]     # the network the SigNoz stack created
```

Kubernetes — put the shared values in a ConfigMap and the token in a Secret:

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: http://signoz-otel-collector.observability:4318
  - name: OTEL_SERVICE_NAME
    valueFrom: {fieldRef: {fieldPath: metadata.labels['app']}}
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: deployment.environment=production,k8s.namespace.name=$(POD_NAMESPACE)
  - name: OTEL_EXPORTER_OTLP_HEADERS
    valueFrom: {secretKeyRef: {name: signoz-ingest, key: authorization}}
```

---

## Verifying

```bash
# Reachable and accepting?
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:4318/v1/traces \
  -H 'Content-Type: application/json' \
  -d '{"resourceSpans":[]}'
# 200 — accepted. 401 — auth required or wrong. 000 — nothing listening.
```

Then check the collector actually took it:

```bash
docker exec signoz-otel-collector wget -qO- http://localhost:8888/metrics \
  | grep -E 'receiver_accepted_spans|receiver_refused_spans'
```

`accepted` rising is what you want. `refused` rising means the collector is
shedding load — see [operations.md](operations.md#performance-tuning).

---

## Common problems

**Spans never appear.** Check service name and time range in the UI first —
clock skew on the sending host puts spans outside the window you are looking at.

**`connection refused`.** From another container, `localhost` is that
container. Use the service name and make sure both are on the `signoz-net`
network.

**`401 Unauthorized`.** Confirm the header format:
`Authorization=Bearer <token>` in `OTEL_EXPORTER_OTLP_HEADERS`, no `Bearer`
prefix duplicated, no trailing newline in the token (`openssl rand -hex 32 >
file` adds one — `tr -d '\n'` it).

**`x509: certificate is not valid for ...`.** The certificate's SAN list does
not contain the name you dialled. Reissue with
`scripts/gen-certs.sh <stack> --host <name>`. Go ignores the Common Name
entirely.

**gRPC works locally, fails through a proxy.** Something in the path is not
speaking HTTP/2. Switch to HTTP on 4318, or fix the proxy.
