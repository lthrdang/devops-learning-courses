# Week 05 — HTTP, TLS, Reverse Proxy and Load Balancing

**VM profile:** `make w05-up` → `alpha` (proxy/LB) and `beta` (backends)
**You will be able to:** explain every byte of an HTTP exchange, terminate TLS with your own CA, put Nginx and HAProxy in front of real backends, and diagnose a 502 in ninety seconds.

---

## Day 1 — HTTP, precisely

### 1.1 The exchange

```http
GET /api/users?page=2 HTTP/1.1
Host: api.example.com
User-Agent: curl/8.5.0
Accept: application/json
Connection: keep-alive

```
```http
HTTP/1.1 200 OK
Date: Sun, 01 Mar 2026 09:15:00 GMT
Content-Type: application/json; charset=utf-8
Content-Length: 142
Cache-Control: max-age=60

{"users":[...]}
```

Two details that matter operationally:

- **`Host:` is mandatory in HTTP/1.1.** It is how one IP address serves a thousand sites — the server picks the site by this header. When a reverse proxy rewrites or drops it, the backend serves the wrong site or 404s. This is the cause of a large share of "it works when I curl the backend directly" mysteries.
- **The blank line separates headers from body.** `Content-Length` (or `Transfer-Encoding: chunked`) tells the receiver where the body ends. Get this wrong and connections hang rather than error.

### 1.2 Status codes as a triage tool

Do not memorise the list. Memorise **who is to blame**:

| Code | Meaning | Whose problem |
|---|---|---|
| 2xx | success | — |
| 301/302 | moved permanently/temporarily | 301 is cached by browsers **forever** — a wrong 301 is very hard to undo |
| 304 | not modified | caching working correctly |
| 400 | malformed request | the **client** |
| 401 / 403 | unauthenticated / authenticated but not allowed | these are different; conflating them wastes time |
| 404 | not found | the client, *or* your routing |
| 429 | rate limited | the client, or your limits are too tight |
| **500** | the application threw | **the application.** Read app logs |
| **502** | **the proxy could not reach the upstream, or got garbage** | **infrastructure.** Read the proxy's error log |
| **503** | no healthy upstream / deliberately unavailable | infrastructure or capacity |
| **504** | upstream too slow; the proxy gave up | **the upstream is alive but slow.** Read timeouts and the app's latency |

> **This table is the most immediately useful thing in this week.** 500 sends you to the developer. 502/503/504 send you to yourself. Being able to say "this is a 504, so the backend is up but exceeding our 5-second `proxy_read_timeout`" in the first minute of an incident is what a competent platform engineer sounds like.

### 1.3 Keep-alive, and why it matters

HTTP/1.0 opened a TCP connection per request. HTTP/1.1 reuses one (`Connection: keep-alive`). A TCP handshake plus a TLS handshake is 2–3 round trips; on a 50 ms link that is 150 ms *before any data*. Reusing connections is the single largest latency win available, and it is why a proxy that fails to keep connections alive to its backends can double your response times without any error appearing anywhere.

### 1.4 curl as an instrument

```bash
curl -v https://example.com                 # headers both ways
curl -I https://example.com                 # HEAD: headers only
curl -sS -o /dev/null -w '%{http_code}\n' URL
curl --resolve example.com:443:10.0.0.5 https://example.com/   # test a specific backend by name
curl -H 'Host: api.example.com' http://10.0.0.5/                # test name-based routing by IP
curl --http1.1 URL ; curl --http2 URL
```

**The timing breakdown is the highest-value flag in curl:**

```bash
curl -sS -o /dev/null -w '
  dns:      %{time_namelookup}s
  connect:  %{time_connect}s
  tls:      %{time_appconnect}s
  ttfb:     %{time_starttransfer}s
  total:    %{time_total}s
' https://example.com
```

Read it as a decision tree: high `dns` → resolver problem. High `connect` → network or a saturated backlog. High `tls` → handshake/CPU/certificate chain. **High `ttfb` with everything else fast → the server is thinking; the network is innocent.** High `total` with low `ttfb` → a large or slow body transfer.

---

## Day 2 — TLS

### 1.1 What the handshake establishes

Three things, in this order: **identity** (this really is `example.com`), **key agreement** (both sides derive a shared secret nobody watching can compute), and **integrity** (tampering is detectable).

The certificate proves identity by being **signed** by a Certificate Authority your system already trusts. Your trust store lives at `/etc/ssl/certs/ca-certificates.crt` on Ubuntu.

### 2.2 The chain

```
Root CA (in your trust store, self-signed)
  └── Intermediate CA (signed by the root)
        └── example.com (signed by the intermediate)   ← the "leaf"
```

