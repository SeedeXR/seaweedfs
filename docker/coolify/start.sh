#!/bin/sh
# Entrypoint for the Coolify image. Validates the environment, renders the S3
# identities file, then hands off to the stock /entrypoint.sh. Every problem is
# fatal and logged with the variable to fix: a misconfigured deploy must fail
# its healthcheck loudly, never come up serving S3 anonymously.
#
# Environment (see docker/coolify/README.md):
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY  admin S3 identity       (required)
#   WEED_ADMIN_PASSWORD                         admin UI password       (required)
#   S3_APP_ACCESS_KEY / S3_APP_SECRET_KEY       scoped app identity     (optional, both or neither)
#   S3_APP_BUCKETS                              buckets the app identity may read, write, list
#   S3_PUBLIC_READ_BUCKETS                      buckets anyone may GET (never List)
set -eu
set -f # bucket lists are split on commas below; never glob them

IDENTITIES_FILE=${IDENTITIES_FILE:-/tmp/s3-identities.json}
NEXT_ENTRYPOINT=${NEXT_ENTRYPOINT:-/entrypoint.sh}

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) coolify-start: $*" >&2; }
die() { log "FATAL: $*"; exit 1; }

value_of() { eval "printf '%s' \"\${$1:-}\""; }

require() {
  [ -n "$(value_of "$1")" ] || die "$1 is empty; set it under Environment Variables in Coolify"
}

# Keys end up inside JSON, so only characters that need no escaping pass.
require_key() {
  case "$(value_of "$1")" in
    '' | *[!A-Za-z0-9+/=._-]*) die "$1 must be non-empty and use only A-Z a-z 0-9 + / = . _ -" ;;
  esac
}

# Checks every name in the comma-separated bucket list $1 against the S3
# naming rules. Runs in the current shell so die really exits.
require_buckets() {
  require "$1"
  old_ifs=$IFS
  IFS=,
  for b in $(value_of "$1"); do
    printf '%s' "$b" | grep -Eq '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$' ||
      die "$1 contains invalid bucket name '$b'"
  done
  IFS=$old_ifs
}

# JSON array of "<verb>:<bucket>" for each bucket in $1 and each verb after it.
actions_json() {
  var=$1
  shift
  out=""
  old_ifs=$IFS
  IFS=,
  for b in $(value_of "$var"); do
    IFS=$old_ifs
    for verb in "$@"; do
      out="$out${out:+,}\"$verb:$b\""
    done
    IFS=,
  done
  IFS=$old_ifs
  printf '[%s]' "$out"
}

require_key AWS_ACCESS_KEY_ID
require_key AWS_SECRET_ACCESS_KEY
require WEED_ADMIN_PASSWORD

identities=""
if [ -n "${S3_APP_ACCESS_KEY:-}${S3_APP_SECRET_KEY:-}" ]; then
  require_key S3_APP_ACCESS_KEY
  require_key S3_APP_SECRET_KEY
  require_buckets S3_APP_BUCKETS
  [ "$S3_APP_ACCESS_KEY" != "$AWS_ACCESS_KEY_ID" ] || die "S3_APP_ACCESS_KEY must differ from AWS_ACCESS_KEY_ID"
  # Object read/write/delete and listing on its buckets only: no bucket
  # create/delete, policy or ACL rights, which need Admin.
  identities="{\"name\":\"app\",\"credentials\":[{\"accessKey\":\"$S3_APP_ACCESS_KEY\",\"secretKey\":\"$S3_APP_SECRET_KEY\"}],\"actions\":$(actions_json S3_APP_BUCKETS Read Write List)}"
  log "app identity scoped to buckets: $S3_APP_BUCKETS"
fi
if [ -n "${S3_PUBLIC_READ_BUCKETS:-}" ]; then
  require_buckets S3_PUBLIC_READ_BUCKETS
  # Read without List: objects are fetchable by exact key, buckets cannot be enumerated.
  identities="$identities${identities:+,}{\"name\":\"anonymous\",\"actions\":$(actions_json S3_PUBLIC_READ_BUCKETS Read)}"
  log "anonymous GetObject enabled on: $S3_PUBLIC_READ_BUCKETS"
fi

if [ -n "$identities" ]; then
  umask 077
  printf '{"identities":[%s]}\n' "$identities" > "$IDENTITIES_FILE" || die "cannot write $IDENTITIES_FILE"
  set -- "$@" "-s3.config=$IDENTITIES_FILE"
fi

# gRPC between master, volume, filer, S3 and admin is unauthenticated unless
# mutual TLS is configured, and those ports listen on every interface. All of
# them live in this one process, so a CA minted per boot is enough: every
# component trusts it, and nothing outside the container holds a certificate.
# Set GRPC_MTLS=off only for an external `weed shell` or worker, which would
# need these certificates.
if [ "${GRPC_MTLS:-on}" != "off" ]; then
  tls_dir=$(mktemp -d "${TMPDIR:-/tmp}/grpc-tls.XXXXXX") || die "cannot create gRPC TLS directory"
  (
    umask 077
    cd "$tls_dir"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
      -subj "/CN=seaweedfs-grpc-ca" -keyout ca.key -out ca.crt 2>/dev/null &&
      openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
        -subj "/CN=seaweedfs-grpc" -keyout node.key -out node.csr 2>/dev/null &&
      printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth,clientAuth\n' > ext.cnf &&
      openssl x509 -req -in node.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 3650 \
        -extfile ext.cnf -out node.crt 2>/dev/null &&
      rm -f ca.key node.csr ext.cnf ca.srl
  ) || die "generating gRPC mTLS certificates failed (is openssl installed?)"
  export WEED_GRPC_CA="$tls_dir/ca.crt"
  for component in MASTER VOLUME FILER S3 ADMIN WORKER CLIENT; do
    export "WEED_GRPC_${component}_CERT=$tls_dir/node.crt"
    export "WEED_GRPC_${component}_KEY=$tls_dir/node.key"
  done
  log "gRPC mutual TLS enabled with a per-boot CA"
else
  log "WARNING: GRPC_MTLS=off; internal gRPC ports accept unauthenticated clients"
fi

# Create the app's buckets on first start unless the operator listed them.
if [ -z "${S3_BUCKET:-}" ] && [ -n "${S3_APP_BUCKETS:-}" ]; then
  export S3_BUCKET="$S3_APP_BUCKETS"
fi

log "starting: $*"
exec "$NEXT_ENTRYPOINT" "$@"
