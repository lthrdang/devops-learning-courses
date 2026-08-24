#!/usr/bin/env python3
"""An HTTP service instrumented with Prometheus metrics, using no dependencies.

Written against the raw exposition format on purpose. In a real project you
would use prometheus_client; the point here is that you understand what that
library EMITS, because when a metric looks wrong you will be reading this text
format in a browser, not reading library source.

  python3 metered.py --port 8000
  curl localhost:8000/metrics
"""

from __future__ import annotations

import argparse
import json
import math
import random
import threading
import time
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# --- metric storage --------------------------------------------------------
LOCK = threading.Lock()

# A COUNTER only ever goes up (and resets to 0 on restart). The raw value is
# meaningless; rate() over it is the signal. That is why Prometheus insists on
# the distinction.
counters: dict[tuple, float] = defaultdict(float)

# A HISTOGRAM is a set of cumulative buckets. It exists so that percentiles can
# be computed ACROSS instances - you cannot average p99s from three servers and
# get the fleet p99, but you CAN sum their bucket counts and derive it.
LATENCY_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]
hist_buckets: dict[tuple, list[int]] = {}
hist_sum: dict[tuple, float] = defaultdict(float)
hist_count: dict[tuple, int] = defaultdict(int)

# A GAUGE goes up and down.
gauges: dict[tuple, float] = defaultdict(float)

START = time.time()


def _key(labels: dict) -> tuple:
    return tuple(sorted(labels.items()))


def inc(name: str, labels: dict, value: float = 1.0) -> None:
    with LOCK:
        counters[(name, _key(labels))] += value


def observe(name: str, labels: dict, value: float) -> None:
    k = (name, _key(labels))
    with LOCK:
        if k not in hist_buckets:
            hist_buckets[k] = [0] * len(LATENCY_BUCKETS)
        for i, bound in enumerate(LATENCY_BUCKETS):
            if value <= bound:
                hist_buckets[k][i] += 1
        hist_sum[k] += value
        hist_count[k] += 1


def set_gauge(name: str, labels: dict, value: float) -> None:
    with LOCK:
        gauges[(name, _key(labels))] = value


def _fmt_labels(label_tuple: tuple, extra: str = "") -> str:
    parts = [f'{k}="{v}"' for k, v in label_tuple]
    if extra:
        parts.append(extra)
    return "{" + ",".join(parts) + "}" if parts else ""


def render_metrics() -> str:
    """Emit the Prometheus text exposition format.

    Every metric needs # HELP and # TYPE. Without # TYPE, Prometheus treats it
    as untyped and tooling cannot tell you that rate() on it is wrong.
    """
    out: list[str] = []
    with LOCK:
        out.append("# HELP http_requests_total Total HTTP requests.")
        out.append("# TYPE http_requests_total counter")
        for (name, lbls), v in sorted(counters.items()):
            if name == "http_requests_total":
                out.append(f"http_requests_total{_fmt_labels(lbls)} {v:g}")

        out.append("# HELP http_request_duration_seconds Request latency.")
        out.append("# TYPE http_request_duration_seconds histogram")
        for (name, lbls), buckets in sorted(hist_buckets.items()):
            for bound, count in zip(LATENCY_BUCKETS, buckets):
                out.append(
                    f'http_request_duration_seconds_bucket{_fmt_labels(lbls, f"le=\"{bound}\"")} {count}'
                )
            # The +Inf bucket is MANDATORY and equals the total count.
            # histogram_quantile() returns NaN without it - a classic source of
            # "my latency panel is empty and I do not know why".
            out.append(
                f'http_request_duration_seconds_bucket{_fmt_labels(lbls, "le=\"+Inf\"")} {hist_count[(name, lbls)]}'
            )
            out.append(f"http_request_duration_seconds_sum{_fmt_labels(lbls)} {hist_sum[(name, lbls)]:g}")
            out.append(f"http_request_duration_seconds_count{_fmt_labels(lbls)} {hist_count[(name, lbls)]}")

        out.append("# HELP app_uptime_seconds Seconds since start.")
        out.append("# TYPE app_uptime_seconds gauge")
        out.append(f"app_uptime_seconds {time.time() - START:g}")

        out.append("# HELP app_in_flight_requests Requests currently being served.")
        out.append("# TYPE app_in_flight_requests gauge")
        for (name, lbls), v in sorted(gauges.items()):
            if name == "app_in_flight_requests":
                out.append(f"app_in_flight_requests{_fmt_labels(lbls)} {v:g}")

    return "\n".join(out) + "\n"