**The server must send the leaf *and* the intermediates.** A server that sends only the leaf works in browsers (which cache intermediates from previous sites) and **fails in `curl`, in Java, and in your monitoring** — a genuinely maddening bug that presents as "it works in my browser". Check with:

```bash
openssl s_client -connect example.com:443 -servername example.com </dev/null 2>/dev/null | grep -E 'depth|verify|s:|i:'
```

### 2.3 SNI

One IP can host many TLS sites, but the certificate must be chosen *before* the encrypted HTTP request arrives. **SNI** (Server Name Indication) puts the hostname in the *unencrypted* part of the handshake so the server can pick.

Consequence: `openssl s_client -connect IP:443` without `-servername` gets you the default certificate, not the one you wanted — and you will conclude the certificate is wrong when it is not. **Always pass `-servername`.**

### 2.4 The errors, and what each really means

| Error | Cause | First check |
|---|---|---|
| `certificate has expired` | expired | `openssl x509 -noout -dates` — and **check the client's clock**, which is the other half of this error |
| `self signed certificate in certificate chain` | your CA is not trusted by the client | install the CA, or use `--cacert` |
| `unable to get local issuer certificate` | the server did not send the intermediate | fix the server's chain file, not the client |
| `hostname mismatch` | the name is not in the cert's SAN list | `openssl x509 -noout -ext subjectAltName` |
| `handshake failure` | no shared protocol or cipher | `openssl s_client -tls1_2` to bisect |

**Note that CN is dead.** Modern clients ignore `Subject: CN=` entirely and use only the **Subject Alternative Name** extension. A certificate with the right CN and no SAN is rejected by every current browser, and this surprises people who learned TLS years ago.

### 2.5 Terminate, or pass through?

| Model | TLS ends at | Use when |
|---|---|---|
| **Termination** | the proxy; plaintext to backends | the usual choice. The proxy can route on paths, add headers, compress, cache |
| **Passthrough** | the backend | you need end-to-end encryption, or client-certificate auth at the app |
| **Re-encryption** | terminated then re-encrypted to the backend | compliance requires encryption on the internal network too |

With termination, the backend no longer knows the request was HTTPS or who the client was. That is what `X-Forwarded-For` and `X-Forwarded-Proto` are for — and why an app that builds redirect URLs from the wrong scheme sends users to `http://` and creates a redirect loop. Extremely common.

---

## Day 3 — Reverse proxy

### 3.1 Forward vs reverse

A **forward proxy** sits in front of *clients* (a corporate egress proxy). A **reverse proxy** sits in front of *servers*. Same mechanism, opposite direction, completely different purpose.

A reverse proxy gives you: TLS termination in one place, one public port for many services, path- and host-based routing, load balancing, health checking, rate limiting, caching, compression, and a place to put security headers. It is the most useful single component in a small platform.

### 3.2 Nginx, annotated

```nginx
upstream app_backend {
    least_conn;                        # or round-robin (default), or ip_hash
    server 10.0.0.11:8080 max_fails=3 fail_timeout=30s;
    server 10.0.0.12:8080 max_fails=3 fail_timeout=30s;
    server 10.0.0.13:8080 backup;      # only used when all others are down
    keepalive 32;                      # reuse upstream connections - big latency win
}

server {
    # `http2 on;` is nginx 1.25.1+. On Ubuntu 24.04 (nginx 1.24) it is an
    # unknown directive - use the `http2` parameter on `listen` instead, which
    # is valid in both. Check `nginx -v` before copying an http2 line anywhere.
    listen 443 ssl http2;
    server_name app.lab.local;

    ssl_certificate     /etc/nginx/tls/app.crt;   # leaf + intermediates, in that order
    ssl_certificate_key /etc/nginx/tls/app.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    location /health {
        access_log off;                # do not drown real traffic in probe noise
        return 200 "ok\n";
    }

    location / {
        proxy_pass http://app_backend;

        # Without these the backend sees the PROXY as the client and has no idea
        # the request was HTTPS. This is the single most common proxy misconfiguration.
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_http_version 1.1;            # required for upstream keepalive
        proxy_set_header Connection "";    # ditto

        proxy_connect_timeout 5s;          # can't connect      → 502
        proxy_send_timeout   30s;
        proxy_read_timeout   30s;          # upstream too slow  → 504
        proxy_next_upstream error timeout http_502 http_503;
    }
}

server {
    listen 80;
    server_name app.lab.local;
    return 301 https://$host$request_uri;
}
```

```bash
sudo nginx -t                    # ALWAYS validate before applying
sudo systemctl reload nginx      # reload = zero downtime; restart = drops connections
```

**`reload` vs `restart` is a real operational distinction.** Reload starts new workers with the new config and lets old workers finish their in-flight requests. Restart kills everything. Using `restart` for a config change is a self-inflicted, entirely avoidable blip.

