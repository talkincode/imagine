#!/usr/bin/env python3
"""Test double for the provider HTTP surfaces `imagine` speaks.

This stands in for Volcengine Ark and Google Gemini so `scripts/e2e.sh` can
exercise the real client path — create, poll, download, file writes, `--json`
output — without a network or a credential. It implements the documented wire
formats; it deliberately does not validate them. Its job is to test *imagine*,
not the providers, so if a provider changes its API only the real API will say
so.

Usage: mock_providers.py [port] [logfile]
Prints the port it bound to on stdout, then serves until killed.

Routes
------
POST /api/v3/contents/generations/tasks            -> {"id": "cgt-mock-1"}   (Seedance)
GET  /api/v3/contents/generations/tasks/cgt-mock-1 -> running, then succeeded + content.video_url
POST /fail/contents/generations/tasks              -> task that always fails
POST /slow/contents/generations/tasks              -> task that never finishes
POST /api/v3/images/generations                    -> {"data": [{"url": ...}]}  (Seedream)
POST /v1beta/interactions                          -> interaction with a Files uri (Omni)
POST /array-error/interactions                     -> 400 with an array-wrapped error
GET  /v1beta/files/mockfile                        -> PROCESSING, then ACTIVE
GET  /v1beta/files/mockfile:download?alt=media      -> video bytes
GET  /cdn/*                                        -> asset bytes (no auth needed)
"""

import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SEEDANCE_MP4 = b"SEEDANCE-MP4-BYTES"
SEEDREAM_PNG = b"SEEDREAM-PNG-BYTES"
OMNI_MP4 = b"GEMINI-OMNI-MP4-BYTES"
PNG_MAGIC = b"\x89PNG\r\n\x1a\n" + b"0" * 32

LOG = None
POLLS = {}
LOCK = threading.Lock()


def poll_count(key):
    """First poll reports in-progress, the second reports done."""
    with LOCK:
        POLLS[key] = POLLS.get(key, 0) + 1
        return POLLS[key]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # keep the test output readable
        pass

    def record(self, body):
        if not LOG:
            return
        with open(LOG, "a") as f:
            f.write(json.dumps({
                "method": self.command,
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "goog_api_key": self.headers.get("x-goog-api-key"),
                "content_type": self.headers.get("Content-Type"),
                "body": body.decode() if body else None,
            }) + "\n")

    def send(self, code, payload, ctype="application/json"):
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def host(self):
        return self.headers.get("Host")

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        self.record(body)
        if self.path == "/api/v3/contents/generations/tasks":
            return self.send(200, {"id": "cgt-mock-1"})
        if self.path == "/fail/contents/generations/tasks":
            return self.send(200, {"id": "cgt-fail"})
        if self.path == "/slow/contents/generations/tasks":
            return self.send(200, {"id": "cgt-slow"})
        if self.path == "/api/v3/images/generations":
            return self.send(200, {
                "model": "mock", "created": 1,
                "data": [{"url": f"http://{self.host()}/cdn/seedream.png"}],
            })
        if self.path == "/array-error/interactions":
            # Google wraps some errors in a one-element array.
            return self.send(400, [{"error": {"code": 400, "message": "API key not valid."}}])
        if self.path == "/v1beta/interactions":
            return self.send(200, {
                "id": "v1_mock", "object": "interaction", "status": "completed",
                "steps": [{"type": "model_output", "content": [{
                    "type": "video", "mime_type": "video/mp4",
                    "uri": f"http://{self.host()}/v1beta/files/mockfile:download?alt=media",
                }]}],
            })
        return self.send(404, {"error": {"code": "not_found", "message": self.path}})

    def do_GET(self):
        self.record(None)
        if self.path == "/api/v3/contents/generations/tasks/cgt-mock-1":
            if poll_count("ark") < 2:
                return self.send(200, {"id": "cgt-mock-1", "status": "running"})
            return self.send(200, {
                "id": "cgt-mock-1", "status": "succeeded",
                "content": {"video_url": f"http://{self.host()}/cdn/seedance.mp4"},
            })
        if self.path == "/fail/contents/generations/tasks/cgt-fail":
            # Providers report a failed task as HTTP 200 with a failure status.
            return self.send(200, {
                "id": "cgt-fail", "status": "failed",
                "error": {"code": "OutputVideoSensitiveContentDetected",
                          "message": "output video may contain sensitive information"},
            })
        if self.path == "/slow/contents/generations/tasks/cgt-slow":
            return self.send(200, {"id": "cgt-slow", "status": "running"})
        if self.path == "/v1beta/files/mockfile":
            if poll_count("gemini") < 2:
                return self.send(200, {"name": "files/mockfile", "state": "PROCESSING"})
            return self.send(200, {"name": "files/mockfile", "state": "ACTIVE",
                                   "mime_type": "video/mp4"})
        if self.path.startswith("/v1beta/files/mockfile:download"):
            return self.send(200, OMNI_MP4, "video/mp4")
        if self.path == "/cdn/seedance.mp4":
            return self.send(200, SEEDANCE_MP4, "video/mp4")
        if self.path == "/cdn/seedream.png":
            return self.send(200, SEEDREAM_PNG, "image/png")
        if self.path == "/cdn/first-frame":
            # A real image with no filename extension, so the client has to
            # sniff the type from the bytes.
            return self.send(200, PNG_MAGIC, "application/octet-stream")
        return self.send(404, {"error": {"code": "not_found", "message": self.path}})


def main():
    global LOG
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    LOG = sys.argv[2] if len(sys.argv) > 2 else None
    if LOG:
        open(LOG, "w").close()
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