# --- the service -----------------------------------------------------------
IN_FLIGHT = 0


def route_of(path: str) -> str:
    """Normalise a path into a bounded set of ROUTE TEMPLATES.

    THIS FUNCTION IS THE MOST IMPORTANT THING IN THE FILE.

    Using the raw path as a label creates one time series per distinct URL. A
    scanner hitting /a, /b, /c... or an endpoint like /items/12345 produces
    unbounded cardinality, and Prometheus dies - taking your monitoring down at
    exactly the moment you need it. Always label with the TEMPLATE.
    """
    if path.startswith("/items/"):
        return "/items/:id"
    if path in ("/", "/health", "/metrics", "/items", "/slow", "/flaky", "/leak"):
        return path
    return "/other"          # everything unknown collapses to ONE series


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code: int, body: bytes, ctype: str = "application/json") -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        global IN_FLIGHT
        started = time.monotonic()
        route = route_of(self.path.split("?")[0])
        status = 200

        with LOCK:
            IN_FLIGHT += 1
        set_gauge("app_in_flight_requests", {}, IN_FLIGHT)

        try:
            if self.path.startswith("/metrics"):
                return self._send(200, render_metrics().encode(), "text/plain; version=0.0.4")

            if self.path.startswith("/health"):
                return self._send(200, b'{"status":"ok"}')

            if self.path.startswith("/slow"):
                # A LOG-NORMAL delay: most requests fast, a long tail. This is
                # what real latency looks like, and it is why p99 matters and
                # the average lies.
                time.sleep(min(8.0, random.lognormvariate(-2.0, 1.3)))
                return self._send(200, b'{"ok":true}')

            if self.path.startswith("/flaky"):
                if random.random() < 0.15:
                    status = 500
                    return self._send(500, b'{"error":"deliberate"}')
                return self._send(200, b'{"ok":true}')

            if self.path.startswith("/leak"):
                LEAKED.append(bytearray(1024 * 1024))
                return self._send(200, json.dumps({"leaked_mb": len(LEAKED)}).encode())

            if self.path.startswith("/items"):
                time.sleep(random.uniform(0.005, 0.05))
                return self._send(200, b'{"items":[1,2,3]}')

            if self.path == "/":
                return self._send(200, json.dumps({
                    "service": "metered", "uptime_s": round(time.time() - START, 1)
                }).encode())

            status = 404
            self._send(404, b'{"error":"not found"}')

        finally:
            elapsed = time.monotonic() - started
            labels = {"method": "GET", "route": route, "status": str(status)}
            inc("http_requests_total", labels)
            # NOTE: the histogram is labelled WITHOUT status. Including it would
            # multiply the series count by the number of status codes for no
            # analytical gain - you almost always want latency across all
            # outcomes. Histograms are already ~13 series each; be frugal.
            observe("http_request_duration_seconds", {"method": "GET", "route": route}, elapsed)
            with LOCK:
                IN_FLIGHT -= 1
            set_gauge("app_in_flight_requests", {}, IN_FLIGHT)

    def log_message(self, fmt: str, *a) -> None:
        print(json.dumps({"level": "info", "svc": "metered", "msg": fmt % a}), flush=True)


LEAKED: list = []

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=8000)
    args = p.parse_args()
    print(json.dumps({"level": "info", "svc": "metered", "msg": f"listening on {args.port}"}), flush=True)
    ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()
