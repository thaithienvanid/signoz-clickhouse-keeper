#!/usr/bin/env bash
#
# Create or update the htpasswd file used by the basic-auth fragment.
#
#   scripts/gen-htpasswd.sh <stack> <username> [password]
#
# With no password argument one is generated and printed once — that is the
# only time you will see it.
#
# Examples
#   scripts/gen-htpasswd.sh standalone ingest
#   scripts/gen-htpasswd.sh ha ingest 'my-own-password'
#
# Appends to deploy/<stack>/secrets/.htpasswd, replacing any existing line for
# the same user, so this doubles as the way to rotate a password.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() { sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

[ $# -ge 2 ] || usage 1
case "$1" in -h|--help) usage 0 ;; esac

STACK="$1"
USERNAME="$2"
PASSWORD="${3:-}"
GENERATED=false

STACK_DIR="${REPO_ROOT}/deploy/${STACK}"
[ -d "$STACK_DIR" ] || { echo "error: no such stack '${STACK}'" >&2; exit 1; }

SECRET_DIR="${STACK_DIR}/secrets"
HTPASSWD="${SECRET_DIR}/.htpasswd"

if [ -z "$PASSWORD" ]; then
    PASSWORD="$(openssl rand -base64 24)"
    GENERATED=true
fi

# bcrypt via httpd's htpasswd. Using the container keeps this working on hosts
# that have no apache2-utils installed.
HASH="$(docker run --rm httpd:2.4-alpine htpasswd -nbB "$USERNAME" "$PASSWORD" | tr -d '\r\n')"

mkdir -p "$SECRET_DIR"
touch "$HTPASSWD"
chmod 600 "$HTPASSWD"

# Drop any existing entry for this user, then append the new one.
if grep -q "^${USERNAME}:" "$HTPASSWD" 2>/dev/null; then
    grep -v "^${USERNAME}:" "$HTPASSWD" > "${HTPASSWD}.tmp" || true
    mv "${HTPASSWD}.tmp" "$HTPASSWD"
    chmod 600 "$HTPASSWD"
    echo "rotating credentials for existing user '${USERNAME}'"
fi
printf '%s\n' "$HASH" >> "$HTPASSWD"

echo "updated deploy/${STACK}/secrets/.htpasswd"
if [ "$GENERATED" = true ]; then
    echo
    echo "  username: ${USERNAME}"
    echo "  password: ${PASSWORD}"
    echo
    echo "Store it now — it is not recoverable from the bcrypt hash."
fi
echo
echo "next:"
echo "  scripts/apply-security.sh ${STACK} basic-auth"
echo "  cd deploy/${STACK} && docker compose -f docker-compose.yaml -f compose.security.yaml up -d"
