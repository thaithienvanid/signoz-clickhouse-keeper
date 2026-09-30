# Migrating to SigNoz Foundry

[Foundry](https://github.com/SigNoz/foundry) is SigNoz's own deployment tool.
You describe a deployment in a `casting.yaml`, and `foundryctl` generates the
compose file and configs from it. This runbook moves a **standalone** stack
from this repo onto a Foundry-generated compose stack, keeping your telemetry,
dashboards, alerts and users. You can roll back with `make up` until you
delete the old volumes.

The HA stack is not covered; see [HA](#ha) at the end.

---

## Should you?

Both paths run the same SigNoz on the same ClickHouse and ClickHouse Keeper
versions. Foundry defaults to Keeper too, not ZooKeeper. What differs is who
owns the files.

**Move to Foundry** if you would rather SigNoz maintained the deployment
shape. Upgrades become a version bump in `casting.yaml`, and Foundry refuses
to generate a pairing that breaks its compatibility rules (see
[upgrading.md](upgrading.md)). You stop tracking upstream changes by hand, the
way this repo has had to for the collector pipeline and the ClickHouse pin.

**Stay here** if you rely on what Foundry's compose output does not do. Every
row below is from `foundryctl` v0.3.0 output, forged from
[`deploy/foundry/casting.yaml`](../deploy/foundry/casting.yaml):

| This repo | Foundry compose output |
|---|---|
| ClickHouse user with a password from `.env` | `default` user, empty password (reachable only on the compose network) |
| Ports on `127.0.0.1` | Every interface, unless patched (the casting here patches them) |
| `memory_limiter` first in every collector pipeline | No `memory_limiter` |
| CPU/memory limits, `nofile` ulimits, log rotation on every service | None |
| Keeper: read-only four-letter-word list, `force_sync`, compressed logs | `*` (all commands, including mutating ones), `force_sync: false`, no compression |
| TLS, auth and persistent-queue overlays (`scripts/apply-security.sh`) | None; you write them into the ingester config yourself |
| `make backup` / `restore` / `smoke` / `bootstrap` | None of these target Foundry's container names |
| HA stack: nginx in front of 2 collectors, 2 backends, 3 ClickHouse, 3 Keepers | Replicas without a load balancer (see [HA](#ha)) |

Most of the table can be closed from the casting: `config.data` merges into
the generated ClickHouse, Keeper and collector configs, and `patches` edits the
compose file. At that point you are maintaining hardening on top of generated
files instead of the files themselves. That is a reasonable trade, but still a
trade.

## Why this is a backup and restore, not a volume reattach

It is tempting to point Foundry at the existing volumes. That breaks
replication without deleting anything, which makes it the worst kind of
failure:

| | This repo | Foundry |
|---|---|---|
| ClickHouse macros | `shard=01`, `replica=replica-01` | `shard=00`, `replica=00` |
| Keeper `server_id` / Raft host | `1` / `clickhouse-keeper` | `0` / `signoz-telemetrykeeper-clickhousekeeper-0` |
| Volume names | `signoz_clickhouse-data`, … | `signoz-telemetrystore-0-0-data`, … |

Replicated tables resolve their Keeper path through the macros. With different
macros they look in the wrong place, find no metadata, and go read-only.

A native ClickHouse `RESTORE` into the new stack sidesteps all three problems:
it writes fresh Keeper metadata under Foundry's macros. Your old volumes stay
untouched, and they are the rollback.

---

## Before you start

- **Same versions on both sides.** The backup carries ClickHouse schema and
  migration state as they are, so the new stack must run exactly the images the
  old one does. `deploy/foundry/casting.yaml` pins the same tags as
  `deploy/standalone/.env.example`, and `scripts/validate.sh` fails if they
  drift. If your running stack is behind the repo's pins, upgrade it first
  ([upgrading.md](upgrading.md)).
- **A maintenance window.** From step 1 to step 6 nothing is ingested and the
  UI is down. OTel SDKs and agents retry and buffer for a while; anything past
  their buffer is dropped.
- **Disk.** You need room for the backup plus a second full copy of your
  ClickHouse data. The old volumes are kept until you delete them.
- **foundryctl**, pinned to the version this runbook was checked against:
  ```bash
  curl -fsSL https://signoz.io/foundry.sh | FOUNDRY_VERSION=v0.3.0 bash
  foundryctl version
  ```

## 1. Stop ingestion and record what you have

Stop the collector first. That way the backup is the final state, and nothing
lands in the old stack after it:

```bash
docker compose -f deploy/standalone/docker-compose.yaml stop otel-collector
```

Record row counts to compare against after the restore:

```bash
set -a; . deploy/standalone/.env; set +a
for t in signoz_traces.distributed_signoz_index_v3 \
         signoz_logs.distributed_logs_v2 \
         signoz_metrics.distributed_samples_v4; do
  docker exec signoz-clickhouse clickhouse-client \
    --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
    -q "SELECT '$t', count() FROM $t"
done | tee before.txt
```

## 2. Back up, then stop the old stack

```bash
make backup                       # prints backups/standalone-<timestamp>
B=backups/standalone-<timestamp>  # the directory it printed
ls "$B" "$B/clickhouse"
```

Expect `metastore-signoz.db` and one `.zip` per SigNoz database. That means six,
including `signoz_analytics` (alert state history). Backups taken before this
runbook existed did not include `signoz_analytics`; take a fresh one.

Then stop the old stack. **Do not use `make nuke` or `down -v`** — those
volumes are your rollback:

```bash
make down
```

## 3. Generate and start the Foundry stack

```bash
foundryctl forge -f deploy/foundry/casting.yaml -p deploy/foundry/pours
FC="docker compose -f deploy/foundry/pours/deployment/compose.yaml"
$FC up -d --wait
```

This is a fresh install. The migrator creates an empty schema and SigNoz an
empty metastore. The ingester stays in no-op mode, because there is no
organization yet.

## 4. Restore ClickHouse

Stop everything that writes, then replace each database with the backup's copy:

```bash
$FC stop signoz-signoz-0 ingester

CH=signoz-telemetrystore-clickhouse-0-0
docker exec "$CH" mkdir -p /var/lib/clickhouse/backups
for path in "$B"/clickhouse/*.zip; do
  name=$(basename "$path"); db=${name%%-*}
  echo "restoring $db"
  docker cp "$path" "$CH:/var/lib/clickhouse/backups/$name"
  docker exec "$CH" clickhouse-client -q "DROP DATABASE IF EXISTS $db SYNC"
  docker exec "$CH" clickhouse-client -q "RESTORE DATABASE $db FROM Disk('backups', '$name')"
  docker exec "$CH" rm -f "/var/lib/clickhouse/backups/$name"
done
```

No credentials here: Foundry's ClickHouse `default` user has an empty password.

## 5. Restore the metastore

Copy the SQLite file into Foundry's metastore volume while SigNoz is stopped.
Remove any `-wal`/`-shm` sidecars left by the fresh install first, or SQLite
will replay them over your database:

```bash
docker run --rm \
  -v signoz-metastore-sqlite-0-data:/data \
  -v "$PWD/$B:/backup:ro" \
  alpine sh -c 'rm -f /data/signoz.db-wal /data/signoz.db-shm &&
                cp /backup/metastore-signoz.db /data/signoz.db'
```

## 6. Start SigNoz, then the collector

```bash
$FC up -d --wait signoz-signoz-0
$FC start ingester
```

The restored metastore already has your organization, so SigNoz pushes the
collector its config over OpAMP. The collector picks it up within about 30s and
leaves no-op mode.

## 7. Verify

**OTLP is accepting data.** The check is a real request, because the port
accepts TCP connections even in no-op mode. Retry for up to a minute:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:4318/v1/traces \
  -H 'Content-Type: application/json' -d '{"resourceSpans":[]}'   # want 200
```

**Row counts** match `before.txt`:

```bash
for t in signoz_traces.distributed_signoz_index_v3 \
         signoz_logs.distributed_logs_v2 \
         signoz_metrics.distributed_samples_v4; do
  docker exec "$CH" clickhouse-client -q "SELECT '$t', count() FROM $t"
done | diff before.txt - && echo "counts match"
```

Run this before clients reconnect; afterwards the counts only grow.

**Replication is healthy.** Both columns should be `0`:

```bash
docker exec "$CH" clickhouse-client \
  -q "SELECT countIf(is_readonly), countIf(absolute_delay > 60) FROM system.replicas"
```

**The UI** at <http://localhost:8080>. Log in with your existing account;
everyone has to log in again anyway (see the CHANGELOG entry for SigNoz
v0.144.0). Check that dashboards, alert rules and saved views are there, and
that a dashboard shows data from before the migration.

Clients need no changes: the host and ports are the same.

## Rolling back

Until you delete the old volumes:

```bash
$FC down          # add -v to also discard the Foundry volumes
make up
```

The old stack resumes exactly where step 2 left it. Anything ingested by the
Foundry stack in the meantime is not carried back.

## Cleaning up

After a soak period you are comfortable with, delete the old stack's volumes:

```bash
docker volume ls --filter label=com.docker.compose.project=signoz
docker volume rm signoz_clickhouse-data signoz_clickhouse-keeper-data \
                 signoz_clickhouse-user-scripts signoz_signoz-sqlite
```

That is the point of no return.

---

## Running on Foundry

- **Upgrades:** bump the images in `casting.yaml`, then:
  ```bash
  foundryctl forge -f deploy/foundry/casting.yaml -p deploy/foundry/pours
  $FC up -d --force-recreate
  ```
  Foundry's own docs say to recreate every service together. Docker does not
  restart containers when only mounted config changes, and restarting Keeper
  alone leaves ClickHouse unable to reconnect.
- **Backups:** `scripts/backup.sh` targets this repo's container names. The
  statements it runs still work against `signoz-telemetrystore-clickhouse-0-0`
  (`BACKUP DATABASE … TO Disk('backups', …)`, and the casting keeps the
  `backups` disk). The SQLite file is in the `signoz-metastore-sqlite-0-data`
  volume; stop `signoz-signoz-0` before copying it.
- **Hardening:** see the table above. Close the gaps that matter to you with
  `config.data` and `patches` in the casting.

## HA

Not covered, and deliberately so. From `foundryctl` v0.3.0, a compose casting
with replicas generates the replica containers but no load balancer:

- scaled ingesters lose their host ports (Foundry's docs say so);
- each backend gets its own host port (8080, 9080, …).

Foundry points at its swarm and Kubernetes castings for load-balanced
replicas.

Mind the replica count if you try it. For `telemetrystore`, Foundry counts
`replicas` as copies *beyond the first*: `replicas: 2` gives this repo's three
ClickHouse nodes, and `replicas: 3` gives four. Every casting (compose, swarm,
Helm, Kustomize, systemd) applies that `+ 1`, so it is intended, but Foundry's
casting reference does not say so. `signoz`, `ingester` and `telemetrykeeper`
count the total, so `telemetrykeeper` `replicas: 3` is three Keepers.

The same backup-and-restore principle applies to the HA stack. The metastore is
a `pg_dump` restored with `psql`, and ClickHouse is restored on one replica and
replicates to the rest. But the target layout is different enough that it
needs its own runbook, tested against a real Foundry swarm or Kubernetes
deployment.
