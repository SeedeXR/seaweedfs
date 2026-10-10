#!/bin/sh
# Tests for start.sh. Runs anywhere with a POSIX sh:
#   sh docker/coolify/start_test.sh
#   docker run --rm -v "$PWD/docker/coolify:/t:ro" alpine:3.23 sh /t/start_test.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Stand-in for /entrypoint.sh: records its arguments and S3_BUCKET.
cat > "$tmp/next.sh" <<'EOF'
#!/bin/sh
echo "ARGS=$*"
echo "S3_BUCKET=${S3_BUCKET:-}"
env | grep '^WEED_GRPC_' | sort
EOF
chmod +x "$tmp/next.sh"

failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

# run <env assignments...> -- runs start.sh with a clean environment.
run() {
  rm -f "$tmp/ids.json"
  env -i PATH="$PATH" NEXT_ENTRYPOINT="$tmp/next.sh" IDENTITIES_FILE="$tmp/ids.json" \
    "$@" sh "$here/start.sh" mini -dir=/data > "$tmp/out" 2>&1
}

base="AWS_ACCESS_KEY_ID=adminkey AWS_SECRET_ACCESS_KEY=adminsecret WEED_ADMIN_PASSWORD=pw GRPC_MTLS=off"

# shellcheck disable=SC2086 # $base is a deliberate word list
{
  run $base || fail "minimal valid env exited non-zero: $(cat "$tmp/out")"
  grep -q '^ARGS=mini -dir=/data$' "$tmp/out" || fail "minimal env should pass args through unchanged: $(cat "$tmp/out")"
  [ ! -e "$tmp/ids.json" ] || fail "no identities file expected without app/public settings"

  for missing in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY WEED_ADMIN_PASSWORD; do
    env_without=$(echo "$base" | tr ' ' '\n' | grep -v "^$missing=" | tr '\n' ' ')
    if run $env_without; then fail "missing $missing must be fatal"; fi
    grep -q "FATAL: $missing" "$tmp/out" || fail "missing $missing must name it in the log: $(cat "$tmp/out")"
  done

  if run AWS_ACCESS_KEY_ID='bad"key' AWS_SECRET_ACCESS_KEY=s WEED_ADMIN_PASSWORD=pw; then
    fail "a quote in a key must be rejected (JSON injection)"
  fi

  run $base S3_APP_ACCESS_KEY=appkey S3_APP_SECRET_KEY=appsecret S3_APP_BUCKETS=njozi-media,njozi-models \
    S3_PUBLIC_READ_BUCKETS=njozi-media || fail "app + public env exited non-zero: $(cat "$tmp/out")"
  want='{"identities":[{"name":"app","credentials":[{"accessKey":"appkey","secretKey":"appsecret"}],"actions":["Read:njozi-media","Write:njozi-media","List:njozi-media","Read:njozi-models","Write:njozi-models","List:njozi-models"]},{"name":"anonymous","actions":["Read:njozi-media"]}]}'
  [ "$(cat "$tmp/ids.json" 2>/dev/null)" = "$want" ] || fail "identities file mismatch: $(cat "$tmp/ids.json" 2>/dev/null)"
  grep -q "^ARGS=mini -dir=/data -s3.config=$tmp/ids.json$" "$tmp/out" || fail "-s3.config not appended: $(cat "$tmp/out")"
  grep -q '^S3_BUCKET=njozi-media,njozi-models$' "$tmp/out" || fail "S3_BUCKET should default to S3_APP_BUCKETS"
  perms=$(ls -l "$tmp/ids.json" | cut -c1-10)
  [ "$perms" = "-rw-------" ] || fail "identities file must be 0600, got $perms"

  run $base S3_BUCKET=other S3_APP_ACCESS_KEY=appkey S3_APP_SECRET_KEY=appsecret S3_APP_BUCKETS=njozi-media
  grep -q '^S3_BUCKET=other$' "$tmp/out" || fail "explicit S3_BUCKET must win"

  if run $base S3_APP_ACCESS_KEY=appkey S3_APP_SECRET_KEY=appsecret S3_APP_BUCKETS='njozi-media,Bad_Bucket'; then
    fail "invalid bucket name must be fatal"
  fi
  grep -q "invalid bucket name 'Bad_Bucket'" "$tmp/out" || fail "invalid bucket must be named: $(cat "$tmp/out")"

  if run $base S3_PUBLIC_READ_BUCKETS='*'; then fail "glob as bucket name must be fatal"; fi

  if run $base S3_APP_ACCESS_KEY=appkey S3_APP_BUCKETS=njozi-media; then
    fail "app access key without secret must be fatal"
  fi

  if run $base S3_APP_ACCESS_KEY=appkey S3_APP_SECRET_KEY=appsecret; then
    fail "app identity without buckets must be fatal"
  fi

  if run $base S3_APP_ACCESS_KEY=adminkey S3_APP_SECRET_KEY=x S3_APP_BUCKETS=njozi-media; then
    fail "app key equal to admin key must be fatal"
  fi
}

# gRPC mTLS: needs openssl, as in the image.
if command -v openssl > /dev/null && openssl version | grep -q '^OpenSSL 3'; then
  mtls_env=$(echo "$base" | sed 's/GRPC_MTLS=off//')
  # shellcheck disable=SC2086
  run $mtls_env TMPDIR="$tmp" || fail "mTLS boot exited non-zero: $(cat "$tmp/out")"
  ca=$(sed -n 's/^WEED_GRPC_CA=//p' "$tmp/out")
  [ -s "$ca" ] || fail "WEED_GRPC_CA not exported or empty: $(cat "$tmp/out")"
  for c in MASTER VOLUME FILER S3 ADMIN WORKER CLIENT; do
    grep -q "^WEED_GRPC_${c}_CERT=" "$tmp/out" || fail "WEED_GRPC_${c}_CERT not exported"
    grep -q "^WEED_GRPC_${c}_KEY=" "$tmp/out" || fail "WEED_GRPC_${c}_KEY not exported"
  done
  dir=$(dirname "$ca")
  openssl verify -CAfile "$ca" -purpose sslserver "$dir/node.crt" > /dev/null 2>&1 || fail "node cert does not verify as a server cert"
  openssl verify -CAfile "$ca" -purpose sslclient "$dir/node.crt" > /dev/null 2>&1 || fail "node cert does not verify as a client cert"
  [ ! -e "$dir/ca.key" ] || fail "CA private key must be deleted after signing"
  perms=$(ls -l "$dir/node.key" | cut -c1-10)
  [ "$perms" = "-rw-------" ] || fail "node key must be 0600, got $perms"
else
  echo "skipping mTLS test: OpenSSL 3 not available"
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "start.sh: all tests passed"
