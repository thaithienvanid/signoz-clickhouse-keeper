# Securing the ingestion endpoint

Both stacks start with **no authentication** and publish their ports on
`127.0.0.1` only. That is deliberate: an unauthenticated OTLP endpoint on a
public interface is an open write channel into your telemetry store. Before you
change `BIND_ADDRESS`, turn something on here.

Security is applied by deep-merging a **fragment** into the stack's collector
config, then bringing the stack up with an overlay:

```bash
scripts/apply-security.sh <stack> <fragment>...
cd deploy/<stack>
docker compose -f docker-compose.yaml -f compose.security.yaml up -d
```

The base `collector/config.yaml` is never modified. Re-running the script always
rebuilds `config.generated.yaml` from scratch, so switching schemes is one
command, not an unpick.

## Choosing

| Fragment | Proves | Use when |
|---|---|---|
| `basic-auth` | Client knows a username + password | Internal network, simplest thing that works |
| `bearer-auth` | Client holds an API key | Programmatic senders, per-team key rotation |
| `tls` | Server identity; traffic encrypted | Anything crossing a network you do not own |
| `mtls` | Both identities, cryptographically | Zero-trust; no shared secret to leak |
| `persistent-queue` | *(not security)* durability across restarts | You cannot ask clients to resend |

`tls` and the auth fragments are complementary — TLS says *who the server is*,
auth says *who the client is*. Compose them:

```bash
scripts/apply-security.sh standalone tls bearer-auth
```

`mtls` is the exception: the client certificate *is* the credential, so it needs
no auth fragment, and it already contains everything `tls` does. The script
refuses `tls mtls` together.

## Basic auth

```bash
scripts/gen-htpasswd.sh standalone ingest     # prints a generated password once
scripts/apply-security.sh standalone basic-auth
```

Rotate by re-running `gen-htpasswd.sh` with the same username — it replaces that
user's line and leaves everyone else alone.

Clients send a standard `Authorization: Basic` header:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic $(printf 'ingest:%s' "$PASSWORD" | base64 -w0)"
```

## Bearer token

```bash
mkdir -p deploy/standalone/secrets
openssl rand -hex 32 >> deploy/standalone/secrets/tokens.txt
sudo chown 10001 deploy/standalone/secrets/tokens.txt   # see "File ownership" below
sudo chmod 600 deploy/standalone/secrets/tokens.txt
scripts/apply-security.sh standalone bearer-auth
```

The file holds one token per line, so rotation is: append the new token, move
clients across, delete the old line, restart the collector.

```bash
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer ${TOKEN}"
```

## TLS

```bash
scripts/gen-certs.sh standalone --host otel.example.com
scripts/apply-security.sh standalone tls
```

`gen-certs.sh` issues certificates **with Subject Alternative Names**. This is
not a detail: Go's TLS stack — which every OpenTelemetry SDK and the collector
itself use — ignores the Common Name entirely and rejects a certificate whose
SAN list does not contain the name being dialled. The `openssl` recipes in most
older SigNoz walkthroughs omit SANs and produce certificates that cannot be
used by any modern client.

Clients need the CA:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://otel.example.com:4318
export OTEL_EXPORTER_OTLP_CERTIFICATE=/path/to/ca.crt
```

For a public endpoint, use a real CA instead and drop the files into
`deploy/<stack>/certs/` as `ca.crt`, `server.crt` and `server.key`; nothing else
changes.

## mTLS

```bash
scripts/gen-certs.sh standalone --client payments-api
scripts/apply-security.sh standalone mtls
```

Issue one certificate per client. Revoking a client means removing its
certificate and re-issuing the CA bundle — `client_ca_file_reload: true` means
the collector picks that up without a restart.

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://otel.example.com:4318
export OTEL_EXPORTER_OTLP_CERTIFICATE=/path/to/ca.crt
export OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE=/path/to/client-payments-api.crt
export OTEL_EXPORTER_OTLP_CLIENT_KEY=/path/to/client-payments-api.key
```

## Durable ingestion queue

Not authentication, but the other thing people want before calling an ingestion
path production-ready.

```bash
scripts/apply-security.sh standalone persistent-queue
```

By default the ClickHouse exporters run with `sending_queue` **disabled** — they
batch and retry in-process, and in-flight data is lost if the collector restarts
or ClickHouse stays down past the retry budget. This fragment backs the queue
with `file_storage` on a named volume, so batches survive a restart and drain
when ClickHouse returns. It costs disk I/O on the ingest path.

## File ownership

The collector image declares `USER 10001`, so anything it must read has to be
readable by that uid — not just by you. A secret left at mode `0600` owned by
your host user is invisible inside the container, and the extension that needs
it fails at startup.

`gen-certs.sh` and `gen-htpasswd.sh` handle this: they `chown` the files the
collector needs to uid 10001 and keep them at mode `0600`. Run them with `sudo`
(or as root) and that just works. Without root they fall back to mode `0644`
and print a warning — readable by the container, and by every other local user,
which is the trade-off you are accepting.

Two files deliberately stay yours and never get chowned:

| File | Why |
|---|---|
| `certs/ca.key` | The signing key. It is never mounted into any container. |
| `certs/client-*.key` | Belongs to the client, not the collector. |

Verify the uid against the image rather than trusting this number:

```bash
docker inspect signoz/signoz-otel-collector:v0.144.8 --format '{{.Config.User}}'
```

The same applies to the `persistent-queue` fragment, but the compose overlay
takes care of it: a fresh named volume is created root-owned, so an
`init-collector-queue` service chowns it to 10001 before the collector starts.

## Where TLS belongs in HA

In the HA stack nginx is the only thing clients reach, so the usual choice is to
terminate TLS at nginx and leave the collectors plaintext on the internal Docker
network. Applying the `tls` fragment instead encrypts all the way to the
collector, which is what you want when the container network is not itself
trusted — but then nginx has to re-originate TLS to its upstreams. Pick one
deliberately.

## Verifying

```bash
# Should be rejected
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:4318/v1/traces \
  -H 'Content-Type: application/json' -d '{"resourceSpans":[]}'

# Should be accepted
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:4318/v1/traces \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' -d '{"resourceSpans":[]}'
```

`scripts/smoke-test.sh` does this and more; pass credentials through
`OTLP_AUTH_HEADER`.
