# Standalone deployment

One Keeper, one ClickHouse, one collector, one backend, SQLite metastore. Right
for a development box, a small team, or anywhere the loss of the host would be
an acceptable outage.

Files: [`deploy/standalone/`](../deploy/standalone/)

---

## Prerequisites

| | Minimum | Comfortable |
|---|---|---|
| CPU | 4 cores | 8 cores |
| RAM | 8 GB | 16 GB+ |
| Disk | 50 GB SSD | 250 GB+ NVMe |

Docker Engine 24+ with Compose v2 (`docker compose version`). Outbound HTTPS to
`github.com` is needed once, for the histogram UDF download.

Retention drives disk more than anything else. As a starting estimate,
100k spans/minute at SigNoz's default 15-day trace retention lands somewhere
around 150–250 GB after compression; measure your own rather than trusting that.

---

## Deploy

```bash
make init                          # deploy/standalone/.env from the example
$EDITOR deploy/standalone/.env     # set CLICKHOUSE_PASSWORD
make up
```

`make up` runs `docker compose up -d`. First start takes a few minutes: the
schema migrator creates several hundred tables.

```bash
make ps        # every service healthy, init-clickhouse and schema-migrator exited 0
make smoke     # push telemetry and confirm it is queryable
```

Expected steady state:

```
NAME                       STATUS
signoz                     Up (healthy)
signoz-clickhouse          Up (healthy)
signoz-clickhouse-keeper   Up (healthy)
signoz-otel-collector      Up (healthy)
signoz-init-clickhouse     Exited (0)
signoz-schema-migrator     Exited (0)
```

The two `Exited (0)` containers are correct — they are one-shot jobs.

UI: <http://localhost:8080>.

---

## What each file does

### `.env`

Image versions, the ClickHouse password, port bindings, and resource limits.
Git-ignored. `.env.example` is the tracked template.

The ClickHouse pin is load-bearing — see [upgrading.md](upgrading.md).

### `docker-compose.yaml`

Six services. Three points worth knowing:

**`init-clickhouse`** downloads the `histogramQuantile` binary that SigNoz's
percentile queries over histogram metrics call, into a named volume that
ClickHouse mounts read-only. It short-circuits if the binary is already there,
so restarts do not re-download it.

**`schema-migrator`** runs four commands in order:

```
migrate ready       wait until every host in system.clusters answers
migrate bootstrap   CREATE DATABASE ... ON CLUSTER cluster
migrate sync up     schema changes that must finish before ingestion
migrate async up    materialized views and backfills
```

It uses the *collector* image, not `signoz-schema-migrator`. Both exist and
both work, but the collector's `migrate` subcommands are what current SigNoz
uses, and running one image means one version to keep straight.

**`otel-collector`** starts with `migrate sync check` — it refuses to ingest
against a schema it does not understand — then runs with
`--manager-config=/etc/opamp-config.yaml`. That flag is what connects it to the
SigNoz backend over OpAMP. Without it the collector works, and every log
pipeline you configure in the UI is quietly ignored.

### `clickhouse/config.d/signoz.xml`

A **drop-in overlay**, merged on top of the image's own `config.xml`. It is not
a replacement, and that distinction matters: the image ships
`config.d/docker_related_config.xml`, which is the only thing making ClickHouse
listen on `0.0.0.0`. Replacing `config.xml` wholesale — as most older SigNoz
walkthroughs tell you to — drops it, and the server ends up reachable only from
inside its own container.

Contents:

- `<zookeeper>` pointing at Keeper. The element name is a protocol
  compatibility artifact; there is no ZooKeeper here.
- `<macros>` giving this node its replica identity.
- `<remote_servers><cluster>` — **the name must be `cluster`**. The migrator and
  the backend both default to that exact string.
- `<distributed_ddl>` with cleanup, so finished DDL entries do not accumulate
  in Keeper forever.
- One-day TTLs on ClickHouse's own system logs, which are unbounded by default.

