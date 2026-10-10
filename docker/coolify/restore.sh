#!/bin/sh
# Restores a backup.sh archive into a Docker volume and proves every file
# arrived intact.
#
#   restore.sh <archive.tar.gz> <volume> [--force]
#
# Checks the archive against its .sha256, refuses to overwrite a volume that
# already holds data (unless --force), extracts, re-verifies every file
# against the manifest taken at backup time, and hands the files to uid 1000,
# which the image runs as. Run it while the SeaweedFS container is stopped.
set -eu

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) restore: $*" >&2; }
die() { log "FATAL: $*"; exit 1; }

[ $# -ge 2 ] || die "usage: $0 <archive.tar.gz> <volume> [--force]"
archive=$1
volume=$2
force=${3:-}
helper_image=${HELPER_IMAGE:-alpine:3.23}

[ -f "$archive" ] || die "no such archive: $archive"
[ -f "$archive.sha256" ] || die "missing $archive.sha256; refusing an unverifiable archive"
[ -f "$archive.manifest.sha256" ] || die "missing $archive.manifest.sha256; refusing an unverifiable archive"
dir=$(cd "$(dirname "$archive")" && pwd)
name=$(basename "$archive")

log "verifying archive checksum"
docker run --rm -v "$dir:/backup:ro" "$helper_image" sh -c 'cd /backup && sha256sum -c "$1.sha256"' check "$name" >&2 ||
  die "archive or manifest checksum mismatch: a file is corrupt or was altered"

docker volume inspect "$volume" > /dev/null 2>&1 || docker volume create "$volume" > /dev/null || die "cannot create volume $volume"

log "restoring into volume $volume"
docker run --rm -v "$dir:/backup:ro" -v "$volume:/data" "$helper_image" sh -euc '
  if [ -n "$(ls -A /data)" ]; then
    if [ "$2" != "--force" ]; then
      echo "volume is not empty; pass --force to replace its contents" >&2
      exit 3
    fi
    find /data -mindepth 1 -delete
  fi
  tar -xzf "/backup/$1" -C /data
  cd /data
  sha256sum -c -s "/backup/$1.manifest.sha256" || { echo "file checksum mismatch after extract" >&2; exit 4; }
  echo "$(wc -l < "/backup/$1.manifest.sha256") files verified"
  chown -R 1000:1000 /data
' restore "$name" "$force" >&2 || die "restore failed (see above); the volume may be partially written"

log "volume $volume restored and verified"
