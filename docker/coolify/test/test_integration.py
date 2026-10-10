"""Integration tests for the Coolify deployment, run by run.sh against the
real stack behind Traefik (TLS terminated at the proxy, as in production).

Configuration comes from the environment run.sh sets:
  S3_URL, ADMIN_URL                 proxied endpoints (https, self-signed)
  ADMIN_KEY, ADMIN_SECRET           admin S3 identity
  APP_KEY, APP_SECRET               scoped app identity
  ADMIN_USER, ADMIN_PASSWORD        admin UI login
  PUBLIC_BUCKET, PRIVATE_BUCKET     public-read and private app buckets
  DOCKER_NETWORK, SEAWEEDFS_HOST    for probing internal ports from a neighbour container
  LARGE_MB                          size of the large-upload test (0 skips it)
"""

import hashlib
import http.client
import http.cookiejar
import os
import re
import ssl
import subprocess
import tempfile
import unittest
import urllib.error
import urllib.parse
import urllib.request
import uuid

import boto3
from boto3.s3.transfer import TransferConfig
from botocore.config import Config
from botocore.exceptions import ClientError

ENV = os.environ
S3_URL = ENV["S3_URL"]
ADMIN_URL = ENV["ADMIN_URL"]
PUBLIC_BUCKET = ENV.get("PUBLIC_BUCKET", "njozi-media")
PRIVATE_BUCKET = ENV.get("PRIVATE_BUCKET", "njozi-models")
INSECURE = ssl._create_unverified_context()  # Traefik's default self-signed cert


def s3_client(key, secret):
    return boto3.client(
        "s3",
        endpoint_url=S3_URL,
        aws_access_key_id=key,
        aws_secret_access_key=secret,
        region_name="us-east-1",
        verify=False,
        config=Config(
            signature_version="s3v4",
            s3={"addressing_style": "path"},
            # Matches the Njozi app: checksums only when an API requires them.
            request_checksum_calculation="when_required",
            response_checksum_validation="when_required",
            retries={"max_attempts": 3, "mode": "standard"},
        ),
    )


ADMIN = s3_client(ENV["ADMIN_KEY"], ENV["ADMIN_SECRET"])
APP = s3_client(ENV["APP_KEY"], ENV["APP_SECRET"])


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def request(method, url, headers=None, body=None, opener=None):
    """Returns (status, headers, body) without raising on 4xx/5xx."""
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    open_ = opener.open if opener else (lambda r, timeout: urllib.request.urlopen(r, context=INSECURE, timeout=timeout))
    try:
        with open_(req, timeout=120) as resp:
            return resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as err:
        return err.code, err.headers, err.read()


def error_code(err):
    return err.response.get("Error", {}).get("Code")


def unique(prefix="t"):
    return f"{prefix}-{uuid.uuid4().hex[:12]}"


class S3AuthTest(unittest.TestCase):
    def test_anonymous_cannot_list_buckets(self):
        status, _, _ = request("GET", S3_URL + "/")
        self.assertEqual(status, 403)

    def test_wrong_secret_is_rejected(self):
        bad = s3_client(ENV["APP_KEY"], "wrong-secret")
        with self.assertRaises(ClientError) as ctx:
            bad.list_objects_v2(Bucket=PUBLIC_BUCKET)
        self.assertIn(error_code(ctx.exception), ("SignatureDoesNotMatch", "AccessDenied", "InvalidAccessKeyId"))

    def test_app_buckets_were_created_on_startup(self):
        names = {b["Name"] for b in ADMIN.list_buckets()["Buckets"]}
        self.assertTrue({PUBLIC_BUCKET, PRIVATE_BUCKET} <= names, names)


