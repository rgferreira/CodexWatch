#!/usr/bin/env python3
import argparse
import base64
import datetime
import hashlib
import hmac
import json
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse


def b64url_decode(value):
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def b64url(data):
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


class State:
    def __init__(self, secret):
        self.secret = secret
        self.lock = threading.Lock()
        self.items = {}
        self.nonces = {}


class Handler(BaseHTTPRequestHandler):
    server_version = "CodexWatchMock/1"

    def log_message(self, *_):
        pass

    @property
    def state(self):
        return self.server.state

    def send_json(self, status, value):
        data = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authenticate(self, body):
        timestamp = self.headers.get("X-Transport-Timestamp", "")
        nonce = self.headers.get("X-Transport-Nonce", "")
        digest = self.headers.get("X-Content-Digest", "")
        authorization = self.headers.get("Authorization", "")
        try:
            numeric_timestamp = int(timestamp)
        except ValueError:
            return False
        if abs(int(time.time()) - numeric_timestamp) > 120:
            return False
        expected_digest = b64url(hashlib.sha256(body).digest())
        if not hmac.compare_digest(digest, expected_digest):
            return False
        canonical = (
            f"{self.command}\n{urlparse(self.path).path}\n{timestamp}\n{nonce}\n{digest}"
        ).encode()
        expected = "CW-HMAC " + b64url(hmac.new(
            self.state.secret, canonical, hashlib.sha256
        ).digest())
        if not hmac.compare_digest(authorization, expected):
            return False
        with self.state.lock:
            cutoff = time.time() - 120
            self.state.nonces = {key: value for key, value in self.state.nonces.items() if value > cutoff}
            if nonce in self.state.nonces:
                return False
            self.state.nonces[nonce] = time.time()
        return True

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if not self.authenticate(body):
            self.send_json(401, {"error": "authentication"})
            return
        parts = [part for part in urlparse(self.path).path.split("/") if part]
        if len(parts) < 4 or parts[:2] != ["v1", "pairings"]:
            self.send_json(404, {"error": "not_found"})
            return
        pairing = parts[2]
        if parts[3:] == ["envelopes"]:
            self.put_envelope(pairing, body)
            return
        if parts[3:] == ["claims"]:
            self.claim(pairing, body)
            return
        if len(parts) == 6 and parts[3] == "envelopes" and parts[5] in ("lease", "ack"):
            self.lease_action(pairing, parts[4], parts[5], body)
            return
        self.send_json(404, {"error": "not_found"})

    def put_envelope(self, pairing, body):
        record_id = self.headers.get("Idempotency-Key", "")
        idempotency_digest = self.headers.get("X-Idempotency-Digest", "")
        direction = self.headers.get("X-Direction", "")
        expires_raw = self.headers.get("X-Expires-At", "")
        if len(body) > 70 * 1024:
            self.send_json(413, {"error": "too_large"})
            return
        try:
            expires_at = datetime.datetime.fromisoformat(expires_raw.replace("Z", "+00:00")).timestamp()
        except ValueError:
            self.send_json(400, {"error": "expires"})
            return
        if expires_at <= time.time():
            self.send_json(410, {"error": "expired"})
            return
        key = (pairing, record_id)
        digest = idempotency_digest
        with self.state.lock:
            existing = self.state.items.get(key)
            if existing:
                if digest and hmac.compare_digest(existing["digest"], digest):
                    status = 200
                else:
                    self.send_json(409, {"error": "idempotency_conflict"})
                    return
            else:
                self.state.items[key] = {
                    "body": body,
                    "digest": digest,
                    "direction": direction,
                    "expires": expires_at,
                    "created": time.time(),
                    "lease_token": None,
                    "lease_until": 0,
                }
                status = 201
        self.send_json(status, {"record_id": record_id})

    def claim(self, pairing, body):
        request = json.loads(body or b"{}")
        direction = request.get("direction")
        lease_seconds = min(90, max(5, int(request.get("lease_seconds", 45))))
        limit = min(4, max(1, int(request.get("limit", 1))))
        now = time.time()
        output = []
        with self.state.lock:
            values = sorted(self.state.items.items(), key=lambda value: value[1]["created"])
            for (item_pairing, record_id), item in values:
                if len(output) >= limit:
                    break
                if item_pairing != pairing or item["direction"] != direction:
                    continue
                if item["expires"] <= now or item["lease_until"] > now:
                    continue
                token = secrets.token_urlsafe(24)
                item["lease_token"] = token
                item["lease_until"] = now + lease_seconds
                output.append({
                    "record_id": record_id,
                    "envelope": base64.b64encode(item["body"]).decode(),
                    "lease_token": token,
                    "lease_expires_at": datetime.datetime.fromtimestamp(
                        item["lease_until"], datetime.timezone.utc
                    ).isoformat().replace("+00:00", "Z"),
                })
        self.send_json(200, {"items": output})

    def lease_action(self, pairing, record_id, action, body):
        request = json.loads(body or b"{}")
        token = request.get("lease_token")
        key = (pairing, record_id)
        with self.state.lock:
            item = self.state.items.get(key)
            if not item:
                self.send_json(204, {})
                return
            if not token or not hmac.compare_digest(token, item.get("lease_token") or ""):
                self.send_json(423, {"error": "lease"})
                return
            if action == "ack":
                del self.state.items[key]
            else:
                seconds = min(90, max(5, int(request.get("lease_seconds", 45))))
                item["lease_until"] = time.time() + seconds
        self.send_json(200, {"status": "ok"})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--secret", required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.state = State(b64url_decode(args.secret))
    print(server.server_port, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
