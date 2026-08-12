#!/usr/bin/env bash
#
# Generate a private CA plus server and client certificates for OTLP TLS/mTLS.
#
#   scripts/gen-certs.sh <stack> [--host NAME]... [--client NAME] [--days N]
#
#   stack          standalone | ha
#   --host NAME    extra DNS name or IP for the server certificate SAN list
#                  (repeatable; localhost, 127.0.0.1 and ::1 are always included)
#   --client NAME  also issue a client certificate with this CN, for mTLS
#   --days N       validity in days (default 825 — the max most TLS clients accept)
#
# Examples
#   scripts/gen-certs.sh standalone
#   scripts/gen-certs.sh ha --host otel.example.com --host 10.0.1.20
#   scripts/gen-certs.sh standalone --client payments-api
#
# Certificates land in deploy/<stack>/certs/, which is git-ignored.
#
# These are self-signed: every client has to be told to trust ca.crt. For
# anything public-facing, use a real CA (Let's Encrypt, your internal PKI)
# instead and just drop the files in with the same names.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() { sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

[ $# -ge 1 ] || usage 1
case "$1" in -h|--help) usage 0 ;; esac

STACK="$1"; shift
CERT_DIR="${REPO_ROOT}/deploy/${STACK}/certs"
[ -d "${REPO_ROOT}/deploy/${STACK}" ] || { echo "error: no such stack '${STACK}'" >&2; exit 1; }

DAYS=825
CLIENT_CN=""
EXTRA_HOSTS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --host)   EXTRA_HOSTS+=("$2"); shift 2 ;;
        --client) CLIENT_CN="$2";      shift 2 ;;
        --days)   DAYS="$2";           shift 2 ;;
        *) echo "error: unexpected argument '$1'" >&2; usage 1 ;;
    esac
done

mkdir -p "$CERT_DIR"
cd "$CERT_DIR"
umask 077

# ── Subject Alternative Names ────────────────────────────────────────────────
# A certificate with only a CN and no SAN is rejected outright by Go's TLS
# stack — which is what every OTel SDK and the collector itself use. The
# openssl recipe in older SigNoz guides omitted SANs and produced certificates
# that simply cannot be used.
san="DNS:localhost,IP:127.0.0.1,IP:::1"
case "$STACK" in
    standalone) san="${san},DNS:otel-collector,DNS:signoz,DNS:clickhouse" ;;
    ha)         san="${san},DNS:loadbalancer,DNS:otel-collector-1,DNS:otel-collector-2,DNS:signoz-1,DNS:signoz-2" ;;
esac
for host in ${EXTRA_HOSTS+"${EXTRA_HOSTS[@]}"}; do
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$host" == *:* ]]; then
        san="${san},IP:${host}"
    else
        san="${san},DNS:${host}"
    fi
done

# ── CA ───────────────────────────────────────────────────────────────────────
if [ -f ca.key ] && [ -f ca.crt ]; then
    echo "reusing existing CA (delete ca.key/ca.crt to start over)"
else
    echo "generating CA"
    openssl req -x509 -newkey rsa:4096 -sha256 -nodes \
        -keyout ca.key -out ca.crt -days $((DAYS * 2)) \
        -subj "/CN=SigNoz Internal CA/O=SigNoz Self-Hosted" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
fi

# ── Server certificate ───────────────────────────────────────────────────────
echo "generating server certificate"
echo "  SAN: ${san}"
openssl req -newkey rsa:4096 -sha256 -nodes \
    -keyout server.key -out server.csr \
    -subj "/CN=signoz-collector/O=SigNoz Self-Hosted" 2>/dev/null

openssl x509 -req -in server.csr -sha256 -days "$DAYS" \
    -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt \
    -extfile <(printf 'subjectAltName=%s\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$san") 2>/dev/null
rm -f server.csr

# ── Client certificate (mTLS) ────────────────────────────────────────────────
if [ -n "$CLIENT_CN" ]; then
    echo "generating client certificate for '${CLIENT_CN}'"
    openssl req -newkey rsa:4096 -sha256 -nodes \
        -keyout "client-${CLIENT_CN}.key" -out "client-${CLIENT_CN}.csr" \
        -subj "/CN=${CLIENT_CN}/O=SigNoz Self-Hosted" 2>/dev/null

    openssl x509 -req -in "client-${CLIENT_CN}.csr" -sha256 -days "$DAYS" \
        -CA ca.crt -CAkey ca.key -CAcreateserial -out "client-${CLIENT_CN}.crt" \
        -extfile <(printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\n') 2>/dev/null
    rm -f "client-${CLIENT_CN}.csr"
fi

chmod 600 ./*.key
chmod 644 ./*.crt

echo
echo "wrote to deploy/${STACK}/certs/:"
ls -1 .
echo
echo "verify:  openssl verify -CAfile ca.crt server.crt"
echo "inspect: openssl x509 -in server.crt -noout -text | grep -A1 'Subject Alternative Name'"
