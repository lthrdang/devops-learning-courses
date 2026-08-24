# Week 09 — Solutions & discussion

---

## The drill (09-latency) — the investigation, worked

**Step 1 — DEFINE.** The report is "slow, sometimes". Turn it into something testable:

```bash
for i in $(seq 1 20); do
  curl -o /dev/null -s -w '%{time_connect} %{time_starttransfer} %{time_total}\n' \
    http://localhost:8000/items
done
```

Twenty samples, not one. "Sometimes slow" means the distribution matters, and a single measurement cannot see a distribution. You now have a reproducible measurement and a shape.

**Step 2 — MEASURE.** The 60-second triage:

```bash
uptime          # load 2.4 on 2 cores -> saturated
vmstat 1 5      # r=2-3 consistently; si/so NON-ZERO -> swapping
mpstat -P ALL 1 3
free -m         # available is low
tc qdisc show   # ← the one nobody runs
```

**Step 3 — BISECT.** The decisive question: *is the slowness in the network or in the server?*

```bash
curl -o /dev/null -s -w 'connect=%{time_connect} ttfb=%{time_starttransfer}\n' http://localhost:8000/items
curl -o /dev/null -s -w 'connect=%{time_connect} ttfb=%{time_starttransfer}\n' http://<PEER>:8000/items
```

Loopback is unaffected by `tc netem` on the default interface; the peer is not. **That single comparison separates fault 3 from faults 1 and 2** — and it takes ten seconds.

**The three faults:**

| # | Fault | Found by | Fingerprint |
|---|---|---|---|
| 1 | `stress-ng --cpu 1 --cpu-load 85` | `top`, `pidstat 1` | load ≈ cores, one process at ~85% |
| 2 | `tc qdisc netem delay 150ms ±40ms` | `tc qdisc show`; `ping` vs baseline | **`time_connect` inflated, `ttfb − connect` normal** |
| 3 | `stress-ng --vm 1 --vm-bytes 55%` | `free -m`, `vmstat` si/so | bimodal latency: fine p50, terrible p99 |

**Why the symptom said "sometimes".** Fault 2 adds a *distribution* (150 ms ± 40 ms), and fault 3 causes swapping that hits some requests and not others. Two independent sources of variance produce "sometimes fine, sometimes five seconds" — which is exactly why averaging would have hidden all of it.

**The lesson to carry forward:** *"intermittent" is not a property of the problem; it is a property of your measurement.* Every intermittent problem varies along some axis — which backend, which request, which time of day, which customer. Find the axis and it becomes deterministic. The `for` loop above was the first step in doing that.

---

## C9.1 — The SLO

**The SLO:** 99.9% of `/items` requests succeed (non-5xx) **and** complete within 500 ms, measured over a rolling 30 days.

**Compliance:**

```promql
sum(rate(http_requests_total{route="/items", status!~"5.."}[30d]))
  / sum(rate(http_requests_total{route="/items"}[30d]))
```

**The error budget:** 99.9% over 30 days permits **43 minutes 12 seconds** of full unavailability — or an equivalent partial degradation. That number is the whole point of an SLO: it converts an argument about "how reliable should we be" into arithmetic.

| SLO | Budget per 30 days |
|---|---|
| 99% | 7h 12m |
| 99.9% | 43m 12s |
| 99.95% | 21m 36s |
| 99.99% | 4m 19s |

**Burn-rate alerting — the part that matters.** Alerting on "we breached the SLO" is useless: by then the month is spent. Alert on *consuming the budget too fast*:

```yaml
# Fast burn: 14.4x the sustained rate exhausts a 30-day budget in ~2 days.
# The short window (5m) plus long window (1h) both firing suppresses
# single-spike false positives.
- alert: ErrorBudgetBurnFast
  expr: |
    (
      sum(rate(http_requests_total{route="/items",status=~"5.."}[5m]))
        / sum(rate(http_requests_total{route="/items"}[5m])) > 14.4 * 0.001
    )
    and
    (
      sum(rate(http_requests_total{route="/items",status=~"5.."}[1h]))
        / sum(rate(http_requests_total{route="/items"}[1h])) > 14.4 * 0.001
    )
  for: 2m
  labels: { severity: page }

# Slow burn: 6x - exhausts in ~5 days. A ticket, not a page.
- alert: ErrorBudgetBurnSlow
  expr: |
    sum(rate(http_requests_total{route="/items",status=~"5.."}[6h]))
      / sum(rate(http_requests_total{route="/items"}[6h])) > 6 * 0.001
  for: 30m
  labels: { severity: ticket }
```

**What you stop doing when the budget is exhausted:** you freeze feature releases and spend the engineering time on reliability until the budget recovers. **If nothing changes when the budget runs out, you do not have an SLO — you have a number on a dashboard.** This is the clause that makes the SLO a real contract between the people who want features and the people who carry the pager, and it is the clause organisations quietly omit.

---

## C9.3 — Find the cardinality bomb

```bash
#!/usr/bin/env bash
set -euo pipefail
PROM=${PROM:-http://localhost:9090}

echo "=== TSDB summary (Prometheus computes this for you) ==="
curl -s "$PROM/api/v1/status/tsdb" | jq '{
  seriesCountByMetricName: .data.seriesCountByMetricName[:10],
  labelValueCountByLabelName: .data.labelValueCountByLabelName[:10],
  memoryInBytesByLabelName: .data.memoryInBytesByLabelName[:10]
}'

echo "=== total series ==="
curl -s --data-urlencode 'query=count({__name__=~".+"})' "$PROM/api/v1/query" | jq -r '.data.result[0].value[1]'

echo "=== series per metric, top 15 ==="
curl -s --data-urlencode 'query=topk(15, count by (__name__)({__name__=~".+"}))' \
  "$PROM/api/v1/query" \
  | jq -r '.data.result[] | "\(.value[1])\t\(.metric.__name__)"' | sort -rn

echo "=== 24h growth (>50% is a warning sign) ==="
curl -s --data-urlencode \
  'query=topk(10, (count by (__name__)({__name__=~".+"}) / (count by (__name__)({__name__=~".+"} offset 24h)) - 1) * 100)' \
  "$PROM/api/v1/query" \
  | jq -r '.data.result[] | select((.value[1]|tonumber) > 50) | "\(.metric.__name__)\t+\(.value[1]|tonumber|floor)%"'
```

