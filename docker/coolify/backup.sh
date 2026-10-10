#!/bin/sh
# Consistent, verifiable backup of the SeaweedFS data volume, for disaster
# recovery or moving to another server or cloud (see README.md, "Migrating").
#
#   backup.sh <container> <output-dir>
#
# Stops the container (SeaweedFS flushes leveldb and volume indexes on
# SIGTERM), archives every file in its /data volume, writes a per-file SHA-256
# manifest and <archive>.sha256 beside it, and starts the container again,
# even if the backup failed. Keep the three files together. Downtime is the
# time it takes to read the volume.
#
# The archive holds everything a new host needs: objects, filer metadata,
# bucket config, IAM data and the SSE-S3 key material. Treat it as a secret.
set -eu

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) backup: $*" >&2; }
die() { log "FATAL: $*"; exit 1; }

[ $# -eq 2 ] || die "usage: $0 <container> <output-dir>"
container=$1
out_dir=$2
helper_image=${HELPER_IMAGE:-alpine:3.23}

docker inspect "$container" > /dev/null 2>&1 || die "no such container: $container"
volume=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' "$container")
[ -n "$volume" ] || die "$container has no named volume mounted at /data"
mkdir -p "$out_dir" || die "cannot create $out_dir"
out_dir=$(cd "$out_dir" && pwd)
archive="seaweedfs-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"

was_running=$(docker inspect -f '{{.State.Running}}' "$container")
restart() {
  if [ "$was_running" = "true" ]; then
    log "starting $container again"
    docker start "$container" > /dev/null || log "ERROR: could not restart $container; start it by hand"
  fi
}
trap restart EXIT

if [ "$was_running" = "true" ]; then
  log "stopping $container for a consistent snapshot"
  docker stop -t 60 "$container" > /dev/null || die "could not stop $container"
fi

log "archiving volume $volume"
# The per-file manifest travels beside the archive (busybox tar cannot merge
# two source directories); <archive>.sha256 covers both files.
docker run --rm -v "$volume:/data:ro" -v "$out_dir:/backup" "$helper_image" sh -euc '
  cd /data
  find . -type f -exec sha256sum {} + | sort -k2 > "/backup/$1.manifest.sha256"
  tar -czf "/backup/$1" .
  cd /backup && sha256sum "$1" "$1.manifest.sha256" > "$1.sha256"
  echo "$(wc -l < "$1.manifest.sha256") files"
' archive "$archive" >&2 || die "archiving failed"

log "wrote $out_dir/$archive ($(du -h "$out_dir/$archive" | cut -f1)), $archive.manifest.sha256 and $archive.sha256"
echo "$out_dir/$archive"
