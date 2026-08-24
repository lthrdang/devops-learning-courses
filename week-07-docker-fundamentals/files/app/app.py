#!/usr/bin/env python3
"""A small, deliberately well-behaved containerised service.

"Well-behaved" here means the things a container SHOULD do and most tutorials
skip: fail fast on missing configuration, handle SIGTERM, log to stdout, expose
a real health endpoint, and never assume it can write outside its volume.
"""

from __future__ import annotations

import json
import os
import signal
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# --- configuration: read once, at startup, and FAIL LOUDLY if wrong ---------
# A container that starts half-configured and serves errors is far worse than
# one that refuses to start: the orchestrator can act on a crash, but it cannot
# act on a container that is "up" and quietly wrong.
PORT = int(os.environ.get("PORT", "8000"))
APP_SECRET = os.environ.get("APP_SECRET")
DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
VERSION = os.environ.get("APP_VERSION", "dev")

START = time.monotonic()
READY = False
SHUTTING_DOWN = False


def log(level: str, msg: str, **fields) -> None:
    """Structured logs to stdout. In a container, stdout IS the log file -
    never write to a file inside the container, because nothing collects it."""
    record = {"level": level, "msg": msg, "version": VERSION, **fields}
    print(json.dumps(record), flush=True)      # flush: unbuffered, or logs vanish on crash


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/health":
            # READINESS, not liveness. While shutting down we report 503 so a
            # load balancer drains us BEFORE we stop accepting - week 5.
            if SHUTTING_DOWN:
                self._send(503, {"status": "draining"})
            elif not READY:
                self._send(503, {"status": "starting"})
            else:
                self._send(200, {"status": "ok",
                                 "uptime_s": round(time.monotonic() - START, 1)})

        elif self.path == "/":
            self._send(200, {
                "service": "labapp",
                "version": VERSION,
                "hostname": os.uname().nodename,   # differs per container - shows LB spread
                "pid": os.getpid(),                # should be 1 with the exec form
                "user": f"{os.getuid()}:{os.getgid()}",   # should NOT be 0:0
            })

        elif self.path == "/write":
            try:
                DATA_DIR.mkdir(parents=True, exist_ok=True)
                target = DATA_DIR / "counter"
                n = int(target.read_text()) + 1 if target.exists() else 1
                target.write_text(str(n))
                self._send(200, {"count": n, "path": str(target)})
            except OSError as e:
                # With --read-only this is where you SEE the restriction working.
                log("error", "write failed", error=str(e), path=str(DATA_DIR))
                self._send(500, {"error": str(e)})

        elif self.path == "/burn":
            # Allocate memory until something stops us - for observing cgroup
            # limits and exit code 137.
            chunks = []
            try:
                while True:
                    chunks.append(bytearray(10 * 1024 * 1024))
                    time.sleep(0.05)
            except MemoryError:
                self._send(500, {"error": "MemoryError", "mb": len(chunks) * 10})

        else:
            self._send(404, {"error": "not found", "path": self.path})

    def log_message(self, fmt: str, *args) -> None:
        log("info", "request", detail=fmt % args)


def on_term(signum, frame) -> None:
    """Graceful shutdown.

    This only runs if the process is PID 1 AND receives the signal - which
    requires the Dockerfile to use the EXEC form of CMD/ENTRYPOINT. With the
    shell form, /bin/sh is PID 1, does not forward SIGTERM, and this handler
    never fires; docker stop then SIGKILLs after 10s.
    """
    global SHUTTING_DOWN
    SHUTTING_DOWN = True
    log("info", "SIGTERM received, draining", grace_s=5)
    # Keep serving (returning 503 on /health) long enough for the load balancer
    # to notice and stop sending new work.
    time.sleep(5)
    log("info", "shutdown complete")
    sys.exit(0)


if __name__ == "__main__":
    if not APP_SECRET:
        # Fail fast, loudly, on stderr, with a non-zero exit.
        print("FATAL: APP_SECRET is not set", file=sys.stderr, flush=True)
        sys.exit(1)

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)

    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    log("info", "listening", port=PORT, pid=os.getpid(), uid=os.getuid())
    READY = True
    server.serve_forever()
