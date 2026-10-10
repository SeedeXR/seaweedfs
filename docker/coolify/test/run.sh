#!/bin/sh
# End-to-end test of the Coolify deployment:
#   1. start.sh unit tests (busybox sh, as in the image)
#   2. build the image
#   3. boot it behind Traefik with fresh random secrets
#   4. integration tests (test_integration.py)
#   5. backup -> restore into a fresh volume -> boot a second stack on it ->
#      every object reads back byte-identical with the same credentials
#
# Usage: docker/coolify/test/run.sh
#   LARGE_MB=520   size of the large-upload test (0 skips it; default 520)
#   KEEP=1         leave the stacks running afterwards
#   SKIP_BUILD=1   reuse the last built image
# Needs docker, python3 with boto3.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
coolify=$(dirname "$here")
repo=$(cd "$coolify/../.." && pwd)
project=${PROJECT:-swtest}
restored=${project}restored
image=seedexr-seaweedfs-test:latest
work=$(mktemp -d)

log() { echo "$(date -u +%H:%M:%S) run: $*" >&2; }
die() { log "FAIL: $*"; exit 1; }

# retry <attempts> <command...>: exponential backoff, for registry hiccups.
retry() {
  attempts=$1
  shift
  n=1
  delay=5
  until "$@"; do
    [ "$n" -ge "$attempts" ] && return 1
    log "attempt $n/$attempts failed: $*; retrying in ${delay}s"
    sleep "$delay"
    n=$((n + 1))
    delay=$((delay * 2))
  done
}

compose() {
  p=$1
  shift
  docker compose -p "$p" --env-file "$work/test.env" \
    -f "$coolify/docker-compose.yml" -f "$here/compose.test.yml" "$@"
}

cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    for p in "$project" "$restored"; do
      if docker ps -a --format '{{.Names}}' | grep -q "^$p-seaweedfs-1$"; then
        log "last 80 log lines of $p-seaweedfs-1:"
        docker logs --tail 80 "$p-seaweedfs-1" 2>&1 | sed 's/^/    /' >&2
      fi
    done
  fi
  if [ "${KEEP:-0}" != "1" ]; then
    compose "$project" down -v --remove-orphans > /dev/null 2>&1 || true
    compose "$restored" down -v --remove-orphans > /dev/null 2>&1 || true
    docker volume rm "${restored}_seaweedfs-data" > /dev/null 2>&1 || true
  fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT INT TERM

wait_healthy() {
  container=$1
  i=0
  while [ "$i" -lt 60 ]; do
    state=$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || echo missing)
    [ "$state" = healthy ] && return 0
    [ "$state" = unhealthy ] && return 1
    sleep 3
    i=$((i + 1))
  done
  return 1
}

rnd() { LC_ALL=C tr -dc "$1" < /dev/urandom | head -c "$2"; }

log "1/5 start.sh unit tests"
retry 3 docker run --rm -v "$coolify:/t:ro" alpine:3.23 \
  sh -c 'apk add -q --no-cache "openssl~3.5" > /dev/null && sh /t/start_test.sh' >&2 || die "start.sh tests"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  log "2/5 building image"
  retry 3 docker build -q -f "$repo/docker/Dockerfile.coolify" -t "$image" "$repo" > /dev/null || die "image build"
fi

cat > "$work/test.env" <<EOF
SERVICE_USER_S3=$(rnd A-Za-z0-9 16)
SERVICE_PASSWORD_64_S3=$(rnd A-Za-z0-9 64)
SERVICE_PASSWORD_ADMIN=$(rnd A-Za-z0-9 32)
SERVICE_USER_S3APP=$(rnd A-Za-z0-9 16)
SERVICE_PASSWORD_64_S3APP=$(rnd A-Za-z0-9 64)
SERVICE_HEX_64_JWTWRITE=$(rnd a-f0-9 64)
SERVICE_HEX_64_JWTREAD=$(rnd a-f0-9 64)
SERVICE_HEX_64_FILERWRITE=$(rnd a-f0-9 64)
SERVICE_HEX_64_FILERREAD=$(rnd a-f0-9 64)
SERVICE_URL_SEAWEEDFS_8333=https://127.0.0.1:18443
S3_APP_BUCKETS=njozi-media,njozi-models
S3_PUBLIC_READ_BUCKETS=njozi-media
EOF
# shellcheck disable=SC1091
. "$work/test.env"

log "3/5 starting stack behind Traefik"
# Both projects bind the same test ports; a stack left by KEEP=1 would
# otherwise answer in place of the new one.
compose "$project" down -v --remove-orphans > /dev/null 2>&1 || true
compose "$restored" down -v --remove-orphans > /dev/null 2>&1 || true
retry 3 compose "$project" up -d --no-build > /dev/null 2>&1 || die "compose up"
wait_healthy "$project-seaweedfs-1" || die "stack never became healthy"

