# Standalone deployment

One Keeper, one ClickHouse, one collector, one backend, SQLite metastore. Right
for a development box, a small team, or anywhere the loss of the host would be
an acceptable outage.

Files: [`deploy/standalone/`](../deploy/standalone/)

---

## Prerequisites

Docker Engine 24+ with Compose v2 (`docker compose version`). Outbound HTTPS to
`github.com` is needed once, for the histogram UDF download. How big a host
depends on the sizing profile; see [Sizing](#sizing).

---

## Sizing

Two profiles. Pick one before `make up`, or switch later; switching keeps your
data:

```bash
make sizing PROFILE=dev        # or PROFILE=default to switch back
make up                        # recreates the containers whose limits changed
```

`make sizing` sets `SIZING_PROFILE` and the container limits in `.env` from
[`sizing/<profile>/limits.env`](../deploy/standalone/sizing/). Nothing else in
`.env` changes.

| | `dev` | `default` |
|---|---|---|
| For | One machine, for testing; low ingest is fine | A server taking real traffic |
| Memory limits, four services together | 1.9 GiB | 13 GiB |
| Largest CPU limit | 1 | 4 (ClickHouse) |
| Host | Any core count, 2 GB of memory free for containers | **4 cores at least**; 16 GB RAM for real traffic |

The core count for `default` is a hard requirement, not advice. Docker refuses
to start a container whose CPU limit is above the host's core count ("range of
CPUs is from 0.01 to N.00, as there are only N CPUs available"), and
`CLICKHOUSE_CPU_LIMIT` is 4. On a smaller host, use `dev` or lower that limit.

### Measured

From a clean start on a 4-core, 16 GB Linux host. *Idle* is two minutes after
`make smoke`. *After load* follows three minutes at 200 spans, 200 log records
and 200 metric points per second, with four dashboard queries through the
SigNoz API every 10 seconds (`scripts/load-test.py --duration 180 --rate 200
--query`). *Resident* is memory the processes hold. *Peak* is the cgroup's
high-water mark, which includes page cache the kernel reclaims before it
OOM-kills, so it overstates what was needed. CI repeats this for both profiles
on every push and puts the numbers in the job summary.

| All four services | `dev` | `default` |
|---|---|---|
| `make up` to healthy | 88 s | 84 s |
| Idle: resident / peak | 439 / 538 MiB | 486 / 677 MiB |
| Idle: ClickHouse CPU | ~6% of a core | ~10% of a core |
| After load: resident / peak | 559 / 802 MiB | 616 / 977 MiB |
| ClickHouse peak, against its limit | 613 MiB of 1 GiB | 787 MiB of 8 GiB |
| Largest single merge | 101 MiB | 463 MiB |
| Dashboard query, median | 0.10–0.27 s | 0.07–0.17 s |
| Spans or logs lost, restarts, OOM kills | none | none |

### On a 2 GB machine

Both profiles again, each with every container inside one 2 GiB memory cgroup,
and a heavier workload: five minutes at 500 per second per signal, the same
dashboard queries, and four heavy ad-hoc queries every 20 seconds (quantiles
over every span, a `GROUP BY trace_id`, a `LIKE` scan of every log body, and
exact distinct counts). For `default`, ClickHouse's container limit was set to
2 GiB as well, because on a real 2 GB machine ClickHouse sizes itself to the
machine's memory, not to the 8 GiB limit. Resident memory was sampled every
second. This test was run by hand, with compose's `cgroup_parent` pointing
every container at one cgroup with a 2 GiB limit; CI does not repeat it.

| 2 GiB for all containers | `dev` | `default` |
|---|---|---|
| Peak resident, all services | 651 MiB | 780 MiB |
| Peak resident, ClickHouse | 468 MiB | 603 MiB |
| Largest single merge | 72 MiB | 515 MiB |
| Heavy query, median / max | 0.20 / 0.47 s | 0.17 / 0.21 s |
| Spans or logs lost, failed queries, OOM kills | none | none |
| Pinned to one core | same result; dashboard medians 0.12–0.43 s | cannot start |

### Is `dev` worth it?

Not for memory at this scale. Both profiles fit in 2 GiB, because most of what
the stack holds is fixed cost: the ClickHouse binary, the metadata of SigNoz's
tables and four runtimes come to about 0.4–0.5 GiB before any telemetry
arrives. Three other things are worth it:

- **Cores.** `default` cannot start on fewer than 4. `dev` caps each
  container at one core, so it starts anywhere, and it ran the 2 GiB test
  above with every container pinned to the same single core.
- **A ceiling.** `dev` fits in 2 GiB by construction: every container is
  capped, and the caps add up to 1.9 GiB. `default` fitted above only because
  the load stayed light. Its own caps add up to 13 GiB, and ClickHouse sizes
  itself to the host. That gave a 1.8 GiB server cap on the 2 GiB machine,
  and gives 7.2 GiB on a 16 GB laptop, with each cache allowed half of the
  machine's memory. ClickHouse grows into those caches as data accumulates
  and is read; this was not measured over days. Under `dev`, ClickHouse stays
  within 922 MiB and its caches within about 800 MiB, whatever the host has,
  so it can run next to an IDE and a browser.
- **Background CPU.** Idle ClickHouse uses about 6% of a core instead of
  about 10%.

The cost is speed. In the 2 GiB runs, single-threaded dashboard queries took
1.2–1.9 times as long (medians of 0.10–0.33 s, against 0.08–0.20 s).

### What `dev` changes

Container limits: ClickHouse 1 GiB and 1 core, collector 256 MiB
(`memory_limiter` at 200 MiB), SigNoz 384 MiB, Keeper 256 MiB and half a core.

ClickHouse tuning, in
[`sizing/dev/clickhouse.xml`](../deploy/standalone/sizing/dev/clickhouse.xml)
and [`clickhouse-users.xml`](../deploy/standalone/sizing/dev/clickhouse-users.xml):

- **What ClickHouse's own docs prescribe for low-memory hosts**
  ([tips.md](https://github.com/ClickHouse/ClickHouse/blob/v25.12.5.44-stable/docs/en/operations/tips.md),
  "Using less than 16GB of RAM"): a 512 MiB mark cache, smaller index caches,
  one query thread, 8192-row blocks, no parallel parsing or formatting, and its
  `metric_log`, `asynchronous_metric_log`, `text_log` and `trace_log` turned
  off. With that tuning, those docs say, ClickHouse runs in "as low as 2 GB";
  `dev` gives it 1 GiB, with the headroom measured above.
- **Vertical merges from the first row.** On this schema, merges use more
  memory than anything else. `signoz_index_v3` has 109 columns and 30 skip
  indexes, and a horizontal merge holds buffers for all of them across every
  part at once: 450–495 MiB per merge measured, even for parts of 1–5 MiB.
  Vertical merges do one column at a time, and the largest merge of any table
  drops to about 100 MiB. ClickHouse switches to vertical only at 131,072 rows,
  which a low-ingest box rarely reaches.

The highest rate measured for `dev` is the 500 per second per signal above.
Past what it can take, the collector's `memory_limiter` refuses data with
`503`, and OTLP SDKs retry and then drop it.

### Disk

The images are a 640 MiB download and take 2.9 GB unpacked. Telemetry is what
grows: the load test's spans and log records cost about 75 bytes each in
ClickHouse, compressed, and metric samples about 7. Real telemetry, with more
attributes, costs more. At a steady 200 per second, that is about 1.3 GB a day
each for traces and for logs. On a dev box, lower retention in
**Settings → Retention**.

Measure your own with `make footprint` (memory and CPU per container against
its limits, data size per database) and `make load` (steady ingest at a rate
you choose, then a check that it all arrived).

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

**Create the admin account before sending any telemetry** — in the UI on first
visit, or headlessly:

```bash
scripts/bootstrap.sh standalone
```

This is a required step, not a nicety. Until an organization exists the backend
will not register the collector over OpAMP, so it never receives a config — and
a collector started with `--manager-config` sits in **no-op mode** until it
does, with every receiver replaced by a `nop` receiver. Nothing is ingested and
port 4318 refuses connections, while the container still reports healthy. The
collector picks up its config within ~30s of the organization existing. Details:
[operations.md](operations.md#nothing-is-ingested-on-a-fresh-install-and-otlp-refuses-connections).

---

## What each file does

### `.env`

Image versions, the ClickHouse password, port bindings, the sizing profile and
resource limits. Git-ignored. `.env.example` is the tracked template.

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
  Only for tables the image already enables: listing a section is enough to
  turn its table on, which is why `zookeeper_log` (two rows for every request
  ClickHouse sends Keeper) and `session_log` are not there.

### `sizing/<profile>/`

One directory per [sizing profile](#sizing), selected by `SIZING_PROFILE` in
`.env`:

- `clickhouse.xml` and `clickhouse-users.xml`, mounted into ClickHouse as
  `config.d/zz-sizing.xml` and `users.d/zz-sizing.xml`. ClickHouse merges those
  directories in sorted order, and the `zz-` prefix puts these last. Empty for
  `default`.
- `limits.env`, the container limits that `make sizing` copies into `.env`.

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

The processors, in pipeline order. The pipelines are `traces`, `metrics` and
`logs`; `scripts/validate.sh` enforces this order in both stacks.

| Processor | Pipelines | What it is for |
|---|---|---|
| `memory_limiter` | all | Sheds load before the container hits its memory limit. Must stay first: it can only shed what nothing has buffered yet |
| `signozspanmetrics/delta` | traces | RED metrics (rate, errors, duration) from spans |
| `signozspanmapper` | traces | Rewrites vendor LLM attributes onto `gen_ai.*`; SigNoz pushes its rules over OpAMP |
| `signozllmpricing` | traces | Per-span LLM cost from SigNoz's pricing rules, pushed over OpAMP. Runs after the mapper, whose output it reads |
| `signozlogsnormalizer` | logs | Structured copy of each log body for SigNoz's JSON log body. UI-built log pipelines run just before it |
| `filter/drop_stale` | all | Drops data timestamped more than 15 days ago |
| `batch` | all | Batches writes to ClickHouse. Last, so it batches only what survived the rest |

See [agents.md](agents.md#llm-and-agent-applications) for what LLM telemetry
needs from the application side.

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

Start from a [sizing profile](#sizing). `CLICKHOUSE_MEMORY_LIMIT` is a
container limit, and ClickHouse sizes its own caches from what it sees. If you
raise it past about 32 GB, also raise `MEMORY_LIMITER_MIB` for the collector
and read [operations.md](operations.md#performance-tuning). Keep
`MEMORY_LIMITER_MIB` at about 80% of `COLLECTOR_MEMORY_LIMIT` whichever way you
move it.

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
