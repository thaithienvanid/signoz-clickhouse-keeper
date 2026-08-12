# Operations

Monitoring, backup, scaling, tuning and troubleshooting for both stacks.

Every command takes `STACK=ha` where relevant.

---

## Health at a glance

```bash
make ps                    # container state
make keeper-status         # Raft leader / followers / synced followers
make cluster-status        # ClickHouse cluster membership and error counts
make replication-status    # replica lag and read-only state
make smoke                 # end-to-end: send telemetry, query it back
```

`make smoke` is the one that matters. Containers can be healthy while telemetry
silently fails to land — a wrong DSN, a schema mismatch, a collector that
started before migrations finished. It sends a trace, a log and a metric, then
queries ClickHouse for the trace.

---

## What to alert on

Use SigNoz to watch SigNoz where you can, but keep at least the first two of
these on something external — a monitoring system that dies with the thing it
monitors tells you nothing.

| Signal | Query / source | Why |
|---|---|---|
| Keeper quorum | `mntr` → `zk_followers` < 1 | Below quorum ClickHouse is read-only |
| Replica read-only | `system.replicas.is_readonly > 0` | Keeper unreachable from that node |
| Replica lag | `system.replicas.absolute_delay > 60` | Falling behind; queries return stale data |
| Refused spans | `otelcol_receiver_refused_spans` rising | Collector shedding load — memory limiter or backpressure |
| Failed exports | `otelcol_exporter_send_failed_*` rising | ClickHouse rejecting writes |
| Queue near full | `otelcol_exporter_queue_size` vs `queue_capacity` | Next stop is dropped data |
| ClickHouse memory | `system.metrics` `MemoryTracking` vs limit | OOM kill risk |
| Disk headroom | `system.disks.free_space` | ClickHouse goes read-only when full |
| DDL queue depth | `system.distributed_ddl_queue` pending | Migrations stuck |

Collector metrics come from its internal telemetry endpoint (`:8888/metrics` by
default). It is not published to the host; scrape it from inside the network or
publish it deliberately.

---

## Useful queries

```sql
-- Storage by database
SELECT database,
       formatReadableSize(sum(bytes_on_disk)) AS size,
       sum(rows) AS rows
FROM system.parts WHERE active
GROUP BY database ORDER BY sum(bytes_on_disk) DESC;

-- Ingestion rate over the last hour, by signal
SELECT toStartOfMinute(timestamp) AS minute, count() AS spans
FROM signoz_traces.distributed_signoz_index_v3
WHERE timestamp > now() - INTERVAL 1 HOUR
GROUP BY minute ORDER BY minute DESC LIMIT 20;

-- Replica health (HA)
SELECT database, table, replica_name, is_readonly,
       absolute_delay, active_replicas, total_replicas,
       queue_size, inserts_in_queue, merges_in_queue
FROM system.replicas
WHERE database LIKE 'signoz%' ORDER BY absolute_delay DESC;

-- Slowest queries in the last day
SELECT query_duration_ms, read_rows,
       formatReadableSize(memory_usage) AS mem, substring(query, 1, 120) AS q
FROM system.query_log
WHERE type = 'QueryFinish' AND event_time > now() - INTERVAL 1 DAY
ORDER BY query_duration_ms DESC LIMIT 10;

-- Anything erroring
SELECT event_time, query_duration_ms, exception, substring(query, 1, 120) AS q
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing' AND event_time > now() - INTERVAL 1 HOUR
ORDER BY event_time DESC LIMIT 20;

-- Stuck distributed DDL
SELECT entry, host, status, exception_code
FROM system.distributed_ddl_queue
WHERE status != 'Finished' ORDER BY entry_version DESC LIMIT 20;
```

Run them with:

```bash
docker exec -it signoz-clickhouse clickhouse-client \
  --user signoz --password "$CLICKHOUSE_PASSWORD"
```

---

## Backup and restore

```bash
make backup                                   # or STACK=ha
make restore FROM=backups/standalone-20260812T101500Z
```

### What gets backed up

