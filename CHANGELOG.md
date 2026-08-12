# Changelog

## 2026-08-12 — Fixes from the first real CI run

The end-to-end job in `.github/workflows/validate.yml` stood the standalone
stack up for real and found things static validation could not. All four are
the same shape: a command or file that is fine on the host but wrong inside the
container it runs in.

- **The collector health check called `wget`, which its image does not have.**
  `signoz/signoz-otel-collector` is built on `debian:bookworm-slim` — no `wget`,
  no `curl`. The check failed with "executable not found", Docker marked the
  container unhealthy, and `docker compose up --wait` aborted the whole deploy
  even though the collector was running correctly and its health extension was
  serving on 13133. Replaced with an HTTP request built from bash builtins
  (`/dev/tcp`, `printf`, `read`), which needs nothing but `bash`.
- **`nginx -t` in CI could not resolve its own upstreams.** nginx resolves
  `upstream` hostnames at config-parse time, so testing the config in a bare
  container failed with "host not found in upstream" regardless of syntax. The
  config was correct; the test was wrong. Now stubs the service names via
  `--add-host`.
- **Secrets were unreadable by the collector.** It runs as `USER 10001`, so the
  mode-0600 certificates and `.htpasswd` written by `gen-certs.sh` and
  `gen-htpasswd.sh` — owned by the host user — were invisible inside the
  container. Both scripts now `chown` the files the collector needs to that uid
  and keep them at 0600, falling back to 0644 with an explicit warning when not
  running as root. `ca.key` and client keys deliberately stay host-owned.
- **The persistent-queue volume was unwritable.** A fresh named volume is
  created root-owned, so `file_storage` could not write to it as uid 10001. The
  security overlays now run an `init-collector-queue` service that chowns it
  first.

**Creating the organization is a required deployment step, not cosmetic.** An
earlier revision of this changelog claimed the `cannot create agent without
orgId` errors on a fresh install were harmless and that "ingestion is
unaffected". That was wrong, and the end-to-end job proved it: every OTLP POST
returned `000` and `distributed_signoz_index_v3` stayed empty.

What actually happens is a chain:

1. A new deployment has no organization.
2. The collector connects over OpAMP; the backend refuses to register an agent
   without one.
3. The backend therefore never pushes the collector a config.
4. A collector started with `--manager-config` **begins in no-op mode** — it
   replaces every receiver in every pipeline with a `nop` receiver and drops
   the processors (`opamp/server_client.go`, `initialNopConfig`) — and leaves
   that mode only when a server config arrives.
5. So no OTLP listener binds and nothing is ingested.

The container reports healthy the entire time; no-op mode exists precisely so
health checks pass while an agent waits for its first config. `docker compose
ps` shows the ports published and the collector `Up (healthy)` while port 4318
refuses connections.

Added `scripts/bootstrap.sh` (and `make bootstrap`) to create the organization
and admin user headlessly, wired it into CI between startup and the smoke test,
and corrected the README, `docs/standalone.md` and `docs/operations.md`.

**Known coverage gap:** CI runs the standalone stack end to end. The HA stack is
statically validated (compose resolution, `nginx -t`, replica-identity and
cluster-name assertions) but is not stood up, so its runtime path has not been
exercised the way standalone's now has.

## 2026-08-12 — Deployable stacks, corrected configuration, supported versions

This revision replaces a single 2,670-line guide whose embedded configuration
could not be deployed as written. The configs are now real files under
`deploy/`, validated in CI, and reconciled against what SigNoz's own deployment
tooling generates.

If you built a deployment from the previous guide, treat the sections below as
a defect list rather than a changelog: several of these prevent the stack from
starting, and two of them fail silently while looking healthy.

### Version corrections

