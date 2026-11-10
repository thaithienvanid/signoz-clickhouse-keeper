# Changelog

## 2026-11-10 — A `dev` sizing profile, measured footprints, and less Keeper logging

### Before you upgrade

- **Nothing to change in `.env`.** It gains one key, `SIZING_PROFILE`, and
  compose treats a missing one as `default`. `make up` recreates ClickHouse
  once, because its mounts change.
- **ClickHouse stops writing `system.zookeeper_log` and `system.session_log`,
  on both stacks.** Both are off in the ClickHouse image. `signoz.xml` and the
  HA `cluster.xml` turned them on by accident: they listed the two sections to
  give them a TTL, and listing a section is enough to enable its table.
  `zookeeper_log` is ClickHouse's log of its own requests to Keeper (the name
  predates Keeper): two rows per request, with the data read or written. It
  was the largest table on a fresh standalone stack, at about 700,000 rows
  while the schema migrator ran. Nearly all of those were ClickHouse polling
  the distributed DDL queue until each of the migrator's 354 `ON CLUSTER`
  statements finished. `aggregated_zookeeper_log` stays on, with per-second
  counts, result codes and latency; [operations.md](docs/operations.md#keeper)
  shows how to read it. Existing rows expire within a day through the TTL, or
  `DROP TABLE system.zookeeper_log SYNC` removes them now.
  If you used `session_log` to audit logins, put the section back in a
  `config.d` file of your own.

### Added

- **`dev` sizing profile** for running the standalone stack on one machine for
  testing: `make sizing PROFILE=dev && make up`. It caps the four services at
  1.9 GiB of memory together and at most one core each, so it starts on any
  machine. ClickHouse gets the tuning its documentation gives for low-memory
  hosts (smaller caches, one query thread, four of its own log tables off). It
  also merges vertically from the first row, which on this schema cut the
  largest merge in the measured run from 463 MiB to 101 MiB. At low load
  `default` fits in 2 GiB too, on a machine with 4 cores; what `dev` adds is
  starting on fewer cores, a hard memory ceiling, and less background CPU. The
  trade is ingest rate and query speed. `make sizing PROFILE=default` switches
  back, and data is kept. Measured numbers, including a run on a simulated
  2 GiB machine, are in [docs/standalone.md](docs/standalone.md#sizing).
- **`make footprint`** (`scripts/footprint.sh`): memory and CPU per container
  against its limits, restarts and OOM kills, and ClickHouse data size.
  `--check` fails on an OOM kill or a restart.
- **`make load`** (`scripts/load-test.py`): steady OTLP traces, logs and
  metrics at a fixed rate, then checks that every span and log record reached
  ClickHouse. `--query` also runs dashboard queries through the SigNoz API
  while it loads. Python standard library only.
- **CI runs the end-to-end job once per profile**, adding three minutes of load
  with queries and a `footprint --check`. Each run's footprint goes to the job
  summary.

### Fixed

- **The documented requirements were not measured, and missed a hard one.**
  Docker refuses to start a container whose CPU limit exceeds the host's core
  count, so the default `.env` (`CLICKHOUSE_CPU_LIMIT=4`) cannot start on fewer
  than 4 cores at all. The README and docs/standalone.md now give measured
  numbers per profile.
- The header of `deploy/standalone/docker-compose.yaml` pointed at
  `../security/compose.tls.yaml`, which does not exist. It now shows
  `apply-security.sh` and `compose.security.yaml`.

## 2026-11-08 — SigNoz v0.149.0; GenAI observability checked end to end

### Before you upgrade

- **Upgrade for security.** In v0.144.0, any logged-in user can reach an SQL
  injection through `POST /api/v1/rules/{id}/history/{stats,timeline,
  top_contributors,overall_status}`. v0.147.0 removed those endpoints in favour
  of parameterised `/api/v2/rules/{id}/history/*` equivalents.
- **Take a backup: metastore migrations 131–143 run on startup, and none can be
  reversed.** Most add permission tuples. The ones that rewrite or delete data:
  - 131 adds a stored `spec` to notification channels and permanently renames
    the `msteamsv2` channel type to `msteams`;
  - 135 deletes SigNoz-synced LLM pricing rules that fail new checks (your own
    rules are kept);
  - 137, 140 and 142 rewrite the built-in roles' transaction groups;
  - 139 deletes role rows of deleted service accounts;
  - 141 rewrites traces saved views to the new field names.
  As always, `make backup` is the rollback.
- **Upgrade SigNoz and the collector together.** Collector v0.144.13 adds
  metadata migration 1002, a row that tells SigNoz to read trace attributes from
  the JSON `attributes` column. v0.145.0 and later read it only behind a
  feature flag, off by default. v0.144.0 has no flag and switches straight
  away. In this repo the migrator runs before the new backend starts, so the
  old backend sees the row only while compose recreates it. Results are the
  same either way, because the collector has written that column since
  v0.144.10.
- **Nobody is logged out this time.** The tokenizer and session code did not
  change.

### Versions

- **`signoz/signoz` `v0.144.0` → `v0.149.0`.** Six releases (v0.145.0,
  v0.146.0, v0.147.0, v0.148.0, v0.148.1, v0.149.0). Every configuration key
  the compose files set still resolves, and the image, entrypoint, ports, OpAMP
  endpoint, `/api/v1/health` and `/api/v1/register` are unchanged. v0.148.0
  sets a ClickHouse setting that needs 25.6 or later, which 25.12.5 meets.
- **`signoz/signoz-otel-collector` `v0.144.12` → `v0.144.15`.**
  - Two sync migrations, both metadata-only:
    - traces 1018 adds four bloom-filter indexes on JSON attribute paths:
      `http.route`, `rpc.method`, `gen_ai.request.model` and
      `gen_ai.provider.name`. Existing parts get them as they merge.
    - metadata 1002 adds the row described above.
  - `migrate async up` has nothing new, and no new database appears, so
    `scripts/backup.sh` still covers everything.
  - The image, user, CLI flags and `migrate` subcommands are unchanged.
  - The LLM cost formula changed in v0.144.13 in how it bills cached tokens, so
    a given rule can price a span differently from before.
  - grpc 1.83.2 rejects gRPC requests that carry neither `:authority` nor
    `Host`. Conformant clients and nginx's `grpc_pass` send `:authority`.
- **`foundryctl` `v0.3.0` → `v0.5.0`**, in CI and in `docs/foundry.md`. The
  casting forges the same compose file, container names, volumes and patch
  targets as before. Every claim in the runbook's comparison table and its HA
  section was re-checked against v0.5.0 output.
- **Unchanged on purpose:**
  - **ClickHouse and Keeper `25.12.5`.** Foundry's compatibility rule
    (collector `> 0.144.5` requires clickhouse `= 25.12.5`) is unchanged.
  - **`postgres` `16-alpine`**, now 16.15. A major-version jump needs a
    data-directory upgrade, and Foundry still ships 16.
  - **`nginx` `1.30-alpine`**, now 1.30.6. 1.30 is still the stable branch.
  - **`actions/checkout@v7`**, now 7.0.1.
  - **The histogram-quantile UDF `v0.0.1`.** It is still the only release.

### Collector config

Both stacks now match the config Foundry generates for collector v0.144.15,
except that `memory_limiter` stays first in every pipeline:

```
traces:  memory_limiter, signozspanmetrics/delta, signozspanmapper, signozllmpricing, filter/drop_stale, batch
metrics: memory_limiter, filter/drop_stale, batch
logs:    memory_limiter, signozlogsnormalizer, filter/drop_stale, batch
```

- **`signozlogsnormalizer`** (new in collector v0.144.13; this config needs
  v0.144.15) rewrites each log body into a map for SigNoz's upcoming JSON log
  body, and keeps the original for the regular `body` column.
  - **Ordering.** SigNoz v0.146.0+ inserts the log pipelines you build in the
    UI just before it, so they still see raw bodies. That is also why it goes
    after `memory_limiter`: placed first, as Foundry does, it would pull the UI
    pipelines ahead of the memory limiter.
  - **Cost.** The structured copy takes extra storage, and SigNoz only queries
    it behind its experimental JSON-body flag. The config comment says how to
    turn it off.
- **`filter/drop_stale`** drops logs, datapoints and spans timestamped more than
  15 days ago, just before `batch`.
  - Logs and spans: the exporters already apply this limit.
  - Metrics: this is new. Backfilling older metrics is now dropped; raise the
    window if you do that on purpose.
  - Why now: SigNoz is moving the age check out of the exporters and into
    this processor (merged upstream, not yet released). Without the filter,
    that change would start storing arbitrarily old data.
- **`scripts/validate.sh`'s pipeline check** now covers all three pipelines. It
  checks that `memory_limiter` is first, `batch` is last, `filter/drop_stale` is
  just before `batch`, and the normalizer is right after `memory_limiter`. It
  still checks that the mapper runs before the pricer. It was tested against
  three deliberate misorderings, and fails each.
- **This config now needs collector v0.144.15 or later.** Before v0.144.13 the
  normalizer does not exist and the collector will not start. v0.144.13 and
  v0.144.14 accept it, but lack v0.144.15's JSON sanitizing.
  `docs/upgrading.md` and both `.env.example` files say so.
- **`docs/standalone.md` documents the processors.** It already had a table of
  the exporters; it now has one for the processors too, in pipeline order,
  with what each is for.

### GenAI / LLM observability

The ingestion side already had what SigNoz's LLM views need. What was missing
was proof that it works, and guidance for the application side, which is where
it usually goes wrong.

- **What SigNoz needs (as of v0.149.0)**:
  - It builds its LLM views from `gen_ai.*` **span attributes** only. GenAI
    metrics and log events are stored but not read.
  - It bridges vendor instrumentations with span-mapper groups, which it seeds
    when the organization is created and pushes to `signozspanmapper` over
    OpAMP.
  - It computes cost in `signozllmpricing`, from pricing rules.
  - Both processors were already in both stacks' traces pipelines.
- **New: `scripts/smoke-test.sh` checks the GenAI path end to end.**
  - **What it sends:** an LLM span in OpenInference's keys (`llm.model_name`,
    `llm.provider`, `llm.token_count.*`).
  - **Mapper check:** it asserts the span is stored with `gen_ai.request.model`
    and `gen_ai.provider.name`, and with every token count the views and the
    pricer read: input, output, cache-read, cache-write and reasoning. Each is
    its own pass/fail line, and a missing field is reported as `<absent>`.
    That proves the mapper groups were seeded, pushed and applied.
  - **Pricer check:** the span also carries a fake
    `signoz.gen_ai.usage.tokens.cost`. The pricer always strips that prefix, so
    its absence proves the pricer is in the pipeline without needing any
    pricing rule.
  - **Retries:** the span is re-sent each round, because the push carrying
    the groups can trail the one that took the collector out of no-op mode.
  - **On failure** it says whether the spans arrived unmapped or not at all.
    It also prints the LLM attributes of the newest stored span, and the mapper
    and pricer lines of the collector's effective config.
- **New: an "LLM and agent applications" section in `docs/agents.md`.** It
  covers the instrumentations the mapper handles and the content-capture
  setting most often got wrong:
  - **OpenTelemetry's GenAI instrumentations.** The legacy
    `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true` writes prompts
    as log events, which the LLM views never read. Prompts reach spans only
    with `OTEL_SEMCONV_STABILITY_OPT_IN=gen_ai_latest_experimental` plus
    `span_only` (checked against `opentelemetry-util-genai` and
    `opentelemetry-instrumentation-openai-v2`).
  - **OpenLLMetry** captures content by default.
  - **Cost:** a self-hosted SigNoz ships no price list, so costs stay empty
    until pricing rules are added. The section also covers what is priced:
    input, output, cache-read and cache-write tokens, with cache counts
    treated as part of input. Reasoning tokens are priced as output, and token
    counts sent as strings are priced as zero.
  - **Limits:** the OTLP size limits for prompt-heavy traffic.
- **Collector config comment:** the pricer's comment now says that costs need
  pricing rules.

### CI

- **The smoke test never showed a ClickHouse error.** Its query helper stored
  the server's message in a variable, but every caller runs it inside `$( )`,
  a subshell, so the variable was gone before anyone read it. Every
  "clickhouse error:" line the script has ever printed was empty, which turns
  a failing query into an unexplained "no rows". The helper now writes the
  message to a file, read back with `ch_err`. Tested with a stand-in `docker`
  that exits with a ClickHouse error: the old helper reported nothing, the new
  one reports the message.
- **The `foundryctl` download now retries, and is verified.** A transient 503
  from GitHub's release host failed run 38's `validate` job. The step made a
  single request, and piped the download into `tar`, which a retry would have
  corrupted. It now retries up to five times into a file, then checks it
  against a sha256 pinned in the workflow before extracting. The digest was
  cross-checked against the release's `checksums.txt`. It is pinned rather than
  read from that file, because a checksum file from the same release cannot
  catch a release that changes under its tag.

## 2026-09-30 — Foundry migration runbook; backups now include alert history

- **`scripts/backup.sh` never backed up `signoz_analytics`.** That database
  holds `rule_state_history_v0`, the alert state history (firing and resolved
  transitions over time). Every backup taken from this repo so far restores
  alert rules (they live in the metastore) but loses their history. The
  database list now includes it, and `restore.sh` needs no change: it restores
  whatever archives the backup holds. Take a fresh backup if alert history
  matters to you.
- **New: [`docs/foundry.md`](docs/foundry.md)**, a runbook for moving the
  standalone stack onto SigNoz Foundry. It covers when to move and what
  Foundry's compose output does not do that this repo does (ClickHouse auth,
  `memory_limiter`, resource limits, the Keeper four-letter-word allow-list,
  the security overlays, an HA load balancer). The migration is a
  `backup.sh` backup restored into a fresh Foundry stack, with `make up` as
  the rollback.
