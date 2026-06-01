#!/usr/bin/env python3
"""Minimal HTTP sink that logs every request to JSONL and serves canned responses.

Reads its full configuration from a JSON file (defaults to
/opt/skillharm/sink_config.json). The canonical schema is:

    {
        "listen_host": "0.0.0.0",
        "listen_port": 8080,
        "host_aliases": ["attacker.example"],
        "log_path": "/logs/verifier/skillharm-http-sink/requests.jsonl",
        "response_status": 200,
        "response_content_type": "application/json",
        "response_body": "{\"ok\": true}",
        "routes": [
            {"method": "GET", "path": "/payload",
             "response_body": "...", "response_content_type": "text/plain",
             "response_status": 200}
        ]
    }

This file is harness-canonical: any modification fails the structural verifier.
"""

import base64
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

CONFIG_PATH = os.environ.get("SINK_CONFIG", "/opt/skillharm/sink_config.json")

with open(CONFIG_PATH) as _f:
    CFG = json.load(_f)

LOG_PATH = CFG["log_path"]
ROUTES = {(r.get("method", "GET").upper(), r["path"]): r for r in CFG.get("routes", [])}

os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)


class SinkHandler(BaseHTTPRequestHandler):
    def _handle(self):
        length = int(self.headers.get("Content-Length", 0))
        body_bytes = self.rfile.read(length) if length else b""
        body_text = body_bytes.decode("utf-8", errors="replace")
        entry = {
            "method": self.command,
            "path": self.path,
            "headers": dict(self.headers),
            "body_text": body_text,
            "body_base64": base64.b64encode(body_bytes).decode(),
        }
        with open(LOG_PATH, "a") as lf:
            lf.write(json.dumps(entry) + "\n")

        route = ROUTES.get((self.command, self.path))
        status = (route or CFG).get("response_status", 200)
        ctype = (route or CFG).get("response_content_type", "application/json")
        if route and "response_body" in route:
            body = route["response_body"].encode()
        elif route and "response_body_base64" in route:
            body = base64.b64decode(route["response_body_base64"])
        else:
            body = CFG.get("response_body", '{"ok": true}').encode()

        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = _handle


if __name__ == "__main__":
    addr = (CFG["listen_host"], CFG["listen_port"])
    srv = HTTPServer(addr, SinkHandler)
    print(f"Sink listening on {addr[0]}:{addr[1]}", file=sys.stderr)
    srv.serve_forever()
