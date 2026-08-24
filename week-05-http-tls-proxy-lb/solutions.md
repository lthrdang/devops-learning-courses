# Week 05 — Solutions & discussion

---

## C5.6 — The 502 taxonomy (do this one first)

| # | Root cause | `error.log` says | Distinguishing command | Fix |
|---|---|---|---|---|
| 1 | Nothing listening on the upstream port | `connect() failed (111: Connection refused) while connecting to upstream` | `ss -tlnp \| grep <port>` — empty | start the backend, or correct `proxy_pass` |
| 2 | Backend bound to `127.0.0.1`, proxy on another host | same `111` | `ss -tlnp` shows `127.0.0.1:8080` not `0.0.0.0:8080` | change the bind address |
| 3 | Firewall dropping proxy→backend | `upstream timed out (110: Connection timed out)` | `nft list ruleset`; `tcpdump` on the backend shows SYN arriving, no reply | open the rule |
| 4 | Backend is not speaking HTTP (wrong port — e.g. Postgres) | `upstream sent invalid header while reading response header` | `curl -v http://backend:port/` returns binary garbage | correct the port |
| 5 | Backend closed the connection mid-response (crash, OOM) | `upstream prematurely closed connection while reading response header` | `journalctl -u backend`; `dmesg \| grep -i oom` | fix the crash; add memory limits |
| 6 | All members marked down by `max_fails` | `no live upstreams while connecting to upstream` | `curl` each member directly — they may all be healthy *now* | tune `max_fails`/`fail_timeout`; they were flapping |

**The pattern to internalise:** the errno in the log is doing all the work.

- **111 / ECONNREFUSED** → the host answered. Routing and firewall are fine. It is the **service or the port**.
- **110 / ETIMEDOUT** → nothing answered. It is the **path** — firewall, route, or a hung backend.
- **"invalid header"** → you connected to something that is not an HTTP server.
- **"prematurely closed"** → it *was* an HTTP server and it died mid-answer.

Four distinct places to look, discriminated by one word in one log file. This is why `error.log` beats `access.log` for 502s, and why "restart nginx" — the thing everyone tries first — fixes exactly none of these six.

---

## C5.1 — Zero-downtime backend replacement

```bash
# The runbook. Order is everything.
#
# 1. START the new backends and confirm they are healthy BEFORE touching the LB.
python3 backend.py --port 9011 --name new1 &
python3 backend.py --port 9012 --name new2 &
curl -sf localhost:9011/health && curl -sf localhost:9012/health || exit 1

# 2. ADD them to the pool alongside the old ones. Now 4 members serve traffic.
#    (edit nginx upstream, then:)
sudo nginx -t && sudo systemctl reload nginx

# 3. Confirm the new members are RECEIVING traffic and answering correctly.
for i in $(seq 1 20); do curl -s localhost/ | jq -r .backend; done | sort | uniq -c

# 4. DRAIN the old ones - mark unhealthy, do NOT kill them.
curl -s localhost:9001/toggle >/dev/null
curl -s localhost:9002/toggle >/dev/null

# 5. WAIT for the health check to notice (inter * fall = 2s * 3 = 6s) PLUS the
#    longest in-flight request. This wait is the entire point.
sleep 15

# 6. Confirm zero traffic is reaching them, THEN remove from config and reload.
sudo nginx -t && sudo systemctl reload nginx

# 7. Only now, stop the old processes.
kill %1 %2
```

**Where the failures come from if you get it wrong:**

- Killing the old backend before the LB notices → every request routed to it in that window is a 502. With `inter 2s fall 3` that window is **6 seconds** of failures.
- `systemctl restart nginx` instead of `reload` → every in-flight connection is dropped at that instant.
- Not waiting for in-flight requests after draining → a request that started before the drain and takes 20 seconds is killed at second 3.

**The generalisable rule: add before you remove, and drain before you stop.** Every orchestrator implements this; Swarm calls it `--update-order start-first` and `stop-grace-period`, and in Week 10 you will recognise both immediately.

---

## C5.2 — The redirect loop

**The cause:** the proxy terminates TLS and speaks plain HTTP to the backend. The backend sees `scheme = http`, believes the user arrived over HTTP, and issues `301 → https://...`. The browser follows it back to the proxy, which again forwards plain HTTP, which again redirects. Forever.

```nginx
proxy_set_header X-Forwarded-Proto $scheme;
```

