#!/bin/sh
# Security scans against a running test stack (start one with KEEP=1 run.sh):
#   - Trivy: image vulnerabilities (fails on fixable HIGH/CRITICAL)
#   - hadolint: Dockerfile.coolify
#   - OWASP ZAP: passive baseline on S3; active full scans of S3 and of the
#     admin UI, the latter authenticated with a real session cookie
#   - nuclei: S3 and admin endpoints
#
# Usage: docker/coolify/test/security_scan.sh <compose-project> <report-dir>
# Exits non-zero when any scanner reports a High (or Critical) finding.
set -eu

[ $# -eq 2 ] || { echo "usage: $0 <compose-project> <report-dir>" >&2; exit 2; }
project=$1
out=$2
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
image=seedexr-seaweedfs-test:latest
network=${project}_default
proxy=${project}-traefik-1
s3=https://$proxy:8443
admin=https://$proxy:9443
mkdir -p "$out"
chmod 777 "$out" # ZAP writes as its own uid
failed=0

log() { echo "$(date -u +%H:%M:%S) scan: $*" >&2; }
flag() { log "HIGH: $*"; failed=1; }

docker inspect "$proxy" > /dev/null 2>&1 || { log "no running proxy $proxy"; exit 2; }
env_of() { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$project-seaweedfs-1" | sed -n "s/^$1=//p"; }

log "trivy image $image"
if ! trivy image --quiet --db-repository ghcr.io/aquasecurity/trivy-db:2 --timeout 20m \
  --scanners vuln,secret --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
  --format table -o "$out/trivy-image.txt" "$image"; then
  flag "trivy found fixable HIGH/CRITICAL issues (see trivy-image.txt)"
fi

log "hadolint"
hadolint "$repo/docker/Dockerfile.coolify" > "$out/hadolint.txt" 2>&1 || flag "hadolint warnings (see hadolint.txt)"

# A public object so ZAP has real S3 responses to analyse, not only 403s.
log "seeding a public object"
python3 -W ignore - "$(env_of AWS_ACCESS_KEY_ID)" "$(env_of AWS_SECRET_ACCESS_KEY)" "$(env_of S3_PUBLIC_READ_BUCKETS | cut -d, -f1)" <<'EOF'
import sys, boto3
from botocore.config import Config
s3 = boto3.client("s3", endpoint_url="https://127.0.0.1:18443", verify=False, region_name="us-east-1",
                  aws_access_key_id=sys.argv[1], aws_secret_access_key=sys.argv[2],
                  config=Config(s3={"addressing_style": "path"}))
s3.put_object(Bucket=sys.argv[3], Key="zap/index.html", Body=b"<html><body>scan target</body></html>",
              ContentType="text/html")
s3.put_object(Bucket=sys.argv[3], Key="zap/tile.webp", Body=b"RIFF0000WEBP", ContentType="image/webp")
EOF
public_bucket=$(env_of S3_PUBLIC_READ_BUCKETS | cut -d, -f1)

# zap <log-name> <zap args...>: ZAP's exit code encodes warnings, so it is
# ignored; the JSON report each scan must produce is checked at the end.
zap() {
  name=$1
  shift
  docker run --rm --network "$network" -v "$out:/zap/wrk:rw" zaproxy/zap-stable "$@" > "$out/$name.log" 2>&1 || true
}

log "ZAP baseline + full scan: S3"
zap zap-s3-baseline zap-baseline.py -t "$s3/$public_bucket/zap/index.html" -I -j \
  -r zap-s3-baseline.html -J zap-s3-baseline.json
zap zap-s3-full zap-full-scan.py -t "$s3/$public_bucket/zap/index.html" -I -m 3 \
  -r zap-s3-full.html -J zap-s3-full.json

log "ZAP authenticated full scan: admin UI"
cookie=$(python3 -W ignore - "$(env_of WEED_ADMIN_USER)" "$(env_of WEED_ADMIN_PASSWORD)" <<'EOF'
import http.cookiejar, re, ssl, sys, urllib.parse, urllib.request
ctx = ssl._create_unverified_context()
jar = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx), urllib.request.HTTPCookieProcessor(jar))
page = op.open("https://127.0.0.1:19443/login").read()
token = re.search(rb'name="csrf_token" value="([^"]+)"', page).group(1).decode()
op.open("https://127.0.0.1:19443/login", urllib.parse.urlencode(
    {"username": sys.argv[1], "password": sys.argv[2], "csrf_token": token}).encode())
print("; ".join(f"{c.name}={c.value}" for c in jar))
EOF
)
[ -n "$cookie" ] || flag "could not log in to the admin UI for the authenticated scan"
printf '40026\tIGNORE\t(DOM XSS: needs a browser ZAP cannot launch in its container)\n' > "$out/zap-rules.conf"
zap zap-admin-full zap-full-scan.py -t "$admin/admin" -I -m 5 -T 60 -c zap-rules.conf \
  -r zap-admin-full.html -J zap-admin-full.json \
  -z "-config replacer.full_list(0).description=session \
      -config replacer.full_list(0).enabled=true \
      -config replacer.full_list(0).matchtype=REQ_HEADER \
      -config replacer.full_list(0).matchstr=Cookie \
      -config replacer.full_list(0).regex=false \
      -config replacer.full_list(0).replacement=$cookie \
      -config globalexcludeurl.url_list.url(0).regex=.*/logout.* \
      -config globalexcludeurl.url_list.url(0).enabled=true"