| Artifact | Contains |
|---|---|
| `config.tar.gz` | Compose files, all configs, **and `.env` — so, your passwords** |
| `metastore-signoz.db` / `metastore-postgres.sql.gz` | Dashboards, alert rules, users, saved views, API keys |
| `clickhouse/*.zip` | One online `BACKUP DATABASE` per SigNoz database |
| `MANIFEST.txt` | Image tags and digests at backup time |

**Back up the metastore.** Every dashboard you have built, every alert rule,
every user lives there and not in ClickHouse. A ClickHouse-only backup restores
your data into an empty product.

The config archive holds `.env`. Encrypt it before it leaves the host:

```bash
gpg --symmetric --cipher-algo AES256 backups/standalone-*/config.tar.gz
```

### ClickHouse backups are online

`BACKUP ... TO Disk()` runs against a live server; no downtime. The script adds
a `backups` disk at runtime if one is not configured and tells you how to make
it permanent. To keep it, add to `deploy/<stack>/clickhouse/config.d/`:

```xml
<clickhouse>
    <storage_configuration><disks><backups>
        <type>local</type>
        <path>/var/lib/clickhouse/backups/</path>
    </backups></disks></storage_configuration>
    <backups><allowed_disk>backups</allowed_disk></backups>
</clickhouse>
```