- **Why not reattach volumes, as `docs/upgrading.md` used to suggest.** Foundry
  generates different ClickHouse macros (`00`/`00` against `01`/`replica-01`),
  a different Keeper server id and Raft hostname, and different volume names.
  Replicated tables resolve their Keeper path through the macros, so
  reattached data comes up read-only. `docs/upgrading.md` now points to the
  runbook instead.
- **New: [`deploy/foundry/casting.yaml`](deploy/foundry/casting.yaml)**, the
  migration target. It pins the same images as the standalone
  `.env.example`, uses a SQLite metastore (Foundry defaults to Postgres, and
  there is no conversion path), adds the `backups` disk `RESTORE` needs, binds
  ports to `127.0.0.1`, and renames the compose project to `signoz-foundry`
  (Foundry's default, `signoz`, is also this repo's).
- **`scripts/validate.sh` checks the casting.** It fails if the casting's pins
  drift from `deploy/standalone/.env.example`. When `foundryctl` is installed,
  it forges the casting and runs `docker compose config` on the result. CI
  installs `foundryctl` v0.3.0 for this.

The runbook's commands were checked against `foundryctl` v0.3.0 output, but a
full migration has not been run end to end: nothing in CI starts a Foundry
stack and restores into it.

## 2026-09-30 — SigNoz v0.144.0

