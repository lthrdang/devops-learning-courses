#!/usr/bin/env python3
"""
backend.py - a controllable HTTP backend for load-balancing experiments.

  python3 backend.py --port 9001 --name app1

Endpoints:
  /            identify which backend answered  (this is how you SEE balancing)
  /health      readiness - can be toggled off, to watch the LB react
  /slow?s=3    sleep, to trigger proxy_read_timeout -> 504
  /error       return 500, to distinguish an APP error from a PROXY error
  /kill        stop responding entirely, to trigger 502
  /toggle      flip health on/off at runtime
"""
import argparse, json, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

STATE = {"healthy": True, "requests": 0, "dead": False}
LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"          # enables keep-alive

    def _json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)

        if STATE["dead"]:
            # Accept the connection and then say nothing. From the proxy's point
            # of view this is indistinguishable from a hung application, which
            # is exactly the scenario we want to be able to recognise.
            time.sleep(300)
            return

        with LOCK:
            STATE["requests"] += 1
            n = STATE["requests"]

        if u.path == "/health":
            if STATE["healthy"]:
                self._json(200, {"status": "ok", "backend": ARGS.name})
            else:
                self._json(503, {"status": "draining", "backend": ARGS.name})

        elif u.path == "/toggle":
            STATE["healthy"] = not STATE["healthy"]
            self._json(200, {"healthy": STATE["healthy"], "backend": ARGS.name})

        elif u.path == "/kill":
            STATE["dead"] = True
            self._json(200, {"dead": True, "backend": ARGS.name})

        elif u.path == "/slow":
            time.sleep(float(q.get("s", ["3"])[0]))
            self._json(200, {"backend": ARGS.name, "slept": q.get("s", ["3"])[0]})

        elif u.path == "/error":
            # A 500 from the APPLICATION. Contrast with a 502 from the PROXY -
            # telling these apart from the client side is the week's core skill.
            self._json(500, {"error": "deliberate application error",
                             "backend": ARGS.name})

        else:
            self._json(200, {
                "backend": ARGS.name,
                "port": ARGS.port,
                "request_number": n,
                "pid": os.getpid(),
                # Echo the forwarding headers so you can SEE whether the proxy
                # set them. If x_forwarded_for is null, the proxy config is wrong.
                "host_header": self.headers.get("Host"),
                "x_forwarded_for": self.headers.get("X-Forwarded-For"),
                "x_forwarded_proto": self.headers.get("X-Forwarded-Proto"),
            })

    def log_message(self, fmt, *a):
        sys.stderr.write("%s %s - %s\n" % (ARGS.name, self.address_string(), fmt % a))


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=9001)
    p.add_argument("--name", default="app1")
    p.add_argument("--bind", default="0.0.0.0")
    ARGS = p.parse_args()
    srv = ThreadingHTTPServer((ARGS.bind, ARGS.port), Handler)
    print(f"{ARGS.name} listening on {ARGS.bind}:{ARGS.port}", file=sys.stderr)
    srv.serve_forever()