class AppIdentityTest(unittest.TestCase):
    """What the Njozi app does, with the identity it will hold."""

    CONTENT_TYPES = [
        ("image/webp", ".webp"),
        ("image/jpeg", ".jpg"),
        ("video/mp4", ".mp4"),
        ("application/vnd.apple.mpegurl", ".m3u8"),
        ("video/mp2t", ".ts"),
        ("audio/mp4", ".m4a"),
    ]
    CACHE_CONTROL = "public, max-age=31536000, immutable"

    def test_put_head_get_delete_preserve_content_type_and_cache_control(self):
        for bucket in (PUBLIC_BUCKET, PRIVATE_BUCKET):
            for content_type, ext in self.CONTENT_TYPES:
                with self.subTest(bucket=bucket, content_type=content_type):
                    key = f"ws/{unique()}/derived/file{ext}"
                    body = os.urandom(4096)
                    APP.put_object(Bucket=bucket, Key=key, Body=body,
                                   ContentType=content_type, CacheControl=self.CACHE_CONTROL)
                    head = APP.head_object(Bucket=bucket, Key=key)
                    self.assertEqual(head["ContentType"], content_type)
                    self.assertEqual(head["CacheControl"], self.CACHE_CONTROL)
                    self.assertEqual(head["ContentLength"], len(body))
                    got = APP.get_object(Bucket=bucket, Key=key)
                    self.assertEqual(got["ContentType"], content_type)
                    self.assertEqual(got["CacheControl"], self.CACHE_CONTROL)
                    self.assertEqual(got["Body"].read(), body)
                    APP.delete_object(Bucket=bucket, Key=key)
                    with self.assertRaises(ClientError) as ctx:
                        APP.head_object(Bucket=bucket, Key=key)
                    self.assertEqual(ctx.exception.response["ResponseMetadata"]["HTTPStatusCode"], 404)

    def test_range_get_returns_206(self):
        key = f"ws/{unique()}/video/clip.mp4"
        body = os.urandom(10_000)
        APP.put_object(Bucket=PUBLIC_BUCKET, Key=key, Body=body, ContentType="video/mp4")
        try:
            got = APP.get_object(Bucket=PUBLIC_BUCKET, Key=key, Range="bytes=100-199")
            self.assertEqual(got["ResponseMetadata"]["HTTPStatusCode"], 206)
            self.assertEqual(got["ContentRange"], f"bytes 100-199/{len(body)}")
            self.assertEqual(got["Body"].read(), body[100:200])
            # Anonymous range read, as a <video> element would do it.
            status, headers, data = request("GET", f"{S3_URL}/{PUBLIC_BUCKET}/{key}", {"Range": "bytes=0-9"})
            self.assertEqual(status, 206)
            self.assertEqual(data, body[:10])
            self.assertEqual(headers.get("Accept-Ranges"), "bytes")
        finally:
            APP.delete_object(Bucket=PUBLIC_BUCKET, Key=key)

    def test_list_v2_prefix_returns_nested_keys(self):
        root = f"ws/{unique()}/pano/abc-room.jpg"
        keys = [f"{root}/tiles/1024-0.webp", f"{root}/tiles/1024-1.webp", f"{root}/base-2048.webp"]
        sibling = f"{root}-other/thumb.webp"
        for k in keys + [sibling]:
            APP.put_object(Bucket=PUBLIC_BUCKET, Key=k, Body=b"x")
        try:
            listed = APP.list_objects_v2(Bucket=PUBLIC_BUCKET, Prefix=root + "/")
            self.assertEqual(sorted(o["Key"] for o in listed.get("Contents", [])), sorted(keys))
        finally:
            for k in keys + [sibling]:
                APP.delete_object(Bucket=PUBLIC_BUCKET, Key=k)

    def test_cannot_manage_buckets(self):
        attempts = {
            "create bucket": lambda: APP.create_bucket(Bucket=unique("app-made")),
            "delete bucket": lambda: APP.delete_bucket(Bucket=PRIVATE_BUCKET),
            "put bucket policy": lambda: APP.put_bucket_policy(
                Bucket=PUBLIC_BUCKET,
                Policy='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*",'
                       f'"Action":"s3:ListBucket","Resource":"arn:aws:s3:::{PUBLIC_BUCKET}"}}]}}'),
            "put bucket acl": lambda: APP.put_bucket_acl(Bucket=PUBLIC_BUCKET, ACL="public-read-write"),
        }
        for name, attempt in attempts.items():
            with self.subTest(name):
                with self.assertRaises(ClientError) as ctx:
                    attempt()
                self.assertEqual(ctx.exception.response["ResponseMetadata"]["HTTPStatusCode"], 403,
                                 f"{name}: {ctx.exception}")
        self.assertIn(PRIVATE_BUCKET, {b["Name"] for b in ADMIN.list_buckets()["Buckets"]})

    def test_no_access_outside_its_buckets(self):
        other = unique("private")
        ADMIN.create_bucket(Bucket=other)
        ADMIN.put_object(Bucket=other, Key="secret.txt", Body=b"admin only")
        try:
            for name, attempt in {
                "get": lambda: APP.get_object(Bucket=other, Key="secret.txt"),
                "put": lambda: APP.put_object(Bucket=other, Key="x", Body=b"x"),
                "list": lambda: APP.list_objects_v2(Bucket=other),
                "delete": lambda: APP.delete_object(Bucket=other, Key="secret.txt"),
            }.items():
                with self.subTest(name):
                    with self.assertRaises(ClientError):
                        attempt()
            self.assertEqual(ADMIN.get_object(Bucket=other, Key="secret.txt")["Body"].read(), b"admin only")
        finally:
            for obj in ADMIN.list_objects_v2(Bucket=other).get("Contents", []):
                ADMIN.delete_object(Bucket=other, Key=obj["Key"])
            ADMIN.delete_bucket(Bucket=other)

    def test_presigned_put_through_proxy(self):
        key = f"ws/{unique()}/images/{uuid.uuid4()}-photo.webp"
        body = os.urandom(50_000)
        url = APP.generate_presigned_url(
            "put_object", Params={"Bucket": PUBLIC_BUCKET, "Key": key, "ContentType": "image/webp"}, ExpiresIn=300)
        try:
            status, _, resp = request("PUT", url, {"Content-Type": "image/webp", "Content-Length": str(len(body))}, body)
            self.assertEqual(status, 200, resp[:300])
            status, headers, data = request("GET", f"{S3_URL}/{PUBLIC_BUCKET}/{key}")
            self.assertEqual(status, 200)
            self.assertEqual(data, body)
            self.assertEqual(headers.get("Content-Type"), "image/webp")
        finally:
            APP.delete_object(Bucket=PUBLIC_BUCKET, Key=key)

    def test_presigned_put_rejects_a_different_content_type(self):
        key = f"ws/{unique()}/images/x.webp"
        url = APP.generate_presigned_url(
            "put_object", Params={"Bucket": PUBLIC_BUCKET, "Key": key, "ContentType": "image/webp"}, ExpiresIn=300)
        status, _, _ = request("PUT", url, {"Content-Type": "text/html"}, b"<script>alert(1)</script>")
        self.assertEqual(status, 403)
        with self.assertRaises(ClientError):
            APP.head_object(Bucket=PUBLIC_BUCKET, Key=key)


class AnonymousAccessTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.key = f"ws/{unique()}/images/public.webp"
        APP.put_object(Bucket=PUBLIC_BUCKET, Key=cls.key, Body=b"public bytes", ContentType="image/webp")
        APP.put_object(Bucket=PRIVATE_BUCKET, Key=cls.key, Body=b"private bytes")

    @classmethod
    def tearDownClass(cls):
        APP.delete_object(Bucket=PUBLIC_BUCKET, Key=cls.key)
        APP.delete_object(Bucket=PRIVATE_BUCKET, Key=cls.key)

    def test_public_bucket_object_is_readable(self):
        status, _, data = request("GET", f"{S3_URL}/{PUBLIC_BUCKET}/{self.key}")
        self.assertEqual((status, data), (200, b"public bytes"))
        status, _, _ = request("HEAD", f"{S3_URL}/{PUBLIC_BUCKET}/{self.key}")
        self.assertEqual(status, 200)

    def test_public_bucket_cannot_be_listed(self):
        for query in ("", "?list-type=2", "?list-type=2&prefix=ws/", "?versions", "?uploads"):
            with self.subTest(query=query):
                status, _, body = request("GET", f"{S3_URL}/{PUBLIC_BUCKET}/{query}")
                self.assertEqual(status, 403, body[:200])
                self.assertNotIn(self.key.encode(), body)

    def test_private_bucket_object_is_not_readable(self):
        status, _, body = request("GET", f"{S3_URL}/{PRIVATE_BUCKET}/{self.key}")
        self.assertEqual(status, 403)
        self.assertNotIn(b"private bytes", body)

    def test_anonymous_cannot_write_or_delete(self):
        status, _, _ = request("PUT", f"{S3_URL}/{PUBLIC_BUCKET}/{unique()}.txt", body=b"x")
        self.assertEqual(status, 403)
        status, _, _ = request("DELETE", f"{S3_URL}/{PUBLIC_BUCKET}/{self.key}")
        self.assertEqual(status, 403)
        self.assertEqual(request("GET", f"{S3_URL}/{PUBLIC_BUCKET}/{self.key}")[0], 200)