and the application must be configured to trust it (Django `SECURE_PROXY_SSL_HEADER`, Rails `config.force_ssl` with trusted proxies, Express `app.set('trust proxy', 1)`).

**The three sentences:**

> When a reverse proxy terminates TLS, the backend receives an ordinary HTTP request and has no way to know the user's connection was encrypted. `X-Forwarded-Proto` carries that fact across the gap so the backend can build correct absolute URLs and make correct redirect decisions. The loop happens because the backend, reasoning only from what it can see, correctly concludes "this request is insecure" and redirects — over and over, because the proxy makes every forwarded request look identical.

**The security caveat that matters:** the backend must only trust `X-Forwarded-*` from a proxy it actually trusts. Any client can send `X-Forwarded-For: 1.2.3.4` or `X-Forwarded-Proto: https` directly, and an app that trusts them blindly can be tricked into believing an attacker is an internal IP or already authenticated. Trust the header only on the interface the proxy connects from.

---

## C5.3 — Path routing

```nginx
# /api/  -> backend, with /api stripped
location /api/ {
    # THE TRAILING SLASH IS THE WHOLE TRICK.
    #   proxy_pass http://api_backend/;   (with slash) -> /api/users becomes /users
    #   proxy_pass http://api_backend;    (no slash)   -> /api/users stays /api/users
    # This is one of nginx's genuinely surprising behaviours and it costs
    # everybody an hour exactly once.
    proxy_pass http://api_backend/;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
}

# /static/ -> straight off disk, never touching a backend
location /static/ {
    alias /var/www/static/;
    expires 7d;
    add_header Cache-Control "public, immutable";
    access_log off;
}

# /admin/ -> restricted by source address
location /admin/ {
    allow 10.0.0.0/8;
    allow 127.0.0.1;
    deny all;                       # order matters: allow rules, then deny all
    proxy_pass http://app_backend;
    proxy_set_header Host $host;
}

# /metrics -> localhost only, invisible to everyone else
location = /metrics {
    allow 127.0.0.1;
    deny all;
    proxy_pass http://app_backend;
}
```

**The trailing-slash trap, stated plainly:** if `proxy_pass` ends with a URI (even just `/`), nginx **replaces** the matched `location` prefix with it. If it has no URI part, nginx passes the original path through untouched. `http://backend` and `http://backend/` behave completely differently, and nothing in the error message will tell you.

**A note on `deny all` returning 403:** for `/metrics` the challenge asked for a 404 to outsiders. `deny all` gives 403, which *confirms the endpoint exists*. `return 404;` inside the deny branch hides it. Whether that matters is a real judgement call — it is obscurity, not security, but it does reduce what a scanner learns.

---

## C5.4 — Health check design

```python
# In backend.py
DEPS = {"postgres": True, "redis": True}
DRAINING = False

def handle_health(self):
    """READINESS - what the LOAD BALANCER asks. Narrow on purpose."""
    if DRAINING:
        return self._json(503, {"status": "draining"})
    if not DEPS["postgres"]:
        # We cannot serve ANY useful request without the database.
        return self._json(503, {"status": "unhealthy", "reason": "postgres unreachable"})
    # Redis is a cache. Degraded, but still serving. Return 200.
    status = "ok" if DEPS["redis"] else "degraded"
    return self._json(200, {"status": status, "redis": DEPS["redis"]})

def handle_deep_health(self):
    """For MONITORING. Reports everything, and never removes us from the LB."""
    return self._json(200, {
        "postgres": DEPS["postgres"],
        "redis": DEPS["redis"],
        "draining": DRAINING,
        "uptime_s": time.time() - START,
    })
```

**Answers:**

- **Redis down → 200 with `"degraded"`.** The service still works, just slower. Removing it from the pool would reduce capacity for no benefit.
- **Postgres down → 503.** It cannot serve. But note the trap below.
- **Should the LB and monitoring use the same endpoint? No.** They ask different questions. The LB asks *"should I send you traffic?"* — a narrow, cheap, fast question. Monitoring asks *"how are you, in detail?"* — expensive and comprehensive. Merging them means either your LB check is slow and fragile, or your monitoring is blind.
- **Draining without a deploy:** a mutable flag toggled via an admin endpoint or a file on disk (`if os.path.exists("/tmp/draining")`). The operator touches the file, the next health check returns 503, the LB drains the instance, and no deployment or restart is involved. This is the most useful five lines of code in any service.