- **ClickHouse `26.1.3.52` → `25.12.5`.** This is a *downgrade*, and it is the
  correct direction. SigNoz declares in
  [`foundry/internal/compat/installation/compat.go`](https://github.com/SigNoz/foundry/blob/main/internal/compat/installation/compat.go)
  that collector `> 0.144.5` requires ClickHouse `= 25.12.5`. The previous pin
  put the deployment outside SigNoz's supported matrix. Newer tags existing on
  Docker Hub is not the same as SigNoz supporting them.
- **`latest` → pinned tags** for `signoz` (`v0.136.1`) and
  `signoz-otel-collector` (`v0.144.8`). The old `.env` recommended pinning in a
  comment and then used `latest` anyway, so every `docker compose pull` was an
  unplanned upgrade.
- **`signoz/signoz-schema-migrator` → `signoz-otel-collector migrate`.**
  Migrations now run through the collector image's `migrate` subcommands
  (`ready`, `bootstrap`, `sync up`, `async up`), matching current SigNoz. The
  old setup also ran only the *sync* migrations — async migrations never ran at
  all.

### Defects that prevented startup

- **Undefined variables in `docker-compose.yml`.** `.env` defined
  `SIGNOZ_VERSION`, `OTELCOL_VERSION` and `SCHEMA_MIGRATOR_VERSION`; the compose
  file referenced `SIGNOZ_BACKEND_VERSION`, `SIGNOZ_OTEL_COLLECTOR_VERSION` and
  `SIGNOZ_SCHEMA_MIGRATOR_VERSION`. Three of the six images resolved to `:`.
- **Malformed health checks.** `interval: 30s; timeout: 5s; retries: 3` is one
  YAML key with the string value `30s; timeout: 5s; retries: 3` — not three
  keys. Every health check in both compose files was affected.
- **`depends_on: signoz: {condition: service_healthy}`** where the `signoz`
  service defined no health check at all. Compose rejects this outright.
- **Missing files.** The compose file mounted `./clickhouse/config.xml`,
  `./clickhouse/users.xml` and `./signoz/prometheus.yml`; the guide said there
  were "6 configuration files" and provided none of those three. Docker creates
  a directory in place of a missing bind-mount source, so ClickHouse would have
  started against a directory where its config should be.
- **`command: ["--config=/root/config/prometheus.yml"]` on the SigNoz backend.**
  Current `signoz` is a Cobra CLI with `server`, `generate` and `metastore`
  subcommands and no such flag. The Prometheus scrape config it pointed at is
  no longer part of SigNoz's configuration at all.
- **`SIGNOZ_SERVER_ALLOWED_ORIGINS=*`.** Wrong key — SigNoz maps
  `SIGNOZ_<section>_<key>`, so this resolved to `server.allowed.origins`, which
  does not exist. The real key is `SIGNOZ_GLOBAL_ALLOWED__ORIGINS` (the double
  underscore is a literal `_`), and it validates entries as
  `scheme://host[:port]` — a bare `*` fails startup validation. Now omitted,
  since an empty list already allows all origins.

### Defects that failed silently

These are the dangerous ones: the stack comes up, reports healthy, and is wrong.

- **Every HA node claimed the same replica identity.** `cluster-ha.xml`
  contained a single `<macros>` block with `shard=01, replica=replica_1`, and
  `docker-compose.ha.yml` mounted that one file into all three ClickHouse
  containers. A comment in the file said to override it per node; nothing did.
  All three nodes would register as the same replica of the same shard in
  Keeper. There is now one `macros-N.xml` per node, and `scripts/validate.sh`
  asserts the three values are distinct.
- **The ClickHouse cluster was named `cluster_1S_1R` / `cluster_3S_2R`.** The
  schema migrator and the SigNoz backend both default to a cluster named
  literally `cluster`. `migrate ready` queries
  `system.clusters WHERE cluster = 'cluster'`, finds no hosts, and waits until
  it times out. Both stacks now use `cluster`, and validation enforces it.
- **Keeper compression settings were in the wrong place.** `compress_logs` and
  `compress_snapshots_with_zstd_format` were children of `<keeper_server>`;
  ClickHouse reads them from `<coordination_settings>`. Unknown keys are
  ignored, so `compress_logs` — which defaults to `false` — was never enabled.
- **The collector wrote to ClickHouse but was never managed by SigNoz.** No
  `--manager-config`, so no OpAMP session: log parsing pipelines configured in
  the UI reached nothing.
- **Missing exporters.** `metadataexporter`, `signozclickhousemeter` and the
  `signozmeter` connector were absent, so query-builder attribute autocomplete
  and SigNoz's metering views had no data.
- **The `prometheus` exporter was defined and never used in a pipeline**, while
  `signoz-prometheus.yml` scraped `otel-collector:8889` for metrics nothing was
  exporting.
- **Self-signed certificates had no Subject Alternative Names.** The `openssl`
  recipe set only a CN. Go's TLS stack — used by the collector and every OTel
  SDK — ignores CN entirely and rejects such certificates. The documented TLS
  and mTLS setups could not have worked with any client.

### Security

- **ClickHouse is no longer passwordless.** The official image restricts the
  built-in `default` user to localhost when no credentials are configured,
  which would have blocked SigNoz from connecting; the old guide papered over
  this with a `users.xml` it never provided. Both stacks now create a real user
  from `CLICKHOUSE_USER` / `CLICKHOUSE_PASSWORD`.
- **Ports bind to `127.0.0.1` by default** rather than every interface. An
  unauthenticated OTLP endpoint is an open write channel into your telemetry
  store; exposing it is now a deliberate edit.
- **Keeper's four-letter-word allow-list is the read-only subset** instead of
  `*`. The previous `*` enabled mutating commands (`crst`, `srst`, `rcvr`,
  `rqld`, `ydld`, `clrs`) on an unauthenticated port.
- **Security is applied by merging fragments**, not by hand-editing the
  collector config. The old instructions had readers replace
  `service.extensions` with `[basicauth/server]`, which drops the health-check
  extension and breaks the container health check. The merge unions those lists
  and CI asserts `signoz_health_check` survives all ten combinations.
- **Secrets are git-ignored** (`.env`, `certs/`, `secrets/`, `*.key`). The old
  guide's backup section instructed readers to `git add .env` and push.

### Configuration improvements

- ClickHouse is configured through a **`config.d/` drop-in** rather than by
  replacing `config.xml`. Replacing it discards the image's
  `docker_related_config.xml`, which is what makes ClickHouse listen on
  `0.0.0.0` — a replacement config that omits `listen_host` leaves the server
  reachable only from inside its own container.
- The **histogram UDF** is registered via `custom-function.xml`, matching the
  image's default `*_function.*ml` glob, and cached in a named volume so the
  download is not repeated on every deploy.
- **System-log TTLs** (1 day) on `query_log`, `trace_log`, `part_log` and the
  rest. Unbounded by default, and on an observability host they will outgrow
  the telemetry they describe.
- **Resource limits, `nofile` ulimits, and log rotation** on every service.
- **`memory_limiter` first in every collector pipeline**, sized from `.env`
  relative to the container's memory limit.
- **Health checks that reflect real endpoints**: `/api/v1/health` for SigNoz
  (the old guide's `depends_on` waited on a health check that did not exist),
  `:13133` for the collector, `ruok`/`imok` for Keeper.

### HA changes

- **Postgres metastore.** The old HA stack ran SigNoz with SQLite on a local
  volume. SQLite cannot be shared between backends, so the topology could not
  actually scale past one — and the diagram showed two.
- **One shard × three replicas** instead of `cluster_3S_2R`. Three shards with
  no replicas survives no node failures; the previous file offered both
  topologies and the migrator would have used neither correctly, since neither
  was named `cluster`.
- **Replicated schema migrations** (`--replication`, default on) so tables are
  created as `Replicated*` `ON CLUSTER cluster`.
- **nginx actually configured for the traffic it carries**: HTTP/2 via
  `http2 on` (the `listen ... http2` form the old config used is deprecated
  since nginx 1.25.1), gRPC upstream retries, WebSocket upgrade headers for the
  UI's live tail, and its own health endpoint.

### Added

- `Makefile` — `up`, `down`, `logs`, `backup`, `keeper-status`,
  `cluster-status`, `replication-status`, `nuke`, all stack-aware.
- `scripts/validate.sh` — static validation of every compose file, XML, YAML
  and fragment combination, plus a live check that pinned image tags exist.
- `scripts/smoke-test.sh` — pushes a trace, log and metric, then queries
  ClickHouse to confirm they landed; checks replica health on HA.
- `scripts/backup.sh` / `restore.sh` — online ClickHouse backups **plus the
  metastore**. The old guide backed up ClickHouse only, which loses every
  dashboard, alert rule, user and saved view.
- `scripts/gen-certs.sh` — CA, server and per-client certificates with correct
  SANs and extended key usages.
- `scripts/apply-security.sh` — fragment merge tool.
- `.github/workflows/validate.yml` — static validation, `nginx -t`, and a real
  end-to-end deploy on every push, plus a weekly run to catch upstream drift.
- `docs/` — split walkthroughs for standalone, HA, operations, production and
  upgrades.