### 3.3 Where a 502 explains itself

```bash
sudo tail -f /var/log/nginx/error.log
```

| Message | errno | Means |
|---|---|---|
| `connect() failed (111: Connection refused)` | ECONNREFUSED | the upstream host is up; **nothing is listening on that port** |
| `connect() failed (113: No route to host)` | EHOSTUNREACH | routing/firewall |
| `upstream timed out (110: Connection timed out)` | ETIMEDOUT | firewall dropping, or the upstream is hung |
| `no live upstreams` | — | every backend has been marked down by `max_fails` |
| `upstream sent invalid header` | — | the backend is not speaking HTTP (wrong port — e.g. you pointed at a database) |

Note that this is `error.log`, **not `access.log`**. Access log shows the 502 happened; error log shows *why*. People stare at access logs for twenty minutes surprisingly often.

---

## Day 4 — Load balancing

### 4.1 L4 vs L7

| | L4 (transport) | L7 (application) |
|---|---|---|
| Decides on | IP + port | URL, headers, cookies, method |
| Sees content | no | yes |
| TLS | can pass through | must terminate to inspect |
| Cost | very cheap | more CPU |
| Can retry a failed request | no | yes |
| Examples | HAProxy `mode tcp`, IPVS | Nginx, HAProxy `mode http`, Traefik |

Use L4 for databases and non-HTTP protocols; L7 for HTTP, where routing by path and retrying idempotent requests are worth the cost.

### 4.2 Algorithms

| Algorithm | Sends to | Good for |
|---|---|---|
| round-robin | each in turn | uniform backends, short requests |
| least connections | fewest active | variable request durations — usually the best default |
| source hash / ip_hash | deterministic by client IP | crude session stickiness |
| random with two choices | best of two random picks | large fleets; nearly as good as least-conn without the shared state |

**Sticky sessions are a smell.** They exist because an application keeps state in memory. They break scaling (a hot backend stays hot), break rolling updates (draining evicts sessions), and break failover. The correct fix is to move session state into Redis or a signed cookie. Learn to say this politely, because you will need to say it.

### 4.3 Health checks — the part people get wrong

```
backend app
    balance leastconn
    option httpchk GET /health
    http-check expect status 200
    default-server inter 2s fall 3 rise 2
    server app1 10.0.0.11:8080 check
    server app2 10.0.0.12:8080 check
```

- `inter 2s` — probe every 2 seconds
- `fall 3` — three consecutive failures before removing it (avoids flapping on one blip)
- `rise 2` — two successes before returning it (avoids returning a still-warming instance)

**Liveness vs readiness.** A `/health` that returns 200 whenever the process is alive is a **liveness** check. What a load balancer needs is **readiness**: can this instance serve a real request *right now* — is its database connection up, is its cache warm, is it not shutting down?

> **The trap in the other direction:** if `/health` checks the database, and the database blips, *every* backend fails its check simultaneously and the load balancer removes them all. You have converted a degraded database into a total outage. The rule of thumb: check dependencies you can survive without in a *separate* endpoint, and keep the LB's readiness check narrow — usually "am I accepting traffic", plus a flag you can flip to drain.

### 4.4 Graceful shutdown

The correct sequence for removing an instance:

1. Mark it **draining** — the LB stops sending *new* connections.
2. Wait for in-flight requests to finish (this is why `sleep 5` before `SIGTERM` exists in real deployment scripts).
3. Send `SIGTERM`; the app stops accepting and finishes what it has.
4. Escalate to `SIGKILL` after a timeout.

Skipping step 1 means every request in flight becomes a 502 for a real user. Week 10 gets this for free from Swarm's rolling updates — but only if the healthcheck and `stop-grace-period` are configured correctly, so understanding it by hand now is what makes that work later.

---

## Day 5 — Drill

```bash
cd infra
make snapshot VM=alpha NAME=pre-w05
make break VM=alpha DRILL=05-proxy
```

Symptom: *"The website returns 502 Bad Gateway. Nginx is running. I restarted it twice."*

Target: **cause identified in under 5 minutes.** Time yourself.

## Recommended reading

- MDN HTTP docs — <https://developer.mozilla.org/en-US/docs/Web/HTTP> — the best free HTTP reference
- <https://http.cat/> — silly, and genuinely useful for remembering codes
- Nginx docs — <https://nginx.org/en/docs/> — and `nginx -T` to dump the full effective config
- HAProxy configuration manual — <https://docs.haproxy.org/>
- Mozilla SSL Configuration Generator — <https://ssl-config.mozilla.org/> — copy from here, not from a blog
- *High Performance Browser Networking*, Ilya Grigorik — **free online** at <https://hpbn.co/>