### `clickhouse/custom-function.xml`

Registers `histogramQuantile`. The filename matters: the image's default
`user_defined_executable_functions_config` is the glob `*_function.*ml`, so
this is picked up with no extra configuration.

### `keeper/keeper-config.xml`

Single-node Keeper. Two things people get wrong here:

`compress_logs` and `compress_snapshots_with_zstd_format` are
**`<coordination_settings>`**, not children of `<keeper_server>`. Put them a
level up and ClickHouse ignores them silently — and `compress_logs` defaults to
off, so you lose the compression you thought you enabled.

`four_letter_word_allow_list` is set to the read-only subset. The default list
includes `crst`, `srst`, `rcvr`, `rqld`, `ydld` and `clrs`, which mutate state
on an unauthenticated port; `*`, which older guides suggest, enables all of
them.

### `collector/config.yaml`

The **bootstrap** pipeline config. Once OpAMP connects, UI-managed log pipelines
are merged in at runtime and written to `--copy-path`; this file stays the
source of truth for everything the UI cannot express — receivers, auth, TLS,
memory limits.

Five exporters, and it is worth knowing what each is for, because missing one
produces a UI that looks broken in a specific way:

| Exporter | Database | Missing it means |
|---|---|---|
| `clickhousetraces` | `signoz_traces` | No traces |
| `signozclickhousemetrics` | `signoz_metrics` | No metrics, no RED metrics from spans |
| `clickhouselogsexporter` | `signoz_logs` | No logs |
| `metadataexporter` | `signoz_metadata` | Query-builder attribute autocomplete is empty |
| `signozclickhousemeter` | `signoz_meter` | Usage/metering views are empty |

`sending_queue` is disabled on the ClickHouse exporters, matching upstream: they
batch and retry internally, and an in-memory queue on top mostly adds data to
lose on restart. For durability across restarts, apply the `persistent-queue`
fragment — see [`deploy/security/README.md`](../deploy/security/README.md).

### `collector/opamp.yaml`

One line: the WebSocket endpoint on the SigNoz backend, port 4320. That port is
deliberately not published to the host.

---

## Configuration you are likely to change

### Exposing beyond localhost

`BIND_ADDRESS=0.0.0.0` in `.env`. **Enable authentication first** —
[`deploy/security/README.md`](../deploy/security/README.md). An open OTLP
endpoint accepts writes from anyone who can reach it.

### Restricting browser origins

Uncomment in the `signoz` service:

```yaml
SIGNOZ_GLOBAL_ALLOWED__ORIGINS: https://signoz.example.com
```

The double underscore is a literal `_` in the config key — SigNoz splits env
vars on single underscores to walk the config tree. Values must be
`scheme://host[:port]`; a bare `*` fails validation at startup. An unset value
allows all origins.

### Memory

`CLICKHOUSE_MEMORY_LIMIT` is a container limit; ClickHouse sizes its own caches
from what it sees. If you raise it past about 32 GB, also raise
`MEMORY_LIMITER_MIB` for the collector and read
[operations.md](operations.md#performance-tuning).

### Retention

Set in the UI under **Settings → Retention**, not in these files. SigNoz manages
TTLs on its own tables; editing them directly puts the UI and the database out
of sync.

---

## Backup

```bash
make backup
```

Writes `backups/standalone-<timestamp>/` with the config archive, `signoz.db`,
and an online ClickHouse backup per database.

Backing up ClickHouse alone is a common and expensive mistake: dashboards,
alert rules, users and saved views live in the **metastore**, not in ClickHouse.
`scripts/backup.sh` takes both. The config archive contains `.env` and therefore
your password — encrypt it before it leaves the host.

---

## Moving to HA

The standalone stack is not a subset of the HA stack — the metastore changes
from SQLite to Postgres and every ClickHouse table becomes genuinely replicated
across three nodes. Plan it as a migration: stand up HA alongside, restore a
backup into it, then cut over. [ha.md](ha.md), then
[production.md](production.md).
