"""Tiny echo backend for the Kong POC (stdlib only).

Returns JSON with the leg, component, method, path, query and request headers.
GET <anything>/slow?ms=1500 sleeps before answering (timeout tests).
"""
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

LEG = os.environ.get("LEG", "unknown")
COMPONENT = os.environ.get("COMPONENT", "unknown")
PORT = int(os.environ.get("PORT", "8080"))
MAX_SLOW_MS = 120_000


class Handler(BaseHTTPRequestHandler):
    server_version = "kong-poc-echo"

    def _answer(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path in ("/healthz", "/readyz"):
            return self._send(200, {"status": "ok"})
        if url.path.rstrip("/").endswith("/slow"):
            try:
                ms = min(int(query.get("ms", ["1000"])[0]), MAX_SLOW_MS)
            except ValueError:
                ms = 1000
            time.sleep(ms / 1000)
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        self._send(200, {
            "leg": LEG,
            "service": COMPONENT,
            "pod": os.environ.get("HOSTNAME"),
            "method": self.command,
            "path": url.path,
            "query": {k: v if len(v) > 1 else v[0] for k, v in query.items()},
            "headers": {k.lower(): v for k, v in self.headers.items()},
            "body_bytes": len(body),
        })

    def _send(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.send_header("x-served-by-leg", LEG)
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = _answer

    def log_message(self, fmt, *args):  # keep stdout quiet; Kong logs the traffic
        pass


if __name__ == "__main__":
    ThreadingHTTPServer.daemon_threads = True
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
