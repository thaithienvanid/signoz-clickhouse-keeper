# From one host to real production

[`deploy/ha/`](../deploy/ha/) runs a full HA topology on a single Docker host.
That is genuinely useful — you can kill a Keeper and watch the election, break
replication and watch it heal — but the host is a single point of failure, so
it is a test rig, not a production deployment.

This is what changes when you spread it across machines.

---

## Machine layout

The minimum that tolerates losing a machine is **three**, one of each role
co-located:

| Host | Runs | Sizing |
|---|---|---|
| node-1 | Keeper 1, ClickHouse 1, collector 1, backend 1 | 8+ cores, 32+ GB, NVMe |
| node-2 | Keeper 2, ClickHouse 2, collector 2, backend 2 | same |
| node-3 | Keeper 3, ClickHouse 3 | same |

Separate hosts for Keeper are better if you can afford them — Keeper is
latency-sensitive and ClickHouse merges are I/O-hungry, so they compete. Keeper
itself needs very little: 2 cores, 4 GB, and a **dedicated** fast disk for
`log_storage_path`.

Spread across three availability zones if you have them. Two zones does not
help: whichever zone holds one Keeper loses quorum when the zone with two goes
away.

**Latency between Keeper nodes matters most.** Aim for under 5 ms RTT. Raft
commits a write only after a quorum acknowledges, so every ClickHouse
replicated write pays that round trip. Keeper across regions does not work;
run one cluster per region.

---

## Networking

Compose's per-host bridge network does not span machines. Pick one:

- **Docker Swarm overlay** — closest to what is here; `docker stack deploy`
  takes these compose files with modest edits.
- **Host networking plus real DNS** — replace service names with hostnames
  throughout the configs. Simplest to reason about, most files to change.
- **Kubernetes** — at which point use SigNoz's Helm chart or Foundry's
  Kubernetes casting rather than translating these by hand.

Whichever you choose, the service names in the configs
(`clickhouse-keeper-1`, `clickhouse-1`, `signoz-1`, …) must resolve from every
host. They appear in `raft_configuration`, `<zookeeper>`, `<remote_servers>`,
the collector DSNs, and the nginx upstreams.

### Ports

| Port | Between | Never expose |
|---|---|---|
| 9181 | ClickHouse → Keeper | ✅ internal only |
| 9234 | Keeper ↔ Keeper (Raft) | ✅ internal only |
| 9000 | Collectors/backends → ClickHouse | ✅ internal only |
| 9009 | ClickHouse ↔ ClickHouse (interserver) | ✅ internal only |
| 8123 | ClickHouse HTTP | ✅ internal only |
| 5432 | Backends → Postgres | ✅ internal only |
| 4320 | Collectors → backend (OpAMP) | ✅ internal only |
| 4317/4318 | Clients → nginx | Public, **authenticated** |
| 8080 | Users → nginx | Public, **behind TLS** |

Only the last two should ever leave your network, and both need
[authentication](../deploy/security/README.md) first.

---

## Storage

Named Docker volumes on a single host are fine for testing and wrong for
production.

- **ClickHouse data** — NVMe, local. Not NFS, not a network block device you
  share. ClickHouse's replication *is* your redundancy; a replicated filesystem
  underneath adds latency and buys nothing.
- **Keeper data** — its own disk, separate from ClickHouse. Small (10s of GB)
  but latency-critical because of `force_sync`.
- **RAID** — RAID 10 if you want a node to survive a disk. Not RAID 5; the
  write penalty hurts on a merge-heavy workload.
- **Capacity** — plan for 2× your steady-state estimate. Merges need headroom,
  and ClickHouse goes read-only when a disk fills.

For cold data, ClickHouse's [tiered storage](https://clickhouse.com/docs/en/guides/separation-storage-compute)
moves old parts to S3 while keeping recent data local. That is usually a better
answer than shortening retention.

---

## Postgres

The single-container Postgres in `deploy/ha/` is fine for testing and is a
single point of failure for the UI in production.

Use a managed service (RDS, Cloud SQL) or run Patroni. Then point both backends
at it and delete the `postgres` service:

```yaml
SIGNOZ_SQLSTORE_POSTGRES_DSN: postgres://signoz:...@pg.internal:5432/signoz?sslmode=require
```

Note `sslmode=require`; the bundled config uses `disable` because the traffic
never leaves a Docker bridge.

Losing Postgres stops the UI and alerting. It does **not** stop ingestion —
collectors do not touch the metastore.

---

## TLS between tiers

The bundled stacks use plaintext internally on the assumption that the Docker
network is trusted. Across machines that assumption is usually wrong.

1. **Clients → nginx.** Non-negotiable. Terminate with a real certificate.
2. **nginx → collectors.** Apply the `tls` fragment and have nginx re-originate.
3. **Collectors/backends → ClickHouse.** Enable `<tcp_port_secure>` and switch
   DSNs to `secure=true`.
4. **ClickHouse ↔ ClickHouse, ClickHouse → Keeper.** `<interserver_https_port>`
   and Keeper's `<tcp_port_secure>`.

Layers 3 and 4 are where most people stop, reasonably, if the cluster network is
genuinely isolated. Be deliberate about it rather than defaulting into it.

---

## Load balancers

One nginx in front of everything else you made redundant is a single point of
failure.

- Two or more nginx instances behind a virtual IP (keepalived) or a cloud LB.
- Health checks against real endpoints, not TCP connect — a collector can
  accept connections while refusing to export.
- For gRPC, the LB must speak HTTP/2 end to end. A layer-4 LB works; a layer-7
  one that downgrades to HTTP/1.1 does not.

---

## Backups off-host

`scripts/backup.sh` writes to local disk, which does not survive losing the
machine. Ship them:

```bash
make STACK=ha backup
gpg --symmetric --cipher-algo AES256 backups/ha-*/config.tar.gz
aws s3 sync backups/ s3://your-bucket/signoz/ --sse AES256
```

For anything beyond a small deployment, use
[`clickhouse-backup`](https://github.com/Altinity/clickhouse-backup) — it does
incremental uploads and understands ClickHouse's part structure.

Restore-test quarterly, into a throwaway stack. An untested backup is a guess.

---

## Monitoring the monitoring

SigNoz cannot page you about its own outage.

Keep a minimal external check — anything, including a cron job with `curl` —
watching:

- `GET /api/v1/health` on the backend
- Keeper `mntr` → `zk_followers` ≥ 1
- `system.replicas` → no `is_readonly`
- ingestion rate above zero (a stack that is up and receiving nothing looks
  identical to a healthy idle one)

`scripts/smoke-test.sh` covers all four and exits non-zero on failure, so it
works directly as a cron or CI check.

---

## Operational readiness

Before calling it done:

- [ ] Authentication on the OTLP endpoint
- [ ] TLS on everything crossing a network you do not control
- [ ] Backups running on a schedule, shipped off-host, encrypted
- [ ] A restore actually performed into a throwaway stack
- [ ] Failover exercised: kill a Keeper, kill a ClickHouse node
      ([ha.md](ha.md#testing-failover))
- [ ] External alerting on quorum, replica health, and ingestion rate
- [ ] Retention set, and disk growth measured against it
- [ ] Versions pinned; the ClickHouse compatibility rule checked
      ([upgrading.md](upgrading.md))
- [ ] Credential rotation documented and someone other than you has run it
- [ ] An upgrade rehearsed on a staging stack