Version bumps, one required collector config change, and one upgrade that logs
every user out.

### Before you upgrade

- **Every user is logged out once, and that closes a security hole.** v0.143.0
  switched the default session tokenizer from `jwt` to `opaque` (server-side,
  revocable tokens stored in the metastore); upstream marks this as breaking,
  because JWT sessions are not valid opaque tokens. This repo never set a
  tokenizer or `SIGNOZ_TOKENIZER_JWT_SECRET`, and before v0.143.0 the default
  secret was empty. **Every earlier deployment from this repo therefore signed
  its sessions with an empty HMAC key**, and SigNoz logged "CRITICAL SECURITY
  ISSUE: No JWT secret key specified!" on every start. Upstream says such
  sessions are "vulnerable to tampering and unauthorized access". Taking the
  opaque default ends that: only the configured tokenizer is active, so JWTs
  are no longer accepted. There is no way to keep the old sessions — `jwt` now
  refuses to start without a non-empty secret, which invalidates them all the
  same. If you are staying on an older release for now, set
  `SIGNOZ_TOKENIZER_JWT_SECRET` (e.g. `openssl rand -hex 32`) on every backend.
- **Take a backup: several metastore migrations cannot be reversed.** The range
  adds migrations 118–130, applied on startup. Most add authorization tuples.
  121 renames `notification_channel.name` to `display_name` and adds a
  generated, unique `name`. 122 and 126 rewrite quick-filter JSON, and 128
  overwrites the built-in roles' transaction groups. None of them has a working
  `down`, and a pre-v0.141 binary would read the generated slug as the channel
  name. As always, `make backup` is the rollback.