**How to read the results.** `labelValueCountByLabelName` is the one to stare at. Any label with thousands of distinct values is either already a problem or about to be. Common offenders: `path` (unbounded URLs), `user_id`, `request_id`, `error_message`, `pod` in an environment that recreates pods constantly, and `version` when every CI build produces a new one.

**The arithmetic that makes it visceral:** a histogram with 12 buckets, labelled by `method` (5) × `status` (8) × `route`, costs `12 × 5 × 8 = 480` series **per route**. With 20 route templates that is 9,600 series — fine. Replace the template with the raw path and 10,000 distinct URLs gives you **4.8 million series**, and Prometheus is dead. That factor is why `route_of()` in `metered.py` is the most important function in the file.

---

## C9.4 — Log volume triage

Reducing 50 GB/day by 80%, in order of value-per-byte removed:

| Action | Typical saving | What you lose |
|---|---|---|
| Drop health-check and load-balancer probe lines | **30–50%** | nothing. These are pure noise; `access_log off` on `/health` (week 5) |
| Drop `DEBUG` in production; keep `INFO` and above | 20–30% | verbose tracing. Keep a runtime flag to re-enable per service |
| Sample successful requests at 1-in-100; keep **100% of errors** | 15–25% | exact per-request history of successes. This is the best ratio available |
| Drop static-asset access logs (`/static/*`) | 5–15% | asset-level analytics; usually already in a CDN |
| Shorten retention: 7 days hot, 30 days cold, rather than 90 days hot | large | fast queries on old incidents |
| Stop logging full request/response bodies | varies, often huge | deep debugging — and it removes a **compliance risk**, since bodies contain personal data |

**What you can no longer investigate — the honest list:**

- *"Show me every request user X made last Tuesday."* Sampling breaks this. If it is a real requirement, it is an **audit log**, which is a separate stream with different retention and different rules — do not conflate the two.
- Reconstructing an incident older than the hot window without waiting for cold storage.
- Debugging a rare, non-erroring behaviour — a request that succeeds but produces wrong output is invisible if you only kept errors.

**The principle:** keep **100% of errors, always**, and sample successes. Errors are rare, small, and are what you actually read; successes are voluminous and near-identical. And note that the health-check line item — the single biggest saving — costs you literally nothing, which is a good indication of how much log spend is pure waste.

---

## C9.7 — The runbook

```markdown
# Runbook: HighErrorRate

## What this means
More than 5% of HTTP requests returned 5xx for at least 5 minutes.

## What users are experiencing
Roughly 1 in 20 page loads fails. Because a page makes several API calls, the
proportion of users hitting AT LEAST ONE failure is much higher than 5% -
assume most active users are affected.

## First three commands
    curl -s -o /dev/null -w '%{http_code} ttfb=%{time_starttransfer}\n' https://app/api/items
    docker compose ps                    # up AND healthy?
    docker compose logs --since 15m api | grep -iE 'error|exception' | tail -30

## Most likely causes, and how to tell them apart
1. **A bad deploy.**  `docker image ls --format '{{.Repository}}:{{.Tag}}\t{{.CreatedSince}}'`
   If an image was created in the last hour, this is the first suspect.
   -> MITIGATE BY ROLLING BACK. Do not diagnose first.

2. **A dependency is down.**  `curl -s localhost:8000/health | jq`
   If it reports `"reason":"database unreachable"`, the app is fine and the
   database is not. Note that the app returns 503 for this, so a 500 makes
   this LESS likely - check anyway, it is cheap.

3. **Resource exhaustion.**  `docker stats --no-stream` ; `df -h` ; `df -i` ; `free -m`
   Look for OOM: `docker inspect <c> --format '{{.State.OOMKilled}}'`, exit 137.
   A full disk (blocks OR inodes) presents as 500s from almost any application.

## Mitigate
- Bad deploy      -> `docker service rollback api`   (or redeploy the previous tag)
- Dependency down -> follow that dependency's runbook; consider serving degraded
- Resource        -> raise the limit / free the resource, then find the leak LATER

MITIGATE FIRST, UNDERSTAND SECOND. A rollback at minute 5 beats a root cause at
minute 90. The users do not care why.

## Verify
    for i in $(seq 1 50); do curl -s -o /dev/null -w '%{http_code}\n' https://app/api/items; done | sort | uniq -c
Expect zero 5xx. Then confirm the alert clears - and watch for 10 minutes,
because an alert that clears and re-fires means you fixed a symptom.

## If none of this works
Escalate to #platform-oncall with: the timeline so far, what you ruled OUT and
how, and a link to the dashboard time range. "What I ruled out" is the most
useful thing you can hand the next person.
```

**Why this shape works.** It opens with *user impact* rather than a metric definition, because that is what determines urgency. It orders causes by **likelihood × cheapness to test**, not by interest. It says "roll back before diagnosing" explicitly, because under stress people want to understand first and that instinct costs users minutes. And the final section asks for **what was ruled out** — the single most useful handover artefact, and the one nobody produces unless the template demands it.

**Testing the runbook is not optional.** Every place a reader gets stuck is a defect. A runbook only its author can follow is a runbook that fails at 3am, which is the only time it is ever read.
