#!/usr/bin/env bash
#
# Back up a running stack: configuration, the SigNoz metastore, and ClickHouse.
#
#   scripts/backup.sh [stack] [--output DIR]
#
#   stack   standalone (default) | ha
#
# Produces backups/<stack>-<timestamp>/ containing:
#   config.tar.gz    compose files, XML/YAML configs, .env  (SECRETS INSIDE)
#   metastore.*      signoz.db (standalone) or a pg_dump (ha)
#   clickhouse/      one native ClickHouse BACKUP per SigNoz database
#   MANIFEST.txt     image digests and the ClickHouse backup names
#
# ClickHouse is backed up online with BACKUP ... TO Disk(), so the stack keeps
# running. That needs a backup disk configured — the script adds one on the
# fly if it is missing and tells you how to make it permanent.
#
# The config archive contains .env and therefore your ClickHouse and Postgres
# passwords. Encrypt it before it leaves the host:
#   gpg --symmetric --cipher-algo AES256 config.tar.gz
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

STACK="standalone"
OUTPUT_ROOT="${REPO_ROOT}/backups"

while [ $# -gt 0 ]; do
    case "$1" in
        standalone|ha) STACK="$1"; shift ;;
        --output)      OUTPUT_ROOT="$2"; shift 2 ;;
        -h|--help)     sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unexpected argument '$1'" >&2; exit 1 ;;
    esac
done

STACK_DIR="deploy/${STACK}"
[ -d "$STACK_DIR" ] || { echo "error: no such stack '${STACK}'" >&2; exit 1; }

case "$STACK" in
    standalone) CH_CONTAINERS=(signoz-clickhouse); SIGNOZ_CONTAINER=signoz ;;
    ha)         CH_CONTAINERS=(signoz-clickhouse-1); SIGNOZ_CONTAINER=signoz-1 ;;
esac

if [ ! -f "${STACK_DIR}/.env" ]; then
    echo "error: ${STACK_DIR}/.env not found — nothing is deployed from this stack yet" >&2
    exit 1
fi
set -a
# shellcheck source=/dev/null
. "${STACK_DIR}/.env"
set +a

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="${OUTPUT_ROOT}/${STACK}-${STAMP}"
mkdir -p "${DEST}/clickhouse"

echo "backing up '${STACK}' to ${DEST}"

# ── Configuration ────────────────────────────────────────────────────────────
echo "==> configuration"
tar -czf "${DEST}/config.tar.gz" -C "$REPO_ROOT" "$STACK_DIR"
echo "    config.tar.gz ($(du -h "${DEST}/config.tar.gz" | cut -f1)) — contains .env, encrypt before moving off-host"

# ── Metastore ────────────────────────────────────────────────────────────────
# Dashboards, alert rules, users and saved views live here, not in ClickHouse.
# A ClickHouse-only backup silently loses all of it.
echo "==> metastore"
if [ "$STACK" = "standalone" ]; then
    # SQLite cannot be copied safely from under a running writer: in WAL mode
    # the committed state is split between signoz.db and its -wal sidecar, so
    # copying the .db alone yields a torn snapshot that may not even open.
    # Stopping SigNoz checkpoints and closes the database first. Ingestion is
    # unaffected — the collector writes to ClickHouse, not here — so the only
    # cost is a few seconds without the UI.
    echo "    stopping SigNoz briefly for a consistent SQLite snapshot"
    docker compose -f "${STACK_DIR}/docker-compose.yaml" stop "$SIGNOZ_CONTAINER" >/dev/null
    docker cp "${SIGNOZ_CONTAINER}:/var/lib/signoz/signoz.db" "${DEST}/metastore-signoz.db"
    docker compose -f "${STACK_DIR}/docker-compose.yaml" start "$SIGNOZ_CONTAINER" >/dev/null
    echo "    metastore-signoz.db ($(du -h "${DEST}/metastore-signoz.db" | cut -f1))"
else
    docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" signoz-postgres \
        pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" --clean --if-exists \
        | gzip > "${DEST}/metastore-postgres.sql.gz"
    echo "    metastore-postgres.sql.gz ($(du -h "${DEST}/metastore-postgres.sql.gz" | cut -f1))"
fi

# ── ClickHouse ───────────────────────────────────────────────────────────────
echo "==> clickhouse"
CH="${CH_CONTAINERS[0]}"
ch_query() {
    docker exec "$CH" clickhouse-client \
        --user "${CLICKHOUSE_USER}" --password "${CLICKHOUSE_PASSWORD}" \
        --query "$1"
}

# BACKUP TO Disk() needs a disk in backups.allowed_disk. Add it at runtime if
# the operator has not made it permanent yet.
if ! ch_query "SELECT 1 FROM system.disks WHERE name = 'backups'" | grep -q 1; then
    echo "    no 'backups' disk configured — adding one for this run"
    docker exec "$CH" sh -c 'mkdir -p /var/lib/clickhouse/backups && cat > /etc/clickhouse-server/config.d/backups.xml <<XML
<clickhouse>
    <storage_configuration><disks><backups>
        <type>local</type>
        <path>/var/lib/clickhouse/backups/</path>
    </backups></disks></storage_configuration>
    <backups><allowed_disk>backups</allowed_disk></backups>
</clickhouse>
XML'
    ch_query "SYSTEM RELOAD CONFIG"
    echo "    (make it permanent by adding that file to ${STACK_DIR}/clickhouse/config.d/)"
fi

: > "${DEST}/MANIFEST.txt"
{
    echo "stack:     ${STACK}"
    echo "taken:     ${STAMP}"
    echo "host:      $(hostname)"
    echo
    echo "images:"
    docker compose -f "${STACK_DIR}/docker-compose.yaml" images --format json 2>/dev/null \
        | python3 -c 'import sys,json
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try: d=json.loads(line)
    except ValueError: continue
    rows = d if isinstance(d, list) else [d]
    for r in rows:
        print(f"  {r.get(\"Service\",\"?\"):<24} {r.get(\"Repository\",\"?\")}:{r.get(\"Tag\",\"?\")} {r.get(\"ID\",\"\")}")' 2>/dev/null || echo "  (unavailable)"
    echo
    echo "clickhouse backups:"
} >> "${DEST}/MANIFEST.txt"

for db in signoz_traces signoz_metrics signoz_logs signoz_metadata signoz_meter; do
    if ! ch_query "EXISTS DATABASE ${db}" | grep -q 1; then
        echo "    ${db}: absent, skipping"
        continue
    fi
    name="${db}-${STAMP}.zip"
    echo "    ${db} -> ${name}"
    ch_query "BACKUP DATABASE ${db} TO Disk('backups', '${name}')" >/dev/null
    docker cp "${CH}:/var/lib/clickhouse/backups/${name}" "${DEST}/clickhouse/${name}"
    # Reclaim the in-container copy; the host copy is the backup now.
    docker exec "$CH" rm -f "/var/lib/clickhouse/backups/${name}"
    echo "  ${name}" >> "${DEST}/MANIFEST.txt"
done

echo
echo "done: ${DEST}"
du -sh "${DEST}"
echo
echo "restore with:  scripts/restore.sh ${STACK} ${DEST}"
