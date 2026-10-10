# SeedeXR Storage on Coolify

This deploys SeaweedFS as one `weed mini` process on one persistent volume. That single process runs the master, volume server, filer, S3 API and admin UI. It is built from this repository, so the deployed code is always the code you checked out.

| File | Purpose |
|---|---|
| `docker-compose.yml` | The Coolify resource |
| `../Dockerfile.coolify` | Builds the image: a static Go binary on Alpine, running as non-root uid 1000 |
| `start.sh` | Entrypoint. Validates the environment, writes the S3 identities, mints the gRPC mTLS certificates, then starts SeaweedFS |
| `backup.sh`, `restore.sh` | Verified backup and restore, used for disaster recovery and for migrating |
| `test/run.sh` | End-to-end test suite: unit tests, integration tests behind Traefik, backup/restore |

## Deploy

1. In Coolify, add a new resource from this Git repository (as a public repository or through your GitHub App), and set:

   | Field | Value |
   |---|---|
   | Build Pack | **Docker Compose** |
   | Branch | `master` |
   | Base Directory | `/` |
   | Docker Compose Location | `/docker/coolify/docker-compose.yml` |

   Keep Base Directory at `/`. Coolify runs `docker compose --project-directory <checkout><Base Directory>`, so paths in the compose file, including the build context `.`, resolve from the repo root.
2. Click **Load compose** (labelled **Reload compose** once loaded). A `seaweedfs` service appears, and the generated secrets appear under **Environment Variables**.
3. Under **Domains** for the `seaweedfs` service, enter the hostnames with the container port:
   ```
   https://s3.example.com:8333,https://media.example.com:8333,https://storage-admin.example.com:23646
   ```
   - `s3.` is the S3 API, used for presigned uploads and server-side calls.
   - `media.` is the public read hostname that Cloudflare will cache. It is optional.
   - `storage-admin.` is the admin UI. It is optional, so leave it out to keep the UI unreachable.
   - Never attach a domain to any other port.
