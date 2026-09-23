#!/usr/bin/env python3
"""Reference HTTP service for the `ltx2_video` backend (self-hosted LTX-2).

`imagine` never runs a model: it speaks HTTP to a local service that owns the
weights and the inference runtime (MLX, PyTorch, or a vendor CLI). This file is
that service's reference implementation and the executable form of the contract
documented in `integrations/ltx2/README.md`:

    POST /v1/videos/generations
    {
      "model": "ltx-2",
      "prompt": "a lawyer speaking to camera",
      "duration": 6,                     # seconds, optional
      "resolution": "720p",              # optional
      "ratio": "16:9",                   # optional
      "seed": 17,                        # optional
      "image": {                         # optional first frame (image-to-video)
        "mime_type": "image/png",
        "data": "<base64>"
      }
    }
    -> 202 { "id": "ltx-<n>" }

    GET  /v1/videos/generations/<id>
    -> { "id": ..., "status": "running" | "succeeded" | "failed",
         "video_url": "<http url>",       # only when succeeded
         "error": { "message": ... } }    # only when failed

    GET  /v1/videos/<id>/content            -> the MP4 bytes
    GET  /healthz                           -> liveness + the commands in use

Errors use `{"error": {"message": ...}}`, which `imagine` reports verbatim.

Inference itself is a command you supply, so this adapter fits any local
runtime (including a CLI like `ltxgen`); see --t2v-cmd/--i2v-cmd below.

Usage:  python3 server.py [options]      (see --help)
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import shlex
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MOCK_BYTES = b"LTX2-MOCK-MP4-BYTES"

# Placeholders available to --t2v-cmd / --i2v-cmd. The template is split into
# argv words here and handed to the runtime without a shell, so a prompt with
# spaces, quotes or `$` arrives intact.
PLACEHOLDERS = ("prompt", "image", "duration", "resolution", "ratio", "seed", "output")

DEFAULT_T2V_CMD = "ltxgen t2v {prompt} --duration {duration} --output {output}"
DEFAULT_I2V_CMD = "ltxgen i2v {image} {prompt} --duration {duration} --output {output}"


class Jobs:
    """In-memory task table. Jobs are lost on restart, which is fine: `imagine`
    polls a task it just created and never resumes one across runs."""

    def __init__(self, t2v_cmd: str, i2v_cmd: str, mock: bool, jobs: int):
        self.t2v_cmd = t2v_cmd
        self.i2v_cmd = i2v_cmd
        self.mock = mock
        # Denoising saturates the device, so run one job at a time by default;
        # raise it only for a runtime that can share the GPU.
        self.semaphore = threading.Semaphore(max(1, jobs))
        self.lock = threading.Lock()
        self.table: dict[str, dict] = {}
        self.counter = 0
        self.workdir = tempfile.mkdtemp(prefix="ltx2-service-")

    def create(self, request: dict) -> str:
        with self.lock:
            self.counter += 1
            job_id = f"ltx-{self.counter}"
        job = {"id": job_id, "status": "running", "video_url": None, "error": None}
        with self.lock:
            self.table[job_id] = job
        threading.Thread(target=self._run, args=(job, request), daemon=True).start()
        return job_id

    def get(self, job_id: str) -> dict | None:
        with self.lock:
            return self.table.get(job_id)

    def content_path(self, job_id: str) -> str:
        return os.path.join(self.workdir, f"{job_id}.mp4")

    def _run(self, job: dict, request: dict) -> None:
        job_id = job["id"]
        output = self.content_path(job_id)
        image_path = None
        try:
            argv, image_path = self._argv(job_id, request, output)
            with self.semaphore:
                if self.mock:
                    time.sleep(0.2)  # a real run takes minutes; keep polls honest
                    with open(output, "wb") as f:
                        f.write(MOCK_BYTES)
                else:
                    proc = subprocess.run(argv, capture_output=True, text=True)
                    if proc.returncode != 0:
                        raise RuntimeError(
                            (proc.stderr or proc.stdout or "").strip()[-500:]
                            or f"command exited {proc.returncode}"
                        )
            if not os.path.exists(output) or os.path.getsize(output) == 0:
                raise RuntimeError(f"command produced no video at {output}")
            with self.lock:
                job["status"] = "succeeded"
                job["video_url"] = f"/v1/videos/{job_id}/content"
        except Exception as exc:  # surfaced to the client as a task error
            with self.lock:
                job["status"] = "failed"
                job["error"] = {"message": str(exc)}
        finally:
            if image_path:
                try:
                    os.unlink(image_path)
                except OSError:
                    pass

    def _argv(self, job_id: str, request: dict, output: str) -> tuple[list[str], str | None]:
        """Command to run, plus the temporary first-frame file it was written to.

        A request with an `image` is an image-to-video job (`--i2v-cmd`); without
        one it is text-to-video (`--t2v-cmd`). Empty placeholders drop their own
        argument, so an omitted `--duration` does not reach the runtime as `''`.
        """
        image = request.get("image")
        image_path = None
        if image:
            image_path = os.path.join(self.workdir, f"{job_id}-first-frame")
            with open(image_path, "wb") as f:
                f.write(base64.b64decode(image["data"]))
        values = {
            "prompt": str(request.get("prompt", "")),
            "image": image_path or "",
            "duration": str(request.get("duration") or ""),
            "resolution": str(request.get("resolution") or ""),
            "ratio": str(request.get("ratio") or ""),
            "seed": "" if request.get("seed") is None else str(request["seed"]),
            "output": output,
        }
        argv: list[str] = []
        for part in shlex.split(self.i2v_cmd if image_path else self.t2v_cmd):
            rendered = part.format(**values)
            if rendered:
                argv.append(rendered)
        return argv, image_path


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    jobs: Jobs = None  # set in main()

    def log_message(self, *args):
        pass

    def send(self, code, payload, ctype="application/json"):
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_error_json(self, code, message):
        self.send(code, {"error": {"message": message}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        if self.path != "/v1/videos/generations":
            return self.send_error_json(404, f"no route for {self.path}")
        try:
            request = json.loads(raw or b"{}")
        except json.JSONDecodeError as exc:
            return self.send_error_json(400, f"invalid JSON body: {exc}")
        if not request.get("prompt"):
            return self.send_error_json(400, "prompt is required")
        job_id = self.jobs.create(request)
        self.send(202, {"id": job_id})

    def do_GET(self):
        if self.path == "/healthz":
            return self.send(200, {
                "status": "ok",
                "mock": self.jobs.mock,
                "t2v_cmd": self.jobs.t2v_cmd,
                "i2v_cmd": self.jobs.i2v_cmd,
            })
        if self.path.startswith("/v1/videos/generations/"):
            job_id = self.path.rsplit("/", 1)[-1]
            job = self.jobs.get(job_id)
            if job is None:
                return self.send_error_json(404, f"unknown task {job_id}")
            payload = {"id": job["id"], "status": job["status"]}
            if job["status"] == "succeeded":
                payload["video_url"] = f"http://{self.headers.get('Host')}{job['video_url']}"
            elif job["status"] == "failed":
                payload["error"] = job["error"] or {"message": "generation failed"}
            return self.send(200, payload)
        if self.path.startswith("/v1/videos/") and self.path.endswith("/content"):
            job_id = self.path.split("/")[3]
            job = self.jobs.get(job_id)
            if job is None or job["status"] != "succeeded":
                return self.send_error_json(404, f"no video for task {job_id}")
            with open(self.jobs.content_path(job_id), "rb") as f:
                return self.send(200, f.read(), "video/mp4")
        return self.send_error_json(404, f"no route for {self.path}")


def main():
    parser = argparse.ArgumentParser(description="Reference service for imagine's ltx2_video backend")
    parser.add_argument("--port", type=int, default=8100, help="listen port (default 8100)")
    parser.add_argument("--host", default="127.0.0.1", help="listen address (default 127.0.0.1)")
    parser.add_argument("--t2v-cmd", default=DEFAULT_T2V_CMD,
                        help="text-to-video command template (default: %(default)s)")
    parser.add_argument("--i2v-cmd", default=DEFAULT_I2V_CMD,
                        help="image-to-video command template (default: %(default)s)")
    parser.add_argument("--jobs", type=int, default=1, help="concurrent generations (default 1)")
    parser.add_argument("--mock", action="store_true",
                        help="write placeholder bytes instead of running a command")
    args = parser.parse_args()

    print("placeholders available to the command templates: " + ", ".join(PLACEHOLDERS), flush=True)
    Handler.jobs = Jobs(args.t2v_cmd, args.i2v_cmd, args.mock, args.jobs)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"ltx2 service on http://{args.host}:{server.server_address[1]} (mock={args.mock})", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