### Versions

- **`signoz/signoz` `v0.139.0` → `v0.144.0`.** Seven releases (v0.140.0,
  v0.141.0, v0.141.1, v0.142.0, v0.142.1, v0.143.0, v0.144.0). Every
  configuration key the compose files set (`SIGNOZ_TELEMETRYSTORE_*`,
  `SIGNOZ_SQLSTORE_*`) still resolves, and the image, entrypoint, ports, OpAMP
  endpoint, `/api/v1/health` and the `/api/v1/register` call in
  `scripts/bootstrap.sh` are unchanged.
- **`signoz/signoz-otel-collector` `v0.144.9` → `v0.144.12`.** Adds sync traces
  migrations 1015–1017: an `attributes_promoted` JSON column, a token-bloom
  index on it, and 26 `gen_ai.*` columns per table (model, provider, token
  counts, costs) with `DEFAULT` expressions and three indexes. All three are
  metadata-only `ADD COLUMN` / `ADD INDEX`: existing parts are not rewritten,
  and `migrate async up` has nothing new. From v0.144.10 the traces exporter
  also writes every span's attributes to the JSON `attributes` column, and the
  upstream PR for 1017 reports 10–15% more insert CPU and 15% more insert
  memory. Watch ClickHouse and collector headroom after the upgrade. Image,
  user (10001), CLI flags and `migrate` subcommands are unchanged, and `bash`
  is still present for the health check.
