"""GSLB-simulator control API (sidecar next to HAProxy, stdlib only).

  GET  /legs                -> state of every leg
  POST /legs/<leg>/drain    -> take the leg out of rotation (no new requests)
  POST /legs/<leg>/ready    -> put it back

Talks to the HAProxy runtime API on 127.0.0.1:9999 (same pod).
State is runtime-only: restarting the pod puts every leg back in rotation.
"""
import json
import re
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BACKEND = "legs"
LEG_RE = re.compile(r"^/legs/([a-z0-9-]+)/(drain|ready)$")


def haproxy(cmd: str) -> str:
    with socket.create_connection(("127.0.0.1", 9999), timeout=3) as s:
        s.sendall((cmd + "\n").encode())
        chunks = []
        while True:
            data = s.recv(65536)
            if not data:
                break
            chunks.append(data)
    return b"".join(chunks).decode()


def legs_state():
    out = haproxy(f"show servers state {BACKEND}")
    lines = [l for l in out.splitlines() if l and not l.startswith("#")]
    result = {}
    for line in lines[1:]:  # first line is the format version
        f = line.split()
        # fields: be_id be_name srv_id srv_name srv_addr srv_op_state srv_admin_state ...
        name, op_state, admin_state = f[3], int(f[5]), int(f[6])
        result[name] = {
            "in_rotation": admin_state == 0,
            "admin_state": admin_state,
            "healthy": op_state == 2,
        }
    return result


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/healthz", "/readyz"):
            return self._send(200, {"status": "ok"})
        if self.path == "/legs":
            return self._send(200, legs_state())
        self._send(404, {"error": "not found"})

    def do_POST(self):
        m = LEG_RE.match(self.path)
        if not m:
            return self._send(404, {"error": "not found"})
        leg, action = m.groups()
        state = legs_state()
        if leg not in state:
            return self._send(404, {"error": f"unknown leg {leg}"})
        # "maint" = like removing the leg from the GSLB: no new requests at all
        haproxy(f"set server {BACKEND}/{leg} state {'maint' if action == 'drain' else 'ready'}")
        self._send(200, {leg: legs_state()[leg]})

    def log_message(self, fmt, *args):
        print("control:", fmt % args, flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8081), Handler).serve_forever()