4. Under **Environment Variables**, set `S3_APP_BUCKETS`, and `S3_PUBLIC_READ_BUCKETS` if any buckets serve public reads. See [Settings](#settings).
5. Optional: under **Advanced**, set **Source commit availability** to **Available during build**, so the admin UI footer shows the deployed commit. It costs little: `SOURCE_COMMIT` is read after the source is copied in, and the Go build cache keeps rebuilds incremental.
6. Deploy. The first build takes a few minutes. Later builds reuse the Go module and build caches.
7. Check it: `curl -fsS https://s3.example.com/healthz` returns 200. Sign in to the admin UI as `admin` with `SERVICE_PASSWORD_ADMIN`.

Coolify generates these secrets, and they don't change on redeploy:

| Variable | What it is |
|---|---|
| `SERVICE_USER_S3` / `SERVICE_PASSWORD_64_S3` | Admin S3 access key and secret. Full access, for operators only |
| `SERVICE_USER_S3APP` / `SERVICE_PASSWORD_64_S3APP` | Scoped app access key and secret. **Give these to applications** |
| `SERVICE_PASSWORD_ADMIN` | Admin UI password. The user is `admin` (`ADMIN_USER`) |
| `SERVICE_HEX_64_*` | Signing keys for JWTs between the internal components |

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `S3_APP_BUCKETS` | required | Buckets the app identity may use, comma separated. They are created on first start |
| `S3_PUBLIC_READ_BUCKETS` | empty | Buckets whose objects anyone can GET by exact key. Listing them stays private |
| `S3_ALLOWED_ORIGINS` | `*` | CORS origins. Keep `*` when a CDN caches public reads (see Cloudflare below) |
| `S3_BUCKET` | `S3_APP_BUCKETS` | Extra buckets to create on startup |
| `ADMIN_USER` | `admin` | Admin UI user name |
| `GOMEMLIMIT` | empty | Soft heap cap for the Go GC. Set it to about 90% of the container memory limit, e.g. `900MiB` for 1 GiB |
| `GRPC_MTLS` | `on` | Mutual TLS on the internal gRPC ports. Set it to `off` only if an external `weed shell` or worker must connect |
| `S3_CONTENT_SECURITY_POLICY` | a sandbox policy | CSP sent with every S3 response. An uploaded `.html` or `.svg` opened directly can't run script on your domain. Images, video, `fetch()` and model loaders aren't affected. Set it to an empty value only if you host a website from a bucket |

For the Njozi app, set:

```
S3_APP_BUCKETS=njozi-media,njozi-models
S3_PUBLIC_READ_BUCKETS=njozi-media,njozi-models
```

Both buckets are public-read because browsers load panoramas, video and 3D models straight from their URLs. The app's `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` are this deployment's `SERVICE_USER_S3APP` / `SERVICE_PASSWORD_64_S3APP`.

The app identity can Get, Put, Head and Delete objects, and List them with a prefix, on `S3_APP_BUCKETS` only. It cannot create or delete buckets, change policies or ACLs, or touch any other bucket. The integration tests check all of this.

## Cloudflare (free plan)

Use two hostnames:

- **`s3.example.com`: DNS only (grey cloud).** Presigned PUTs and server calls go here. Cloudflare's free plan rejects request bodies over 100 MB, and videos can reach 500 MB. Bypassing the proxy also keeps the SigV4-signed `Host` header exactly as the client signed it.
- **`media.example.com`: Proxied (orange cloud).** Public reads go here, as path-style URLs: `https://media.example.com/<bucket>/<key>`.
  - Add a **Cache Rule** for this hostname: *Eligible for cache*, with *Edge TTL: use cache-control header if present*. Without it, Cloudflare only caches known extensions, so `.m3u8` and `.ts` HLS files would not be cached.
  - Objects written with `Cache-Control: public, max-age=31536000, immutable` are then cached for a year at the edge.
  - Cloudflare free caches files up to 512 MB. Larger files are still served, just not cached.
  - Set SSL/TLS mode to **Full (strict)**. Coolify's Let's Encrypt certificate is valid.
  - Keep `S3_ALLOWED_ORIGINS=*`. The free plan does not vary its cache on `Origin`, so a per-origin `Access-Control-Allow-Origin` value would be cached and served to other sites.

Point apps at the right hostname for each job. For example, the Njozi app uses `S3_PUBLIC_ENDPOINT=https://s3.example.com` for presigning and server calls, and `S3_PUBLIC_URL_MEDIA=https://media.example.com/njozi-media` for reads.

## Monitoring

- **Health:** the container healthcheck polls S3 `/healthz` every 15s. S3 starts last, so healthy means the whole stack is up. Coolify shows this status and restarts the container on failure (`restart: unless-stopped`).
- **Logs** appear under Coolify → Logs. Docker rotates them at 5 × 20 MB. Lines worth alerting on:
  - `coolify-start: FATAL`: the configuration was rejected at boot. The line names the variable to fix.
  - `admin login failed for user`: a failed admin login, with the client address and X-Forwarded-For.
  - `admin login throttled`: repeated failures, likely brute forcing.
  - `gRPC admin auth failed`: an unauthorized internal RPC.
- **Metrics:** Prometheus `/metrics` is on container port 9327. Scrape it from a Prometheus on the same Coolify network, and never attach a domain to it. It serves only `/metrics`; the profiling endpoints are not exposed.

## Backups and migrating to another server or cloud

All state lives in the `seaweedfs-data` volume: objects, filer metadata, bucket settings, IAM data and SSE key material. The only other state is the environment variables. A move is therefore one verified archive plus a copy of the variables.

On the old server:

```sh
docker ps --format '{{.Names}}' | grep seaweedfs        # find the container
sh docker/coolify/backup.sh <container> /root/backups    # stops it briefly, archives /data, starts it again
```

You get three files to keep together: `seaweedfs-<timestamp>.tar.gz`, `.manifest.sha256` (a checksum for every file inside) and `.sha256` (checksums of the first two). The archive contains your data and encryption keys, so store it like a secret.

On the new server or cloud:

1. Create the same Coolify resource. Copy `SERVICE_USER_S3`, `SERVICE_PASSWORD_64_S3`, `SERVICE_USER_S3APP`, `SERVICE_PASSWORD_64_S3APP` and `SERVICE_PASSWORD_ADMIN` from the old resource, so clients keep working. The JWT keys can be new.
2. Deploy once, which creates the volume, then stop the resource.
3. Copy all three files to the new server, then run:
   ```sh
   docker volume ls | grep seaweedfs-data                     # the volume Coolify created
   sh docker/coolify/restore.sh seaweedfs-<timestamp>.tar.gz <volume> --force
   ```
   The restore checks the archive's checksum first, then re-checks every file after extraction. It refuses a non-empty volume unless you pass `--force`.
4. Start the resource and switch DNS.

`test/run.sh` runs this whole path on every test run, and requires every object to come back byte-identical with the same credentials.

**Moving off SeaweedFS**, to R2, AWS S3 or any other S3-compatible store, needs no downtime. Copy the objects with [rclone](https://rclone.org) while the old system keeps serving:

```ini
# ~/.config/rclone/rclone.conf
[seedexr]
type = s3
provider = Other
endpoint = https://s3.example.com
access_key_id = <SERVICE_USER_S3>
secret_access_key = <SERVICE_PASSWORD_64_S3>
force_path_style = true

[target]
type = s3
provider = Cloudflare        # or AWS, Wasabi, ...
endpoint = https://<account>.r2.cloudflarestorage.com
access_key_id = ...
secret_access_key = ...
```

```sh
rclone sync seedexr:njozi-media target:njozi-media --checksum --metadata --progress
rclone check seedexr:njozi-media target:njozi-media     # must report 0 differences
```

`--metadata` carries Content-Type and Cache-Control across. Run the sync again just before cutover to catch late writes.

## Security model

- **Credentials:** S3 never runs anonymously. `start.sh` refuses to boot without the admin S3 keys and the admin UI password. Anonymous access exists only as GetObject on the buckets you list in `S3_PUBLIC_READ_BUCKETS`.
- **Exposure:** only ports with a Coolify domain are reachable from outside, and no host ports are published.
- **Internal components:** master, volume and filer require JWTs on HTTP, and mutual TLS on gRPC, using a CA minted per boot whose key is deleted after signing. A neighbouring container cannot bypass S3 auth. Writes over HTTP are also restricted to loopback (`-whiteList=127.0.0.1`).
- **Admin UI:**
  - Requires a password, compared in constant time, with CSRF protection.
  - Failed logins are logged and throttled.
  - Session cookies are `HttpOnly; Secure; SameSite=Lax` behind the TLS proxy.
  - Logging out revokes the session on the server, so a copied cookie stops working.
  - Responses carry CSP, `frame-ancestors 'self'`, HSTS, nosniff, Referrer-Policy and Permissions-Policy.
  - Uploaded SVG and HTML files are always downloaded, never rendered inside the admin origin.
- **S3 responses:**
  - `Server` names no version.
  - Every response carries `nosniff`, HSTS (over HTTPS) and the sandbox CSP.
  - A `*` CORS rule answers a literal `*`, as AWS S3 does, so a shared CDN cache is correct for every origin.
  - Listing a bucket's in-progress multipart uploads needs List permission. Read is not enough, and neither is anonymous public-read.
- **Image:** non-root, a static binary, no shell tools beyond busybox and openssl, and no fuse.
- **Telemetry:** off (`-master.telemetry=false`).

### Accepted risks and follow-ups

- **The admin UI's CSP allows `'unsafe-inline'` scripts.** The templates contain 32 inline scripts and 131 inline event handlers, so removing it means a template refactor. All template output is escaped by templ, and nothing is loaded from other origins.
- **Revoked admin sessions are held in memory.** After a restart, a cookie copied before a logout works again until it expires (at most 24 hours). Persist the revocation list if that matters.
- **The admin UI shows SeaweedFS feature pages this deployment doesn't use** (Iceberg, Lance, message queue). They have no effect while those servers are off.
- **Scanner findings judged not applicable.** Each was verified by hand; the details are in `test/zap-reviewed.tsv`, which the scan gate uses.
  - ZAP "Cross Site Scripting (Reflected)" on `/files` (`path`, `lastFileName`). The values are reflected only as escaped text and as a JSON-encoded string argument, and breakout payloads stay inside the string.
  - ZAP "SQL Injection" on admin pages. The admin UI builds no SQL. The only SQL in the binary is the optional MySQL/Postgres filer stores, which bind every value as a parameter; this deployment uses leveldb.
  - ZAP "CORS Misconfiguration" on S3. `Access-Control-Allow-Origin: *` without credentials is intentional, because public media must load cross-origin from any customer domain.
  - ZAP "Proxy Disclosure": this is Coolify's Traefik.
  - nuclei "self-signed-ssl": the local test proxy only. Coolify serves Let's Encrypt.
  - Trivy GO-2026-5932 (`x/crypto/openpgp`): the module is listed but that package is not compiled into `weed`.

## Tests

```sh
docker/coolify/test/run.sh            # everything; about 10 minutes with the 520 MB upload
LARGE_MB=0 docker/coolify/test/run.sh # skip the large-upload test
sh docker/coolify/start_test.sh       # start.sh unit tests only
KEEP=1 LARGE_MB=0 docker/coolify/test/run.sh && \
  docker/coolify/test/security_scan.sh swtestrestored ./scan-reports   # Trivy, hadolint, ZAP, nuclei
```

`security_scan.sh` runs the following against the stack that `run.sh` left running:
- Trivy on the image, failing on fixable HIGH/CRITICAL.
- hadolint.
- OWASP ZAP: a baseline and an active scan of S3, and an authenticated active scan of the admin UI.
- nuclei.

It exits non-zero on any High finding.
