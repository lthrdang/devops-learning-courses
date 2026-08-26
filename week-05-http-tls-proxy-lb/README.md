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
| **503** | the service is *deliberately* refusing: maintenance, load shedding, a rate limiter | **capacity or policy.** Something chose not to serve this |
| **504** | upstream too slow; the proxy gave up | **the upstream is alive but slow.** Read timeouts and the app's latency |

> **This table is the most immediately useful thing in this week.** 500 sends you to the developer. 502/503/504 send you to yourself. Being able to say "this is a 504, so the backend is up but exceeding our 5-second `proxy_read_timeout`" in the first minute of an incident is what a competent platform engineer sounds like.

**Which code you get for "no backends left" is a property of your proxy, not of HTTP.** RFC 9110 §15.6.4 defines 503 as a *deliberate* condition — "temporary overloading or scheduled maintenance" — and HAProxy reads it that way: when no server in a backend is available, it answers **503**. Nginx does not. Point an nginx upstream at three dead backends and every single request comes back **502**, with `no live upstreams` in the error log (measured on nginx 1.24). Nginx has to stretch 502 to do that — §15.6.3 defines 502 as an *invalid response* from an inbound server, and "no response at all" is not the same thing — but stretch it it does, and so do several other proxies.

> So: **know your proxy's dialect before you page anyone.** On nginx, "502" means *reaching the upstream failed somehow* and the error log holds the actual reason; on HAProxy the same situation is a 503. And notice what else emits a 503: nginx's `limit_req` rejects with 503 by default, so an apparent backend outage can turn out to be your own rate limiter refusing traffic (C5.7 changes it to 429, which is the honest code).

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

### 2.1 What the handshake establishes

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
# 2>&1 - NOT 2>/dev/null. See below.
openssl s_client -connect example.com:443 -servername example.com </dev/null 2>&1 \
  | grep -E 'depth|verify|s:|i:'

# How many certificates did the server actually send? Remember this one.
openssl s_client -connect example.com:443 -servername example.com </dev/null 2>/dev/null \
  | grep -c '^ *[0-9] s:'