log "nuclei"
nuclei -silent -disable-update-check -u https://127.0.0.1:18443 -u "https://127.0.0.1:18443/$public_bucket/zap/index.html" \
  -u https://127.0.0.1:19443/login -severity low,medium,high,critical -jsonl -o "$out/nuclei.jsonl" > /dev/null 2>&1 || true
if grep -qE '"severity":"(high|critical)"' "$out/nuclei.jsonl" 2> /dev/null; then
  flag "nuclei found high/critical issues (see nuclei.jsonl)"
fi

log "ZAP alert summary (risk: 3 High, 2 Medium, 1 Low, 0 Info)"
for name in zap-s3-baseline zap-s3-full zap-admin-full; do
  report="$out/$name.json"
  [ -f "$report" ] || { flag "ZAP produced no $name report (scan failed; see $out/$name.log)"; continue; }
  python3 - "$report" "$here/zap-reviewed.tsv" <<'EOF' || failed=1
import json, re, sys
data = json.load(open(sys.argv[1]))
reviewed = []
for line in open(sys.argv[2]):
    if line.strip() and not line.startswith("#"):
        plugin, url_re, param, _why = line.rstrip("\n").split("\t", 3)
        reviewed.append((plugin, re.compile(url_re), param))

def is_reviewed(plugin, inst):
    return any(p == plugin and u.search(inst["uri"]) and (prm == "*" or prm == inst.get("param"))
               for p, u, prm in reviewed)

print(f"  {sys.argv[1].rsplit('/', 1)[-1]}:")
unreviewed_high = 0
for a in sorted((a for site in data.get("site", []) for a in site.get("alerts", [])), key=lambda a: -int(a["riskcode"])):
    open_ = [i for i in a["instances"] if not is_reviewed(a["pluginid"], i)]
    note = "" if open_ else "  (all instances reviewed: zap-reviewed.tsv)"
    print(f"    [{a['riskcode']}] {a['name']} ({a['count']} instances){note}")
    if int(a["riskcode"]) >= 3 and open_:
        unreviewed_high += 1
        for i in open_[:5]:
            print(f"        UNREVIEWED {i['method']} {i['uri']} param={i.get('param')}")
sys.exit(1 if unreviewed_high else 0)
EOF
done

[ "$failed" -eq 0 ] && log "no High findings" || log "High findings present"
exit "$failed"
