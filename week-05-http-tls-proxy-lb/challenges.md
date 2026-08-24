# Week 05 — Challenges

---

### C5.1 — Zero-downtime backend replacement

With a request loop running continuously (`while true; do curl -s ... ; done`), replace all three backends with new processes on different ports **without a single failed request**.

Count your failures. If it is not zero, work out exactly which request failed and why, then fix the procedure and repeat. Write the procedure down as a runbook.

*This is a rolling update, done by hand. Week 10 automates it — but only someone who has done it manually knows what the automation is protecting them from.*

---

### C5.2 — The redirect loop

Configure Nginx to terminate TLS and proxy to a backend that redirects HTTP to HTTPS. Produce an infinite redirect loop, confirm it with `curl -L --max-redirs 5`, then fix it.

Explain in three sentences why `X-Forwarded-Proto` exists, and what the backend was reasoning about when it caused the loop.

---

### C5.3 — Path routing

Configure a single HTTPS endpoint that routes:

- `/`         → the app backends
- `/api/`     → the API backend, with `/api` **stripped** before it reaches the backend
- `/static/`  → served directly from disk by Nginx, never touching a backend
- `/admin/`   → app backends, but only from your own subnet; 403 for everyone else
- `/metrics`  → 404 to the outside world, 200 from localhost

Prove each rule with `curl`. The `/api` stripping is the one with a subtle trailing-slash trap — find it.

---

### C5.4 — Health check design

Design `/health` for a service that depends on Postgres and Redis, where Redis is a cache the service can survive without and Postgres is not.

- What does the endpoint check?
- What does it return when Redis is down? When Postgres is down?
- Should the load balancer use the same endpoint the monitoring system uses?
- How would an operator drain a single instance for maintenance without deploying anything?

Implement it in `backend.py` and demonstrate all four scenarios against HAProxy.

---

### C5.5 — Measure the cost of TLS

Quantify, on your own VM:

1. Handshake time, cold vs with session resumption.
2. Requests per second, HTTP vs HTTPS, using `ab` or `hey`.
3. CPU consumed per handshake.
4. The difference between RSA-2048 and ECDSA-P256 certificates.

Then answer with numbers: is "TLS is too slow" a real argument in 2026?

---

### C5.6 — The 502 taxonomy

Produce **five different root causes** that all present to the user as exactly `502 Bad Gateway`. For each, record: the `error.log` line, the shortest command that distinguishes it from the other four, and the fix.

This is the single most valuable artefact you will produce this week. Keep it.

---

### C5.7 — Rate limiting under attack

Configure rate limiting so that a single client cannot exceed 10 req/s while legitimate users are unaffected. Then attack it with 100 concurrent requests and measure what real users experience during the attack.

Then answer the hard question: your rate limit key is `$binary_remote_addr`. What happens when all your users arrive through a corporate NAT and share one IP? What is the alternative, and what does *it* break?