- **ClickHouse stays at `25.12.5`.** Foundry's first compatibility rule is
  unchanged — collector `> 0.144.5` requires clickhouse `= 25.12.5` — and both
  Foundry and SigNoz's own dev environment still pin `25.12.5`. The PR that
  added the JSON `attributes` write (signoz-otel-collector#850) says it "needs
  clickhouse > v25.12.5"; SigNoz's own pins read that as `>=`. CI's
  end-to-end job ingests a trace against 25.12.5, which exercises that write.
  Newer 25.12.x patch tags (25.12.11) and 26.x exist; both fall outside the
  equality.
- **`actions/checkout` `v4` → `v7`** in CI. v5 moved to the Node 24 runtime, v6
  stores persisted credentials in a separate file, and v7 refuses to check out
  fork PRs under `pull_request_target` / `workflow_run`. This workflow uses
  none of those triggers, so none of it changes behaviour here.
- **Unchanged on purpose:** `postgres` stays on `16-alpine`, which already
  resolves to the newest 16.x (16.15). Going to 17 or 18 is a major-version
  data-directory upgrade (`pg_upgrade` or dump/restore), and Foundry still uses
  16. `nginx` stays on `1.30-alpine`, the current stable branch (1.30.5). The
  histogram-quantile UDF stays at `v0.0.1`, its only release.

### Collector config: two new traces processors

SigNoz has shipped `signozspanmapper` (maps vendor-specific span attributes onto
`gen_ai.*`) and `signozllmpricing` (per-span token cost) for a while, behind an
`enable_ai_observability` flag that was off by default. v0.143.0 removed the
flag, so every OpAMP push now includes both processor definitions: the mapper
with three built-in groups (`gen_ai.llm`, `gen_ai.agent`, `gen_ai.tool`), the
pricer with any rules set in the UI.

The backend only writes `processors.<name>`. It never edits
`service.pipelines`, so without entries in the base config the processors are
configured and never run. Both `collector/config.yaml` files now define them
the way Foundry's generated config does (`config.v01446`) and run them after
`signozspanmetrics/delta` and before `batch`, mapper first because the pricer
reads what the mapper writes. The base definitions are valid on their own (no
mapper groups, no pricing rules), so the config still loads before the first
OpAMP push.

Even with no rules, the pricer strips any `signoz.gen_ai.*` attributes clients
send: that prefix is reserved for costs the collector computes.

`scripts/validate.sh` gains a check that both stacks' traces pipelines keep
both processors, mapper before pricer, and still start with `memory_limiter`
and end with `batch`.

Foundry's matrix (`internal/compat/installation/compat.go`) gained a second
row to match: signoz `>= 0.143.0` requires collector `>= 0.144.6`, advising
0.144.11. A collector older than that rejects the push outright — unknown
processor type — and, because the push is a single config, loses any log
pipeline changes in it too. Upgrade both images together. The README,
`docs/upgrading.md` and both `.env.example` files now document the rule.

### Other

- **The nginx comment and `docs/ha.md` said live tail needs WebSockets.** It
  streams over server-sent events, and v0.141.0 removed the last WebSocket
  route on the UI port. `proxy_buffering off` is what live tail actually
  depends on, and it was already set. Only the comments changed.
- **HA session caveat, now in `docs/ha.md`.** Opaque tokens are cached in each
  backend's memory and checked there before Postgres, so a sign-out or
  revocation through one backend does not reach the other until its cached
  copy is evicted or expires. The JWT sessions before this could not be
  revoked at all, so this is not a regression, but it is not full revocation
  either.
- **Removed API endpoints** in the range: v1 dashboards
  (`/api/v1/dashboards*`, `/api/v2/metrics/dashboards`), billing
  (`/api/v1/checkout`, `/billing`, `/portal`), query progress
  (`/api/v3/query_progress`, `/ws/query_progress`) and
  `/api/v3/licenses/active`. Nothing in this repo calls them; check your own
  scripts if you drive the SigNoz API.

## 2026-08-31 — SigNoz v0.139.0

Version bumps only; no topology, config or script changes.

- **`signoz/signoz` `v0.136.1` → `v0.139.0`.** Four releases (v0.137.0,
  v0.137.1, v0.138.0, v0.139.0). Nothing in the range touches `conf/` or the
  configuration keys this repo sets — `SIGNOZ_TELEMETRYSTORE_*`,
  `SIGNOZ_SQLSTORE_*` and `SIGNOZ_OTEL_COLLECTOR_*` all still resolve. The range
  adds metastore migrations 108–117 (dashboard and saved-view restructuring,
  auth-domain config, orphan user roles, Lambda dashboards), which the backend
  applies on startup. Forward-only, as always: take a backup first.
- **`signoz/signoz-otel-collector` `v0.144.8` → `v0.144.9`.** A single fix in
  `clickhouselogsexporter` — non-map log bodies are wrapped instead of failing
  the whole batch. No ClickHouse schema migrations, no collector config changes.
- **`nginx` (HA) `1.29-alpine` → `1.30-alpine`.** 1.29 was a mainline release
  and has been superseded twice over; 1.30 is the current stable branch, which
  is what the version policy asks for. `.github/workflows/validate.yml` pins the
  same tag for its `nginx -t` check and moves with it.
- **ClickHouse stays at `25.12.5`.** The compatibility rule in
  `SigNoz/foundry` (`internal/compat/installation/compat.go`) is unchanged —
  collector `> 0.144.5` still requires clickhouse `= 25.12.5` — and Foundry's
  own defaults still pin `clickhouse/clickhouse-server:25.12.5` and
  `clickhouse/clickhouse-keeper:25.12.5`. Newer ClickHouse tags exist; they are
  still outside what SigNoz tests.

Removed endpoints in the v0.139.0 range (deprecated user, service-account
nested-role and v1 infra-monitoring endpoints) are API surface, not deployment
surface — nothing in this repo calls them. If you script against the SigNoz
API, check those before upgrading.

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