For off-host backups at scale, look at
[`clickhouse-backup`](https://github.com/Altinity/clickhouse-backup), which does
incremental uploads to S3. The script here is deliberately dependency-free.

### Restore

`scripts/restore.sh` **drops and recreates** the SigNoz databases and overwrites
the metastore. It prompts before doing either. It deliberately does not restore
configuration over a running deployment — unpack `config.tar.gz` by hand if
that is what you want.

Test your restore path on a throwaway stack before you need it.

---

## Scaling

### Vertical, in order of effect

1. **RAM for ClickHouse.** Query performance is mostly page cache. Raise
   `CLICKHOUSE_MEMORY_LIMIT`.
2. **Faster disk.** NVMe over SATA SSD; SSD over anything spinning. Merges are
   I/O bound.
3. **Cores for ClickHouse.** Parallel query execution scales with them.
4. **Collector CPU.** Only once `otelcol_receiver_refused_spans` is nonzero.

### Horizontal

**More collectors** — stateless, add replicas and an upstream entry. This is
the first thing to scale; ingestion saturates before query does.

**More ClickHouse replicas** — add a node, give it its own `macros-N.xml` with
a new `replica` value, add it to `<remote_servers>`, restart the cluster to
reload config. It clones from an existing replica automatically.

**Sharding** — only when one node can no longer hold the working set. Each new
shard needs its own replicas, or you have traded availability for capacity. See
the reasoning in [ha.md](ha.md#why-one-shard-with-three-replicas).

**Keeper** — do not scale it. Three is right for almost everything; five only
for very large clusters. More members means more Raft round-trips per write.
Never run an even number: four tolerates the same single failure as three.

---

## Performance tuning

### Collector

`.env`:

```bash
MEMORY_LIMITER_MIB=1600        # ~80% of COLLECTOR_MEMORY_LIMIT
MEMORY_LIMITER_SPIKE_MIB=320
```

`memory_limiter` must stay first in every pipeline — it can only shed load it
sees before anything else has buffered it.

For sustained high throughput, larger batches trade latency for efficiency:

```yaml
processors:
  batch:
    send_batch_size: 100000
    send_batch_max_size: 110000
    timeout: 10s
```

Raise the collector's memory limit alongside — bigger batches are held in
memory longer.

### ClickHouse

Drop-ins go in `deploy/<stack>/clickhouse/config.d/`. Start with a `<profiles>`
override; the defaults are tuned for general use, not for append-heavy
observability data.

```xml
<clickhouse>
    <profiles><default>
        <!-- Cap a single query rather than letting it take the server down -->
        <max_memory_usage>10000000000</max_memory_usage>
        <max_bytes_before_external_group_by>5000000000</max_bytes_before_external_group_by>
    </default></profiles>

    <!-- Repeated dashboard queries are a good fit for the query cache -->
    <query_cache>
        <max_size_in_bytes>1073741824</max_size_in_bytes>
        <max_entries>1024</max_entries>
    </query_cache>
</clickhouse>
```

Before tuning anything, look at `system.query_log`. Most "ClickHouse is slow"
reports are one dashboard panel scanning a month of spans, not a configuration
problem.

### Keeper

`force_sync: true` (the shipped default) fsyncs every Raft write. It is the
setting that makes a quorum durable through a simultaneous power loss, and it
costs write latency. Turning it off is defensible on a dev box and hard to
justify in production.

If Keeper writes are genuinely your bottleneck, put its `log_storage_path` on a
dedicated fast disk before you weaken durability.

---

## Troubleshooting

### Nothing starts

```bash
make logs SERVICE=clickhouse
```

- **Port already in use** — something else on 8080/4317/4318. Change the port
  variables in `.env`.
- **`bind source path does not exist`** — usually the security overlay without
  a generated config. Run `scripts/apply-security.sh <stack> <fragment>` first,
  or `make clean` to drop back to the base config.
- **ClickHouse exits immediately** — check for a directory where a config file
  should be: `docker exec signoz-clickhouse ls -la /etc/clickhouse-server/config.d/`.

### `schema-migrator` never finishes

Almost always the cluster name. `migrate ready` runs
`SELECT ... FROM system.clusters WHERE cluster = 'cluster'` and waits for every
host it finds. If `<remote_servers>` declares anything other than `cluster`, it
finds nothing and blocks until timeout.

```bash
make cluster-status    # must list a cluster named exactly 'cluster'
```

### Data does not appear in the UI

Work down the path:

```bash
# 1. Is the collector accepting it?
docker exec signoz-otel-collector wget -qO- http://localhost:8888/metrics \
  | grep -E 'receiver_accepted|receiver_refused'

# 2. Is it exporting successfully?
docker exec signoz-otel-collector wget -qO- http://localhost:8888/metrics \
  | grep -E 'exporter_sent|exporter_send_failed'

# 3. Is it in ClickHouse?
docker exec signoz-clickhouse clickhouse-client --user signoz --password "$CLICKHOUSE_PASSWORD" \
  --query "SELECT count() FROM signoz_traces.distributed_signoz_index_v3 WHERE timestamp > now() - INTERVAL 10 MINUTE"

# 4. Backend errors?
make logs SERVICE=signoz
```

`accepted` rising but `sent` flat means the exporter cannot write — check
credentials and the ClickHouse logs. Both flat means nothing is arriving; check
the client's endpoint and any auth you enabled.

### Log pipelines configured in the UI do nothing

The collector has no OpAMP session. Confirm `--manager-config` is on its command
line and that it can reach the backend:

```bash
docker inspect signoz-otel-collector --format '{{join .Config.Cmd " "}}' | grep manager-config
make logs SERVICE=otel-collector | grep -i opamp
```

### Keeper quorum lost

```bash
make STACK=ha keeper-status
```

With 2 of 3 down, start them — they rejoin and catch up on their own.

If a Keeper will not rejoin, its log is corrupt or too far behind. Stop it,
delete that node's `coordination/log` and `coordination/snapshots`, and start it
again; it re-syncs from the leader. **Only ever do this to a minority of nodes.**
Wiping a majority loses the cluster's state.

### High memory

```bash
docker exec signoz-clickhouse clickhouse-client --user signoz --password "$CLICKHOUSE_PASSWORD" --query "
SELECT metric, formatReadableSize(value) FROM system.asynchronous_metrics
WHERE metric LIKE '%Memory%' ORDER BY value DESC LIMIT 10"
```

Usually a query, not a leak. Find it in `system.query_log`, then cap it with
`max_memory_usage` in a profile override.

### Replica lagging

```bash
make STACK=ha replication-status
```

`absolute_delay` growing with a large `queue_size` means that node cannot keep
up — check its disk I/O first. If `is_readonly` is 1, it has lost its Keeper
connection; that is a Keeper problem, not a replication one.

---

## Routine maintenance

**Weekly** — `make smoke`; check disk headroom; skim `system.query_log` for new
slow queries.

**Monthly** — test a restore into a throwaway stack; review retention against
actual disk growth; check for SigNoz releases.

**Quarterly** — exercise failover ([ha.md](ha.md#testing-failover)); rotate
credentials (`scripts/gen-htpasswd.sh`, token files, ClickHouse password);
review who has UI access.
