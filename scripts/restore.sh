#!/usr/bin/env bash
#
# Restore a stack from a scripts/backup.sh directory.
#
#   scripts/restore.sh <stack> <backup-dir> [--yes]
#
# This OVERWRITES the metastore and the SigNoz ClickHouse databases in the
# running stack. It asks before doing so unless --yes is passed.
#
# What it does NOT do: restore configuration. config.tar.gz is in the backup
# for reference, but unpacking it over a live deployment would swap .env and
# every config file underneath running containers. Unpack it by hand if that
# is what you want.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

usage() { sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

[ $# -ge 2 ] || usage 1
case "$1" in -h|--help) usage 0 ;; esac

STACK="$1"
BACKUP_DIR="$2"
ASSUME_YES=false
[ "${3:-}" = "--yes" ] && ASSUME_YES=true

STACK_DIR="deploy/${STACK}"
[ -d "$STACK_DIR" ]   || { echo "error: no such stack '${STACK}'" >&2; exit 1; }
[ -d "$BACKUP_DIR" ]  || { echo "error: no such backup directory '${BACKUP_DIR}'" >&2; exit 1; }

case "$STACK" in
    standalone) CH=signoz-clickhouse;   SIGNOZ_CONTAINER=signoz ;;
    ha)         CH=signoz-clickhouse-1; SIGNOZ_CONTAINER=signoz-1 ;;
    *) echo "error: unknown stack '${STACK}'" >&2; exit 1 ;;
esac

# shellcheck disable=SC1090
set -a; . "${STACK_DIR}/.env"; set +a

echo "restoring '${STACK}' from ${BACKUP_DIR}"
[ -f "${BACKUP_DIR}/MANIFEST.txt" ] && sed 's/^/  /' "${BACKUP_DIR}/MANIFEST.txt"

if [ "$ASSUME_YES" != true ]; then
    echo
    echo "This overwrites the metastore and the signoz_* ClickHouse databases."
    printf 'Type "restore" to continue: '
    read -r reply
    [ "$reply" = "restore" ] || { echo "aborted"; exit 1; }
fi

ch_query() {
    docker exec "$CH" clickhouse-client \
        --user "${CLICKHOUSE_USER}" --password "${CLICKHOUSE_PASSWORD}" \
        --query "$1"
}

# ── Metastore ────────────────────────────────────────────────────────────────
echo "==> metastore"
if [ "$STACK" = "standalone" ]; then
    src="${BACKUP_DIR}/metastore-signoz.db"
    if [ -f "$src" ]; then
        # SigNoz holds the SQLite file open, so stop it before swapping.
        docker compose -f "${STACK_DIR}/docker-compose.yaml" stop "$SIGNOZ_CONTAINER" >/dev/null
        docker cp "$src" "${SIGNOZ_CONTAINER}:/var/lib/signoz/signoz.db"
        docker compose -f "${STACK_DIR}/docker-compose.yaml" start "$SIGNOZ_CONTAINER" >/dev/null
        echo "    signoz.db restored"
    else
        echo "    no metastore-signoz.db in backup, skipping"
    fi
else
    src="${BACKUP_DIR}/metastore-postgres.sql.gz"
    if [ -f "$src" ]; then
        # The dump was taken with --clean --if-exists, so it drops and
        # recreates each object as it goes.
        gunzip -c "$src" | docker exec -i -e PGPASSWORD="${POSTGRES_PASSWORD}" signoz-postgres \
            psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null
        docker compose -f "${STACK_DIR}/docker-compose.yaml" restart signoz-1 signoz-2 >/dev/null
        echo "    postgres restored, backends restarted"
    else
        echo "    no metastore-postgres.sql.gz in backup, skipping"
    fi
fi

# ── ClickHouse ───────────────────────────────────────────────────────────────
echo "==> clickhouse"
shopt -s nullglob
archives=("${BACKUP_DIR}"/clickhouse/*.zip)
if [ ${#archives[@]} -eq 0 ]; then
    echo "    no ClickHouse archives in backup, skipping"
else
    docker exec "$CH" mkdir -p /var/lib/clickhouse/backups
    for path in "${archives[@]}"; do
        name="$(basename "$path")"
        db="${name%%-*}"
        echo "    ${name} -> ${db}"
        docker cp "$path" "${CH}:/var/lib/clickhouse/backups/${name}"
        # RESTORE will not write into an existing database.
        ch_query "DROP DATABASE IF EXISTS ${db} SYNC" >/dev/null
        ch_query "RESTORE DATABASE ${db} FROM Disk('backups', '${name}')" >/dev/null
        docker exec "$CH" rm -f "/var/lib/clickhouse/backups/${name}"
    done
fi

echo
echo "restore complete."
echo "verify with:  scripts/smoke-test.sh ${STACK}"