class S3ResponseHardeningTest(unittest.TestCase):
    def test_object_responses_are_sandboxed_and_hardened(self):
        key = f"ws/{unique()}/evil.html"
        APP.put_object(Bucket=PUBLIC_BUCKET, Key=key, Body=b"<script>alert(document.domain)</script>",
                       ContentType="text/html")
        try:
            status, headers, _ = request("GET", f"{S3_URL}/{PUBLIC_BUCKET}/{key}")
            self.assertEqual(status, 200)
            self.assertEqual(headers.get("Server"), "SeaweedFS")  # no version to fingerprint
            self.assertEqual(headers.get("X-Content-Type-Options"), "nosniff")
            self.assertTrue(headers.get("Strict-Transport-Security", "").startswith("max-age="))
            csp = headers.get("Content-Security-Policy", "")
            self.assertTrue(csp.startswith("sandbox"), csp)
            self.assertIn("default-src 'none'", csp)
        finally:
            APP.delete_object(Bucket=PUBLIC_BUCKET, Key=key)

    def test_error_responses_do_not_leak_version(self):
        _, headers, _ = request("GET", S3_URL + "/")
        self.assertEqual(headers.get("Server"), "SeaweedFS")


class CorsTest(unittest.TestCase):
    ORIGIN = "https://tours.customer-domain.example"

    def test_preflight_for_presigned_put_with_content_type(self):
        status, headers, _ = request("OPTIONS", f"{S3_URL}/{PUBLIC_BUCKET}/ws/x/upload.mp4", {
            "Origin": self.ORIGIN,
            "Access-Control-Request-Method": "PUT",
            "Access-Control-Request-Headers": "content-type",
        })
        self.assertEqual(status, 200)
        self.assertIn(headers.get("Access-Control-Allow-Origin"), ("*", self.ORIGIN))
        self.assertIn("PUT", headers.get("Access-Control-Allow-Methods", ""))
        self.assertIn("content-type", headers.get("Access-Control-Allow-Headers", "").lower())

    def test_anonymous_cross_origin_get_carries_cors_headers(self):
        key = f"ws/{unique()}/tiles/0.webp"
        APP.put_object(Bucket=PUBLIC_BUCKET, Key=key, Body=b"tile", ContentType="image/webp")
        try:
            for origin in (self.ORIGIN, "https://njozi.seedexr.example"):
                status, headers, _ = request("GET", f"{S3_URL}/{PUBLIC_BUCKET}/{key}", {"Origin": origin})
                self.assertEqual(status, 200)
                # Exactly "*", never the caller's origin: a CDN that ignores
                # Vary: Origin (Cloudflare free) would replay it to other sites.
                self.assertEqual(headers.get("Access-Control-Allow-Origin"), "*")
                self.assertIsNone(headers.get("Access-Control-Allow-Credentials"))
        finally:
            APP.delete_object(Bucket=PUBLIC_BUCKET, Key=key)


