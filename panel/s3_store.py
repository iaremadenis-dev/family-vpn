#!/usr/bin/env python3
"""S3-compatible upload and download. Credentials stay in the env file."""

import hashlib
import hmac
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


def load_env(path):
    values = {}
    for raw in Path(path).read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    for key in ("S3_ENDPOINT", "S3_BUCKET", "S3_REGION", "S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY"):
        if not values.get(key):
            raise SystemExit(f"S3_CONFIG_MISSING {key}")
    values.setdefault("S3_PREFIX", "")
    return values


def signing_key(secret, date, region, service):
    key = hmac.new(("AWS4" + secret).encode("utf-8"), date.encode("utf-8"), hashlib.sha256).digest()
    key = hmac.new(key, region.encode("utf-8"), hashlib.sha256).digest()
    key = hmac.new(key, service.encode("utf-8"), hashlib.sha256).digest()
    return hmac.new(key, b"aws4_request", hashlib.sha256).digest()


def object_key(env, key):
    full = key.strip("/")
    prefix = env.get("S3_PREFIX", "").strip("/")
    if prefix and full != prefix and not full.startswith(prefix + "/"):
        return f"{prefix}/{full}"
    return full


def signed_request(env, method, key, body=b"", content_type="application/octet-stream", now=None):
    endpoint = urllib.parse.urlsplit(env["S3_ENDPOINT"].rstrip("/"))
    if endpoint.scheme not in ("https", "http") or not endpoint.netloc:
        raise SystemExit("S3_ENDPOINT_INVALID")
    uri = urllib.parse.quote(f"/{env['S3_BUCKET']}/{object_key(env, key)}", safe="/")
    moment = now or datetime.now(timezone.utc)
    amz_date = moment.strftime("%Y%m%dT%H%M%SZ")
    day = moment.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(body).hexdigest()
    headers = {
        "host": endpoint.netloc,
        "x-amz-content-sha256": payload_hash,
        "x-amz-date": amz_date,
    }
    if method in ("PUT", "POST"):
        headers["content-type"] = content_type
    signed = sorted(headers)
    canonical = "\n".join(
        [
            method,
            uri,
            "",
            "".join(f"{name}:{headers[name]}\n" for name in signed),
            ";".join(signed),
            payload_hash,
        ]
    )
    scope = f"{day}/{env['S3_REGION']}/s3/aws4_request"
    string_to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256",
            amz_date,
            scope,
            hashlib.sha256(canonical.encode("utf-8")).hexdigest(),
        ]
    )
    signature = hmac.new(
        signing_key(env["S3_SECRET_ACCESS_KEY"], day, env["S3_REGION"], "s3"),
        string_to_sign.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    authorization = (
        f"AWS4-HMAC-SHA256 Credential={env['S3_ACCESS_KEY_ID']}/{scope}, "
        f"SignedHeaders={';'.join(signed)}, Signature={signature}"
    )
    request_headers = {
        "x-amz-content-sha256": payload_hash,
        "x-amz-date": amz_date,
        "Authorization": authorization,
    }
    if method in ("PUT", "POST"):
        request_headers["Content-Type"] = content_type
    url = f"{endpoint.scheme}://{endpoint.netloc}{uri}"
    return url, request_headers, signature


def transmit(env, method, key, body=b""):
    url, headers, _signature = signed_request(env, method, key, body)
    request = urllib.request.Request(url, data=body if method != "GET" else None, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        raise SystemExit(f"S3_HTTP {error.code}") from None


def main(argv):
    if len(argv) == 6 and argv[1] == "signing-key":
        digest = signing_key(argv[2], argv[3], argv[4], argv[5])
        print(digest.hex())
        return
    if len(argv) < 4:
        raise SystemExit("S3_USAGE")
    env = load_env(argv[1])
    action, key = argv[2], argv[3]
    if action == "put":
        status, _body = transmit(env, "PUT", key, Path(argv[4]).read_bytes())
        if status not in (200, 201, 204):
            raise SystemExit(f"S3_HTTP {status}")
        print("UPLOAD_OK")
        return
    if action == "get":
        status, body = transmit(env, "GET", key)
        if status != 200:
            raise SystemExit(f"S3_HTTP {status}")
        Path(argv[4]).write_bytes(body)
        print("DOWNLOAD_OK")
        return
    raise SystemExit("S3_ACTION")


if __name__ == "__main__":
    main(sys.argv)
