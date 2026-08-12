# Version policy and upgrading

## The ClickHouse pin is not optional

```
CLICKHOUSE_VERSION=25.12.5
```

SigNoz's deployment tool carries an explicit compatibility rule
([`foundry/internal/compat/installation/compat.go`](https://github.com/SigNoz/foundry/blob/main/internal/compat/installation/compat.go)):

```go
{
    Subject:  MoldingKindIngester,
    When:     ">0.144.5",
    Target:   MoldingKindTelemetryStore,
    Requires: "=25.12.5",
    Advice:   "pin ingester to 0.144.5, or upgrade telemetrystore clickhouse to 25.12.5",
}
```

Collector versions above 0.144.5 require ClickHouse **exactly** 25.12.5. Not a
floor — an equality.

Docker Hub will happily offer you `clickhouse/clickhouse-server:latest`, which
is a 26.x release. Using it means running a combination SigNoz does not test.
An earlier revision of this repo pinned 26.1.3.52 for exactly that reason, and
it was wrong.

Check the rule before bumping:

```bash
git clone --depth 1 https://github.com/SigNoz/foundry /tmp/foundry
cat /tmp/foundry/internal/compat/installation/compat.go
```

`scripts/validate.sh` verifies every pinned tag still exists on Docker Hub, and
CI runs weekly to catch tags disappearing. It cannot tell you the compatibility
rule has changed — check that by hand before an upgrade.

## Everything else tracks latest stable

| Component | Policy |
|---|---|
| `signoz/signoz` | Latest release |
| `signoz/signoz-otel-collector` | Latest release; also supplies the migrator |
| `postgres` | Latest 16.x |
| `nginx` | Latest stable |

Never use `latest` as a tag. `docker compose pull` then becomes an unplanned
upgrade, and rolling back means guessing what you were on.

---

## Upgrading

### 1. Check for breaking changes

Read the [SigNoz releases](https://github.com/SigNoz/signoz/releases) between
your version and the target. Pay attention to schema migrations and any
required ClickHouse version change.

### 2. Back up

```bash
make backup
```

Non-negotiable. Schema migrations run forward only — there is no `migrate down`
in the deployment path, so the backup is your rollback.

### 3. Bump the pins

```bash
$EDITOR deploy/standalone/.env
```

Move `SIGNOZ_VERSION` and `SIGNOZ_OTEL_COLLECTOR_VERSION` together. They share
a release train, and the collector image supplies the schema migrator, so a
mismatch means the schema and the reader disagree.

### 4. Validate

```bash
make validate      # confirms the new tags exist
make pull
```

### 5. Apply

```bash
make up
```

Compose recreates changed services only. The schema migrator re-runs and
applies pending migrations before the backend starts.

### 6. Verify

```bash
make ps
make smoke
make logs SERVICE=signoz | tail -50
```

Then look at the UI: a dashboard with historical data, a recent trace, and an
alert rule. Migrations can succeed while a schema change breaks a query path.

---

## Rolling back

If the new version is bad and **migrations have not run**, revert the tags in
`.env` and `make up`.

Once migrations have run, rolling the images back is not enough — the schema
has moved ahead of the old binaries. Restore instead:

```bash
make down
$EDITOR deploy/standalone/.env         # previous tags
make up
make restore FROM=backups/standalone-<timestamp>
```

You lose telemetry ingested since the backup. This is the reason step 2 is not
optional.

---

## Upgrading HA

Same sequence, with the ordering that keeps the cluster serving:

1. `make STACK=ha backup`
2. Bump `deploy/ha/.env`
3. `make STACK=ha pull`
4. **ClickHouse one node at a time**, waiting for each to rejoin:
   ```bash
   docker compose -f deploy/ha/docker-compose.yaml up -d --no-deps clickhouse-1
   make STACK=ha replication-status    # wait for absolute_delay ~ 0
   # then clickhouse-2, then clickhouse-3
   ```
5. **Keeper one node at a time**, keeping quorum throughout:
   ```bash
   docker compose -f deploy/ha/docker-compose.yaml up -d --no-deps clickhouse-keeper-1
   make STACK=ha keeper-status         # wait for it to rejoin
   ```
6. Migrator, then backends, then collectors:
   ```bash
   docker compose -f deploy/ha/docker-compose.yaml up -d
   ```
7. `make STACK=ha smoke`

Never restart two Keepers at once. Two down out of three is a lost quorum, and
ClickHouse goes read-only until it returns.

---

## Deciding between this and Foundry

SigNoz [deprecated its bundled compose manifests](https://github.com/SigNoz/signoz/blob/main/deploy/README.md)
in favour of [Foundry](https://github.com/SigNoz/foundry), which generates
deployment manifests from a `casting.yaml`.

**Use Foundry** if you want vendor-supported installs and upgrades and are
content for a generator to own your manifests. It handles the compatibility
rule above for you, and it also defaults to ClickHouse Keeper.

**Use this repo** if you want to read, diff and own the compose files. The
topology, environment variables, collector pipelines and ClickHouse settings
here are cross-checked against Foundry's output, so you get the same deployment
shape and keep the files under your own review process — at the cost of
tracking upstream changes yourself.

Migrating to Foundry later is straightforward: your volumes carry the data, and
Foundry's [migration guide](https://github.com/SigNoz/signoz/blob/main/deploy/MIGRATION.md)
covers reattaching them. Note that its examples reattach a *ZooKeeper* volume;
coming from here you will be reattaching Keeper's, and you will need the
`macros` values from your `config.d/macros-*.xml` to match your existing data.