export S3_URL=https://127.0.0.1:18443 ADMIN_URL=https://127.0.0.1:19443
export ADMIN_KEY="$SERVICE_USER_S3" ADMIN_SECRET="$SERVICE_PASSWORD_64_S3"
export APP_KEY="$SERVICE_USER_S3APP" APP_SECRET="$SERVICE_PASSWORD_64_S3APP"
export ADMIN_USER=admin ADMIN_PASSWORD="$SERVICE_PASSWORD_ADMIN"
export DOCKER_NETWORK="${project}_default" LARGE_MB="${LARGE_MB:-520}"

log "4/5 integration tests (LARGE_MB=$LARGE_MB)"
python3 -W ignore "$here/test_integration.py" || die "integration tests"

log "5/5 backup -> restore -> verify on a second stack"
python3 -W ignore - "$work/objects.json" <<'EOF' || die "seeding objects"
import hashlib, json, os, sys, boto3
from botocore.config import Config
s3 = boto3.client("s3", endpoint_url=os.environ["S3_URL"], verify=False, region_name="us-east-1",
                  aws_access_key_id=os.environ["APP_KEY"], aws_secret_access_key=os.environ["APP_SECRET"],
                  config=Config(s3={"addressing_style": "path"}))
seeded = {}
for bucket in ("njozi-media", "njozi-models"):
    for i in range(25):
        key, body = f"migration/{i}/obj-{i}.bin", os.urandom(1024 * (i + 1) * 37)
        s3.put_object(Bucket=bucket, Key=key, Body=body, ContentType="application/octet-stream",
                      CacheControl="public, max-age=31536000, immutable")
        seeded[f"{bucket}/{key}"] = hashlib.sha256(body).hexdigest()
json.dump(seeded, open(sys.argv[1], "w"))
print(f"seeded {len(seeded)} objects")
EOF
archive=$(sh "$coolify/backup.sh" "$project-seaweedfs-1" "$work/backup") || die "backup.sh"
wait_healthy "$project-seaweedfs-1" || die "original stack unhealthy after backup restart"
compose "$project" stop > /dev/null 2>&1

# An archive whose checksum does not match must be refused before anything is
# written. The archive is hard-linked (no copy of a GB-sized file) and the
# recorded digest replaced, which is what sha256sum sees for a corrupt file.
mkdir -p "$work/tampered"
bad="$work/tampered/$(basename "$archive")"
ln "$archive" "$bad"
cp "$archive.manifest.sha256" "$work/tampered/"
sed "1s/^[0-9a-f]*/$(printf '0%.0s' $(seq 64))/" "$archive.sha256" > "$bad.sha256"
if sh "$coolify/restore.sh" "$bad" "${restored}_tamper-check" 2> /dev/null; then
  die "restore.sh accepted an archive that fails its checksum"
fi
docker volume rm "${restored}_tamper-check" > /dev/null 2>&1 || true
log "corrupted archive was refused, as expected"

docker volume rm "${restored}_seaweedfs-data" > /dev/null 2>&1 || true
sh "$coolify/restore.sh" "$archive" "${restored}_seaweedfs-data" || die "restore.sh"
if sh "$coolify/restore.sh" "$archive" "${restored}_seaweedfs-data" 2> /dev/null; then
  die "restore.sh overwrote a non-empty volume without --force"
fi
retry 3 compose "$restored" up -d --no-build > /dev/null 2>&1 || die "restored stack up"
wait_healthy "$restored-seaweedfs-1" || die "restored stack never became healthy"

python3 -W ignore - "$work/objects.json" <<'EOF' || die "restored data differs"
import hashlib, json, os, sys, boto3
from botocore.config import Config
s3 = boto3.client("s3", endpoint_url=os.environ["S3_URL"], verify=False, region_name="us-east-1",
                  aws_access_key_id=os.environ["APP_KEY"], aws_secret_access_key=os.environ["APP_SECRET"],
                  config=Config(s3={"addressing_style": "path"}))
seeded = json.load(open(sys.argv[1]))
bad = []
for path, digest in seeded.items():
    bucket, key = path.split("/", 1)
    obj = s3.get_object(Bucket=bucket, Key=key)
    if hashlib.sha256(obj["Body"].read()).hexdigest() != digest:
        bad.append(path)
    if obj.get("CacheControl") != "public, max-age=31536000, immutable":
        bad.append(path + " (Cache-Control)")
if bad:
    sys.exit(f"{len(bad)} objects differ after restore: {bad[:5]}")
print(f"all {len(seeded)} objects byte-identical after backup/restore")
EOF

log "ALL PASSED"
