#!/usr/bin/env python3
"""JoshDrive (Immich fork) telemetry collector.

The phone app POSTs its own log lines here. A post is accepted only if its Immich access token is
valid on the local Immich server, so only accounts on Josh's server can send. Stored as JSON lines
per day in ~/immich/telemetry, kept 30 days. Listens on 127.0.0.1 only; tailscale serve exposes it
to the tailnet (not the internet).
"""
import hashlib
import json
import os
import time
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = 8461
IMMICH = "http://127.0.0.1:2283/api/users/me"
DIR = Path.home() / "immich" / "telemetry"
MAX_BODY = 2 * 1024 * 1024
KEEP_DAYS = 30
_tokens = {}  # sha256(token) -> (email, checked_at)


def owner(token):
    key = hashlib.sha256(token.encode()).hexdigest()
    hit = _tokens.get(key)
    if hit and time.time() - hit[1] < 3600:
        return hit[0]
    req = urllib.request.Request(IMMICH, headers={"x-immich-user-token": token, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            email = json.load(r).get("email", "?")
    except Exception:
        return None
    _tokens[key] = (email, time.time())
    return email


def prune():
    cutoff = time.time() - KEEP_DAYS * 86400
    for f in DIR.glob("*.jsonl"):
        if f.stat().st_mtime < cutoff:
            f.unlink()


class Handler(BaseHTTPRequestHandler):
    def _reply(self, code, text):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        """Remote config for JoshDrive apps (edit ~/immich/gateway/config.json; applied on next fetch)."""
        if self.path != "/jd-config":
            return self._reply(404, "not found")
        token = self.headers.get("x-immich-user-token", "")
        if not (token and owner(token)):
            return self._reply(401, "unknown user")
        try:
            body = (Path.home() / "immich" / "gateway" / "config.json").read_text()
        except OSError:
            body = "{}"
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path == "/register-device":
            return self.register()
        if self.path != "/telemetry":
            return self._reply(404, "not found")
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY:
            return self._reply(413, "bad size")
        token = self.headers.get("x-immich-user-token", "")
        email = owner(token) if token else None
        if not email:
            return self._reply(401, "unknown user")
        try:
            payload = json.loads(self.rfile.read(length))
        except ValueError:
            return self._reply(400, "bad json")
        now = datetime.now(timezone.utc)
        DIR.mkdir(parents=True, exist_ok=True)
        with open(DIR / f"{now:%Y-%m-%d}.jsonl", "a") as out:
            out.write(json.dumps({"receivedAt": now.isoformat(), "user": email, **payload}) + "\n")
        prune()
        self._reply(200, "ok")

    def register(self):
        """A logged-in JoshDrive app registers its tunnel device key (only reachable over Tailscale)."""
        token = self.headers.get("x-immich-user-token", "")
        email = owner(token) if token else None
        if not email:
            return self._reply(401, "unknown user")
        try:
            pk = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length") or 0), 4096)))["devicePk"]
            bytes.fromhex(pk)
            assert len(pk) == 64
        except Exception:
            return self._reply(400, "bad key")
        devices = Path.home() / "immich" / "gateway" / "devices.json"
        devices.parent.mkdir(parents=True, exist_ok=True)
        try:
            known = json.loads(devices.read_text())
        except (OSError, ValueError):
            known = {}
        if pk not in known:
            known[pk] = {"user": email, "addedAt": datetime.now(timezone.utc).isoformat()}
            tmp = devices.with_suffix(".tmp"); tmp.write_text(json.dumps(known, indent=2)); tmp.replace(devices)
        self._reply(200, "ok")

    def log_message(self, fmt, *args):  # keep journald quiet; the data is in the jsonl files
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