@unittest.skipUnless(int(ENV.get("LARGE_MB", "0")) > 0, "LARGE_MB=0")
class LargeUploadTest(unittest.TestCase):
    """A 500 MB video must pass the proxy intact, via presigned PUT and multipart."""

    @classmethod
    def setUpClass(cls):
        cls.size = int(ENV["LARGE_MB"]) * 1024 * 1024
        cls.file = tempfile.NamedTemporaryFile(delete=False)
        digest = hashlib.sha256()
        chunk = os.urandom(8 * 1024 * 1024)
        written = 0
        while written < cls.size:
            piece = chunk[: min(len(chunk), cls.size - written)]
            cls.file.write(piece)
            digest.update(piece)
            written += len(piece)
        cls.file.close()
        cls.sha256 = digest.hexdigest()

    @classmethod
    def tearDownClass(cls):
        os.unlink(cls.file.name)

    def download_sha256(self, key):
        digest = hashlib.sha256()
        body = APP.get_object(Bucket=PUBLIC_BUCKET, Key=key)["Body"]
        for piece in iter(lambda: body.read(8 * 1024 * 1024), b""):
            digest.update(piece)
        return digest.hexdigest()

    def test_presigned_put_streams_large_file(self):
        key = f"ws/{unique()}/video/original.mp4"
        url = urllib.parse.urlsplit(APP.generate_presigned_url(
            "put_object", Params={"Bucket": PUBLIC_BUCKET, "Key": key, "ContentType": "video/mp4"}, ExpiresIn=3600))
        conn = http.client.HTTPSConnection(url.hostname, url.port, context=INSECURE, timeout=900)
        try:
            with open(self.file.name, "rb") as f:
                conn.request("PUT", f"{url.path}?{url.query}", body=f,
                             headers={"Content-Type": "video/mp4", "Content-Length": str(self.size)})
                resp = conn.getresponse()
                self.assertEqual(resp.status, 200, resp.read()[:300])
            self.assertEqual(APP.head_object(Bucket=PUBLIC_BUCKET, Key=key)["ContentLength"], self.size)
            self.assertEqual(self.download_sha256(key), self.sha256)
        finally:
            conn.close()
            APP.delete_object(Bucket=PUBLIC_BUCKET, Key=key)

    def test_multipart_upload_large_file(self):
        key = f"ws/{unique()}/video/multipart.mp4"
        try:
            APP.upload_file(self.file.name, PUBLIC_BUCKET, key, ExtraArgs={"ContentType": "video/mp4"},
                            Config=TransferConfig(multipart_threshold=64 * 1024 * 1024,
                                                  multipart_chunksize=64 * 1024 * 1024))
            self.assertEqual(self.download_sha256(key), self.sha256)
        finally:
            APP.delete_object(Bucket=PUBLIC_BUCKET, Key=key)


@unittest.skipUnless(ENV.get("DOCKER_NETWORK"), "DOCKER_NETWORK not set")
class InternalSurfaceTest(unittest.TestCase):
    """A neighbour container on the same network must not bypass S3 auth."""

    def probe(self, *wget_args):
        host = ENV.get("SEAWEEDFS_HOST", "seaweedfs")
        script = 'wget -S -q -O /dev/null "$@" 2>&1 | grep -m1 "HTTP/" | awk "{print \\$2}"'
        args = [a.replace("{host}", host) for a in wget_args]
        out = subprocess.run(
            ["docker", "run", "--rm", "--network", ENV["DOCKER_NETWORK"], "alpine:3.23", "sh", "-c", script, "probe", *args],
            capture_output=True, text=True, timeout=120)
        return out.stdout.strip()

    def test_internal_data_paths_require_jwt(self):
        cases = {
            "master assign": ("http://{host}:9333/dir/assign", "401"),
            "filer read": ("http://{host}:8888/buckets/", "401"),
            "filer iam config": ("http://{host}:8888/etc/iam/identity.json", "401"),
            "volume read": ("http://{host}:9340/1,0100000000", "401"),
        }
        for name, (url, want) in cases.items():
            with self.subTest(name):
                self.assertEqual(self.probe(url), want)

    def test_internal_writes_require_jwt(self):
        self.assertEqual(self.probe("--post-data=x", "http://{host}:8888/buckets/%s/pwn.txt" % PUBLIC_BUCKET), "401")
        self.assertEqual(self.probe("--post-data=x", "http://{host}:9340/1,0100000000"), "401")

    def test_grpc_ports_require_a_client_certificate(self):
        # A plaintext gRPC server cannot answer a TLS ClientHello at all; an
        # mTLS one completes the server side and then rejects the missing
        # client certificate. In TLS 1.3 that rejection arrives after the
        # client's Finished, so the client stays connected long enough to
        # read it instead of racing it with an immediate EOF.
        host = ENV.get("SEAWEEDFS_HOST", "seaweedfs")
        script = ('apk add -q --no-cache openssl >/dev/null 2>&1; '
                  'sleep 3 | openssl s_client -connect "$1" -tls1_3 2>&1')
        for name, port in (("master", 19333), ("volume", 19340), ("filer", 18888), ("s3", 18333)):
            with self.subTest(name):
                out = subprocess.run(
                    ["docker", "run", "--rm", "--network", ENV["DOCKER_NETWORK"], "alpine:3.23",
                     "sh", "-c", script, "probe", f"{host}:{port}"],
                    capture_output=True, text=True, timeout=180).stdout
                self.assertIn("seaweedfs-grpc", out, f"{name} did not present the internal cert:\n{out[-800:]}")
                self.assertIn("alert certificate required", out.lower(), f"{name} accepted a client without a cert:\n{out[-800:]}")

    def test_metrics_port_serves_metrics_but_not_pprof(self):
        self.assertEqual(self.probe("http://{host}:9327/metrics"), "200")
        self.assertEqual(self.probe("http://{host}:9327/debug/pprof/"), "404")


