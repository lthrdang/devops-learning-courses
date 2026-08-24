#!/usr/bin/env python3
"""Stack API: demonstrates dependency handling done correctly.

The interesting code here is NOT the endpoints - it is connect_with_retry() and
the way a missing cache degrades instead of failing. Those two decisions are the
difference between a stack that survives a dependency blip and one that does not.
"""

from __future__ import annotations

import json
import os
import socket
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = os.environ.get("APP_VERSION", "1.0")
PORT = int(os.environ.get("PORT", "8000"))
DB_HOST = os.environ.get("DB_HOST", "db")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
REDIS_HOST = os.environ.get("REDIS_HOST", "cache")
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6379"))

# The _FILE convention: prefer a mounted secret file over an env var, because
# env vars are readable via `docker inspect` and often end up in logs.
def _secret(name: str, default: str | None = None) -> str | None:
    path = os.environ.get(f"{name}_FILE")
    if path and os.path.exists(path):
        return open(path).read().strip()
    return os.environ.get(name, default)

DB_PASSWORD = _secret("DB_PASSWORD")
DB_USER = os.environ.get("DB_USER", "postgres")
DB_NAME = os.environ.get("DB_NAME", "appdb")

START = time.monotonic()
STATE = {"db": False, "cache": False, "requests": 0, "cache_hits": 0}


def log(level: str, msg: str, **fields) -> None:
    print(json.dumps({"level": level, "msg": msg, "svc": "api", **fields}), flush=True)


# ---------------------------------------------------------------------------
def tcp_probe(host: str, port: int, timeout: float = 2.0) -> bool:
    """Cheapest possible readiness probe: can we open a TCP connection?

    Deliberately NOT a full protocol handshake - this keeps the dependency in
    stdlib-only territory so the lab needs no pip install. A real service would
    use psycopg/redis-py; the RETRY LOGIC below is identical either way.
    """
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def connect_with_retry(host: str, port: int, name: str,
                       attempts: int = 30, cap: float = 10.0) -> bool:
    """Retry with exponential backoff, capped.

    WHY THIS EXISTS EVEN THOUGH COMPOSE HAS condition: service_healthy:
    that condition only governs STARTUP. In production the database will restart
    or fail over at 3am while this process has been running for a month, and
    nothing will restart us to help. An application that cannot reconnect to its
    dependencies is broken no matter how carefully it was started.
    """
    delay = 0.5
    for attempt in range(attempts):
        if tcp_probe(host, port):
            log("info", f"{name} reachable", host=host, port=port, attempt=attempt + 1)
            return True
        log("warn", f"{name} not reachable, retrying",
            host=host, port=port, attempt=attempt + 1, delay=round(delay, 2))
        time.sleep(delay)
        delay = min(cap, delay * 2)
    return False


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
        # Re-probe live, so the health endpoint reflects reality rather than
        # what was true at startup.
        STATE["db"] = tcp_probe(DB_HOST, DB_PORT, timeout=1.0)
        STATE["cache"] = tcp_probe(REDIS_HOST, REDIS_PORT, timeout=1.0)

        if self.path == "/health":
            # READINESS. Postgres is required; Redis is a cache we survive
            # without - so its absence is "degraded", not "down". Week 5 §4.3.
            if not STATE["db"]:
                return self._send(503, {"status": "unhealthy", "reason": "database unreachable"})
            return self._send(200, {
                "status": "ok" if STATE["cache"] else "degraded",
                "db": True, "cache": STATE["cache"],
                "uptime_s": round(time.monotonic() - START, 1),
            })

        if self.path == "/ready":
            return self._send(200 if STATE["db"] else 503, {"db": STATE["db"]})

        if self.path == "/items":
            if not STATE["db"]:
                # A 503 with an honest reason, not a 500. The distinction
                # matters: 500 says "I have a bug", 503 says "my dependency is
                # down, try again" - and only one of those pages a developer.
                return self._send(503, {"error": "database unavailable",
                                        "hint": "check `docker compose logs db`"})
            STATE["requests"] += 1
            if STATE["cache"]:
                STATE["cache_hits"] += 1
            return self._send(200, {
                "items": [{"id": 1, "name": "widget"}, {"id": 2, "name": "gadget"}],
                "served_by": socket.gethostname(),
                "cached": STATE["cache"],
                "version": VERSION,
            })

        if self.path == "/":
            return self._send(200, {
                "service": "api", "version": VERSION,
                "hostname": socket.gethostname(),
                "db_host": DB_HOST, "cache_host": REDIS_HOST,
                "db_password_configured": bool(DB_PASSWORD),   # never the VALUE
                "state": STATE,
            })

        self._send(404, {"error": "not found", "path": self.path})

    def log_message(self, fmt: str, *a) -> None:
        log("info", "request", detail=fmt % a)


if __name__ == "__main__":
    if not DB_PASSWORD:
        print("FATAL: DB_PASSWORD (or DB_PASSWORD_FILE) is not set", file=sys.stderr, flush=True)
        sys.exit(1)

    log("info", "starting", version=VERSION, db=f"{DB_HOST}:{DB_PORT}",
        cache=f"{REDIS_HOST}:{REDIS_PORT}")

    if not connect_with_retry(DB_HOST, DB_PORT, "database"):
        print("FATAL: database never became reachable", file=sys.stderr, flush=True)
        sys.exit(1)
    connect_with_retry(REDIS_HOST, REDIS_PORT, "cache", attempts=5)   # optional

    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