**The trap the challenge is really about:** if `/health` returns 503 when Postgres is down, and Postgres blips, **every instance fails simultaneously** and the load balancer removes the entire pool. You have turned a degraded database into a complete outage, plus a thundering herd of restarts when it recovers.

Mitigations: make the database check tolerant (fail only after N consecutive failures over M seconds, not on one timeout); or have the LB keep the last-known-good pool when *all* members are failing — HAProxy does not do this by default, which is why the tolerance belongs in your health endpoint. **A health check that is too sensitive causes more outages than it prevents**, and this is a genuinely counter-intuitive lesson that most people learn from an incident.

---

## C5.5 — The cost of TLS

Typical results on a 2-vCPU VM:

| Measurement | HTTP | HTTPS |
|---|---|---|
| Connection setup | ~0.3 ms (loopback) | ~3–8 ms cold, **~0.5 ms resumed** |
| Requests/sec (keep-alive) | ~9,000 | ~8,500 |
| Requests/sec (new conn each) | ~4,000 | ~900 |
| CPU per full handshake | — | ~1–2 ms (RSA-2048), ~0.3 ms (ECDSA-P256) |

```bash
sudo apt-get install -y apache2-utils
ab -n 2000 -c 20 -k http://app.lab.local/
ab -n 2000 -c 20 -k https://app.lab.local/
ab -n 2000 -c 20    https://app.lab.local/     # no keep-alive - watch it collapse
```

**The answer: no, "TLS is too slow" is not a real argument — but the reason is more specific than "hardware got faster".**

The cost is almost entirely in the **handshake**, not in the bulk encryption (AES-NI makes symmetric crypto essentially free). So the cost is per *connection*, not per *request*. With keep-alive and session resumption, the penalty is a few percent. Without keep-alive it is a factor of four — which means **if TLS looks expensive in your measurements, the real finding is that something is not reusing connections**, and that would have been hurting you over plain HTTP too.

ECDSA is 3–5× cheaper per handshake than RSA-2048 and is well supported; using RSA-4096 for a public web server is a measurable cost for no meaningful security gain.

---

## C5.7 — Rate limiting under attack

```nginx
limit_req_zone $binary_remote_addr zone=perip:10m rate=10r/s;
limit_req_status 429;                # 429 is correct; the default 503 is a lie

location / {
    limit_req zone=perip burst=20 nodelay;
    # burst=20     allow a short spike of 20 before rejecting
    # nodelay      serve the burst IMMEDIATELY rather than queueing it -
    #              queueing turns a rate limit into a latency problem for
    #              legitimate users, which is worse than rejecting.
}
```

```bash
ab -n 500 -c 100 http://app.lab.local/ 2>&1 | grep -E 'Non-2xx|Requests per'
# meanwhile, from another terminal, measure what a NORMAL user sees:
curl -o /dev/null -s -w 'code=%{http_code} total=%{time_total}\n' http://app.lab.local/
```

**The hard question — shared NAT.**

`$binary_remote_addr` keys the limit by source IP. When 500 employees of one company share a single NAT address, they collectively appear as one client, hit the 10 r/s limit, and are all throttled — while an attacker with a botnet of 5,000 residential IPs sails through untouched, because each individual IP stays under the limit.

So the key is wrong in both directions: it punishes legitimate aggregation and fails to catch genuine distribution.

**Alternatives, and what each breaks:**

| Key | Fixes | Breaks |
|---|---|---|
| Authenticated user/API key | NAT and botnets both | Useless for unauthenticated endpoints — including login, which is what you most want to protect |
| Session cookie | Anonymous users get separate budgets | Trivially bypassed: the attacker discards the cookie |
| `/24` subnet instead of `/32` | Catches cheap single-subnet attacks | Punishes even more legitimate users at once |
| Per-endpoint limits (strict on `/login`, loose on `/static`) | Focuses the limit where abuse is expensive | More configuration; needs you to know your traffic |

**What you actually do:** layer them. A generous per-IP limit as a blunt instrument, a strict per-account limit on expensive endpoints, and a much stricter limit on authentication endpoints specifically. And accept, explicitly, that rate limiting is a mitigation for *accidental* overload and *unsophisticated* abuse. A determined distributed attacker needs a different tool, and pretending otherwise is how teams end up with rate limits so tight that they only ever hurt their own users.