```

**Merge stderr, or you are grepping for lines that cannot arrive.** `s_client` writes the chain it received (` 0 s:…`, `   i:…`) to **stdout** and the verification trace (`depth=2 …`, `verify return:1`) to **stderr**. With `2>/dev/null` the `depth` and `verify` halves of that pattern can never match — and because the `s:`/`i:` lines still print, the command looks like it worked. You lose exactly the half that says whether verification *passed*, and nothing tells you.

### 2.3 SNI

One IP can host many TLS sites, but the certificate must be chosen *before* the encrypted HTTP request arrives. **SNI** (Server Name Indication) puts the hostname in the *unencrypted* part of the handshake so the server can pick.

Consequence: connect without SNI and the server hands you its *default* certificate rather than the one you meant to inspect — and you conclude the certificate is wrong when it is fine. **Always pass `-servername`.** But not for the reason most people give: since OpenSSL 1.1.1, `s_client` fills SNI in by itself from whatever you handed `-connect`, as long as that looks like a DNS name. The cases where it does not, each confirmed by reading the ClientHello off the wire (OpenSSL 3.0.13):

| `s_client -connect …` | SNI sent |
|---|---|
| `app.lab.local:443` | `app.lab.local` — automatic, no flag needed |
| `10.0.0.5:443` | **none** — RFC 6066 forbids a literal address in SNI |
| `localhost:443` | **none** — a single-label name is not a DNS name as far as OpenSSL is concerned |
| any of those, plus `-noservername` | **none** |

Which is precisely why the habit still earns its keep. The moment you reach for `s_client` in anger you are usually connecting **to an IP** to bypass DNS — precisely the case where SNI silently disappears. Lab 3.4 makes you watch it happen.

One more thing `s_client` will not do for you: **it does not check the hostname against the certificate.** `Verify return code: 0 (ok)` means the chain is trusted, not that it is the right chain for the name you asked about. Pass `-verify_hostname app.lab.local` and you get a real answer — `Verification: OK`, or `Verify return code: 62 (hostname mismatch)`.

### 2.4 The errors, and what each really means

| Error | Cause | First check |
|---|---|---|
| `certificate has expired` | expired | `openssl x509 -noout -dates` — and **check the client's clock**, which is the other half of this error |
| `self-signed certificate in certificate chain` | a CA you do not trust signed it, **and** the server sent its root along too | install the CA, or use `--cacert` |
| `unable to get local issuer certificate` | **two unrelated faults**: the server omitted the intermediate, *or* the signing CA is not in your trust store | count the certificates the server sent (below), then blame the correct end |
| `hostname mismatch` | the name is not in the cert's SAN list | `openssl x509 -noout -ext subjectAltName` |
| `handshake failure` | no shared protocol or cipher | `openssl s_client -tls1_2` to bisect |

**Two notes on that table, both of which cost people afternoons.**

**`unable to get local issuer certificate` is the most misread string in TLS**, because it names a *symptom* — "I cannot find the issuer of the certificate in front of me" — that two unrelated faults produce. Either the server sent an incomplete chain, or the chain is complete and rooted in a CA you do not trust. Part 3 of this week's lab manufactures the second one on purpose (your own lab CA, absent from the trust store), where the correct fix is `--cacert` **on the client** — the exact opposite of "fix the server's chain file". So discriminate before you act:

```bash
openssl s_client -connect HOST:443 -servername HOST </dev/null 2>/dev/null | grep -c '^ *[0-9] s:'
```

One certificate on a chain that ought to have an intermediate → **the server is at fault**; fix its chain file. A complete chain → **you are at fault**; trust the CA. A related curiosity, reproduced against one lab certificate by changing only the chain file it was served with: an untrusted private CA reports as `unable to get local issuer certificate` when the server sends leaf + intermediate, and as `self-signed certificate in certificate chain` when the server also sends its root. Same trust problem, two different messages, decided entirely by what the server chose to put on the wire.

**And OpenSSL 3 hyphenates.** It is `self-signed certificate in certificate chain` (verify error 19); OpenSSL 1.x wrote `self signed`. Every runbook, blog post and log-alert regex written before that change carries the old spelling, so `grep 'self signed'` over OpenSSL 3 output finds nothing and you conclude the error is not there.

### 2.5 CN is dead — but your tools have not been told

RFC 9525 (2023, obsoleting RFC 6125) says it outright: the Subject CN "MUST NOT be used to identify a service". Only the **Subject Alternative Name** extension counts, and every current browser enforces that — a certificate with a flawless CN and no SAN is rejected outright.

Your tools are softer. OpenSSL's `X509_check_host()` still falls back to the Subject CN when a certificate carries no SAN *at all*, unless the caller sets `X509_CHECK_FLAG_NEVER_CHECK_SUBJECT` — and curl does not set it. Measured end to end, with a deliberately SAN-less certificate signed by this week's lab CA: `curl` returned **HTTP 200**, and `openssl s_client -verify_hostname` reported **`Verification: OK`**.

> **The lesson is larger than SAN: your debugging tools are more permissive than your users' browsers.** "It works in curl" is not evidence that a certificate is correct — only that curl accepted it. So do not ask a client whether the certificate is good; ask the certificate:
>
> ```bash
> openssl x509 -in server.crt -noout -ext subjectAltName
> ```
>
> If that prints `No extensions in certificate`, you are holding a certificate that will sail through every script you own and fail the instant a browser touches it.

### 2.6 Terminate, or pass through?

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
| Sees content | does not parse the protocol — but can peek at opening bytes | yes, the parsed request |
| TLS | can pass through | must terminate to inspect |
| Cost | very cheap | more CPU |
| Can retry a failed request | the **connection**, yes; the request once sent, no | yes |
| Examples | HAProxy `mode tcp`, IPVS | Nginx, HAProxy `mode http`, Traefik |

Two of those cells are usually taught as flat "no", and both deserve their qualification.

**An L4 proxy can retry** — just not what you think. HAProxy in `mode tcp` honours `retries` and `option redispatch`, both of which the `defaults` block in this week's `haproxy-lab.cfg` already sets, so a backend that refuses the connection gets redispatched to a different one before the client sees anything. What L4 cannot do is retry **after the client's bytes have been forwarded**, because it has no idea where one request ends and the next begins. "Cannot retry" really means "cannot retry a request", and the distinction is the difference between a transparent failover and a duplicated payment.

**And "sees no content" means "does not parse the protocol", not "is blind".** An L4 proxy can inspect the first bytes of a connection without terminating anything — which is exactly how the Passthrough row of the §2.6 table is implemented in practice: `req.ssl_sni` routes on the hostname in the ClientHello, which travels unencrypted, while the TLS session itself stays end to end between client and backend.

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

**So how long until a dead backend is actually out of the pool?** Multiply — then measure, because the multiplication only covers one kind of death. A backend that fails **fast** (refuses the connection, or answers the probe with a 503) is removed within `inter × fall` = **6 s** of its last good probe, and that is a real ceiling: across six runs on HAProxy 2.8 the worst observed was 5.8 s. A backend that **hangs** is a different animal — every probe now has to time out before it counts as a failure at all, and with the same `inter 2s fall 3` the measured removal time was **~10.5 s**. Detection is `inter × fall` *plus* however long a failing probe takes to give up, and hanging is the characteristic failure mode of an overloaded service.

> **Which is why you never size a drain window to `inter × fall`.** Six seconds is the case where the backend has the decency to fail fast; roughly eleven is what these numbers cost when it hangs instead; and on top of either you still owe your longest in-flight request. If you want detection that is both fast and predictable, that is what `fastinter` and an explicit `timeout check` buy you — a probe that cannot take longer than one second puts the arithmetic back in your hands.

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