class AdminUiTest(unittest.TestCase):
    def opener(self, follow=True):
        jar = http.cookiejar.CookieJar()
        handlers = [urllib.request.HTTPSHandler(context=INSECURE), urllib.request.HTTPCookieProcessor(jar)]
        if not follow:
            handlers.append(NoRedirect)
        return urllib.request.build_opener(*handlers)

    def login(self, opener, password):
        status, _, page = request("GET", ADMIN_URL + "/login", opener=opener)
        self.assertEqual(status, 200)
        token = re.search(rb'name="csrf_token" value="([^"]+)"', page).group(1).decode()
        form = urllib.parse.urlencode({"username": ENV["ADMIN_USER"], "password": password, "csrf_token": token})
        return request("POST", ADMIN_URL + "/login",
                       {"Content-Type": "application/x-www-form-urlencoded"}, form.encode(), opener=opener)

    def test_pages_require_login(self):
        status, headers, _ = request("GET", ADMIN_URL + "/admin", opener=self.opener(follow=False))
        self.assertIn(status, (302, 303, 307))
        self.assertIn("/login", headers.get("Location", ""))

    def test_wrong_password_is_rejected(self):
        status, headers, _ = self.login(self.opener(follow=False), "not-the-password")
        self.assertEqual(status, 303)
        self.assertIn("Invalid", urllib.parse.unquote(headers.get("Location", "")))

    def test_login_sets_hardened_session_cookie_and_headers(self):
        opener = self.opener(follow=False)
        status, headers, _ = self.login(opener, ENV["ADMIN_PASSWORD"])
        self.assertEqual(status, 303)
        self.assertTrue(headers.get("Location", "").endswith("/admin"))
        cookie = headers.get("Set-Cookie", "")
        for attr in ("HttpOnly", "Secure", "SameSite=Lax"):
            self.assertIn(attr, cookie)
        for header in ("Content-Security-Policy", "X-Frame-Options", "X-Content-Type-Options",
                       "Strict-Transport-Security", "Referrer-Policy"):
            self.assertTrue(headers.get(header), f"missing {header}")

        status, _, page = request("GET", ADMIN_URL + "/admin", opener=opener)
        self.assertEqual(status, 200)
        self.assertIn(b'data-bs-theme="dark"', page)
        self.assertIn(b"seedexr-mark.svg", page)
        self.assertIn(b"SeedeXR", page)

    def test_branding_assets_are_served(self):
        for path, ctype in (("/static/img/seedexr-mark.svg", "image/svg+xml"),
                            ("/static/img/seedexr-lockup.svg", "image/svg+xml"),
                            ("/static/img/seedexr-favicon.svg", "image/svg+xml"),
                            ("/static/css/seedexr.css", "text/css")):
            with self.subTest(path):
                status, headers, body = request("GET", ADMIN_URL + path)
                self.assertEqual(status, 200)
                self.assertTrue(headers.get("Content-Type", "").startswith(ctype), headers.get("Content-Type"))
                self.assertGreater(len(body), 100)


if __name__ == "__main__":
    unittest.main(verbosity=2)
