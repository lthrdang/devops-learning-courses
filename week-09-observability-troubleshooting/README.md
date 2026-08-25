# Week 09 — Observability & Troubleshooting

**VM profile:** `make w09-up` → `obs` (Docker + node_exporter on the host OS)
**You will be able to:** answer *why* a system is slow with evidence rather than guesses, and run a structured investigation under time pressure.

> This is the most important week in the course. Everything before it taught you to build things; this week teaches you to find out what is wrong with them. It is also the skill that most reliably separates a junior who gets promoted from one who does not.

---

## Day 1 — The troubleshooting method

### 1.1 Why you need a method at all

Under pressure, untrained engineers do the same three things: they change something, they restart something, and they look at the component they know best. All three feel productive. None of them is investigation.

A method is what stops you from confusing *activity* with *progress*. Here is the one to internalise:

```
1. DEFINE     What exactly is broken? For whom? Since when? How do I reproduce it?
2. MEASURE    What does the system say, right now? Get numbers, not impressions.
3. BISECT     Which layer? Halve the problem space with one decisive test.
4. HYPOTHESISE One cause. Written down. Falsifiable.
5. TEST       The cheapest experiment that could DISPROVE it.
6. FIX        Address the cause. Then verify by reproducing the ORIGINAL symptom.
7. RECORD     What it was, how you found it, what would have found it faster.
```

**Step 1 is the one people skip, and skipping it is why investigations wander.** "The site is slow" is not a problem statement. "Checkout p99 latency went from 200 ms to 4 s at 14:05, for all users, and is reproducible with `curl /api/checkout`" is a problem statement — and it has already told you where to look and when to look.

**Step 5 deserves emphasis: try to disprove, not confirm.** If your hypothesis is "the database is slow", do not go and look for evidence the database is slow — you will find some, because databases always have *some* slow queries. Ask instead: "what would I observe if the database were fine?" Then check for that.

### 1.2 Bisection is the highest-leverage move

Every request crosses many layers. Instead of examining them in order, **cut the path in half**:

```
client → DNS → LB → proxy → app → cache → database
                     ↑
              test HERE first
```

One `curl` from the proxy host to the app, bypassing the LB, eliminates half the stack in ten seconds. Ten seconds spent halving beats an hour spent walking.

The general form: **find a test whose result eliminates roughly half of the possibilities, regardless of the outcome.** A test that only confirms what you already suspect has low information value even when it succeeds.

### 1.3 "Nothing changed"

Someone will say it. It is false roughly as often as it is true, and you settle it with evidence, not argument:

```bash
grep -E ' install | upgrade ' /var/log/dpkg.log | tail -20
sudo find /etc -newermt '-24 hours' -type f 2>/dev/null
docker ps --format '{{.Names}}\t{{.RunningFor}}\t{{.Image}}'
docker image ls --format '{{.Repository}}:{{.Tag}}\t{{.CreatedSince}}'
git -C /path/to/config log --since=yesterday --oneline
journalctl --since yesterday | grep -iE 'started|reloaded|reboot'
last reboot | head -3
```

If genuinely nothing changed on your side, then something changed **outside** it: traffic volume, a dependency's behaviour, a certificate expiring, a disk finally filling, a leap in data size. Systems that "break with no changes" are usually systems that were slowly approaching a threshold.

---

## Day 2 — The three signals, and what each is for

| Signal | Answers | Cost | Cardinality |
|---|---|---|---|
| **Metrics** | *"is something wrong, and when did it start?"* | cheap, constant | must stay low |
| **Logs** | *"what exactly happened to this request?"* | expensive at volume | unlimited |
| **Traces** | *"where did the time go across services?"* | expensive | unlimited |

The workflow they support is: **metrics detect and localise; logs explain; traces attribute.** An alert fires from a metric, you narrow to a service, then you read that service's logs for the failing minute. Using logs for detection is slow and expensive; using metrics for explanation is impossible.

### 2.1 Metrics: the two frameworks

**USE — for resources** (CPU, memory, disk, network):
- **U**tilisation: what fraction of the time is it busy?
- **S**aturation: how much work is *queued*?
- **E**rrors

**RED — for services** (anything that serves requests):
- **R**ate: requests per second
- **E**rrors: failed requests per second
- **D**uration: latency distribution

> **Saturation is the one juniors miss.** A CPU at 100% utilisation with no queue is *fully used* and fine. A CPU at 100% with a run queue of 8 is *saturated*, and users are waiting. Utilisation has a ceiling of 100% and stops telling you anything there; saturation has no ceiling and keeps telling you how bad it is. Load average, run queue length, and I/O wait are saturation metrics.

### 2.2 Percentiles, not averages

An average latency of 250 ms can mean "everyone gets 250 ms" or "99 people get 50 ms and one gets 20 seconds". These are different systems and only one of them is broken.

```
p50  the typical experience
p95  the unhappy tail
p99  where your loudest complaints come from
p99.9 where your biggest customer lives
```

**The multiplication trap:** if one API call has a p99 of 1 second, and a page makes 50 calls, then roughly 40% of *page loads* hit at least one 1-second call. A "1% problem" is a 40% problem at the level users actually experience. This is why tail latency matters far more than intuition suggests.

**Never average a percentile.** The average of the p99s from three servers is not the p99 of the fleet. Percentiles must be computed from the underlying distribution — which is why Prometheus histograms exist.

### 2.3 Cardinality — the one way to destroy your monitoring

Every unique combination of label values is a separate time series.

```
http_requests_total{method="GET", status="200", path="/api/users"}      ← fine
http_requests_total{method="GET", status="200", user_id="12345"}        ← catastrophe
```

A `user_id` label with a million users creates a million series. Prometheus will consume all available memory and die — taking your monitoring down at exactly the moment you need it.

**Rule: labels must have bounded, small cardinality.** Method, status, endpoint *template* (`/api/users/:id`, never `/api/users/12345`), service, instance. Anything unbounded — user IDs, request IDs, full URLs, error messages — belongs in **logs**, not in metric labels.

---

## Day 3 — The stack

All of these are free and open source, and all are what real teams run.

| Component | Role |
|---|---|
| **Prometheus** | scrapes and stores metrics; evaluates alert rules |
| **node_exporter** | exposes host metrics (CPU, memory, disk, network) |
| **cAdvisor** | exposes per-container metrics |
| **Grafana** | dashboards and alerting UI |
| **Loki** | log aggregation, queried like Prometheus |
| **Promtail / Alloy** | ships logs into Loki |
| **Alertmanager** | deduplicates, groups and routes alerts |

> ### ⚠️ Promtail is end of life — and this course still uses it on purpose
>
> **Grafana declared Promtail EOL on 2 March 2026.** Commercial support has ended, there will be no further releases, and Grafana's own documentation says you must migrate to **Alloy** or another supported client. Read it yourself: <https://grafana.com/docs/loki/latest/send-data/promtail/>.
>
> The lab stack pins `grafana/promtail:3.6.8` anyway, and that is a decision rather than an oversight. Promtail's config file is about fifteen readable lines — a `scrape_configs:` block that looks exactly like Prometheus's, which you have just learned. Alloy's equivalent is a River-syntax pipeline of `loki.source.*` / `loki.process` / `loki.write` components, and learning a component graph at the same time as learning what a log shipper *does* costs you the lesson.
>
> **What you must take away from this:** in a real job you would migrate, and the migration is one command — `alloy convert --source-format=promtail --output=config.alloy promtail.yml`. An EOL dependency that you have consciously pinned, dated and written down is technical debt. The same dependency on `:latest`, with nobody aware it is dead, is an incident waiting for a maintenance window that never comes. **The difference is entirely whether someone wrote this paragraph.**

**Prometheus pulls.** It scrapes an HTTP endpoint on a schedule. That inverts the usual model and has a useful consequence: the scrape itself is a health check, and `up == 0` tells you a target is unreachable without any extra configuration.

### 3.1 PromQL, the parts you actually need

```promql
# a rate over 5 minutes - ALWAYS use rate() on a counter, never the raw value
rate(http_requests_total[5m])

# error ratio
sum(rate(http_requests_total{status=~"5.."}[5m]))
  / sum(rate(http_requests_total[5m]))

# p99 latency from a histogram
histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))

# CPU utilisation from node_exporter (note: measure IDLE and subtract)
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# memory available
node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100

# disk will be full in under 4 hours - PREDICTION, not a threshold
predict_linear(node_filesystem_avail_bytes{mountpoint="/"}[6h], 4*3600) < 0
```

**`rate()` on counters, always.** A counter only increases and resets to zero on restart. The raw number is meaningless; the rate of change is the signal. `rate()` also handles the resets for you, which is why hand-computing deltas is wrong.

That last query is worth dwelling on. `predict_linear` alerts on **"you will have a problem"** rather than **"you have a problem"** — a disk alert at 80% is arbitrary and fires constantly on a large disk that is filling slowly; an alert that says "full in 4 hours at the current rate" is actionable every time it fires.

### 3.2 Alerting that people do not ignore

**Alert on symptoms, not causes.** "Error rate above 1% for 5 minutes" is worth waking someone. "CPU above 80%" is not — a busy server doing its job is fine, and the alert will fire hundreds of times without ever indicating a problem.

The test for any alert: **if it fires at 3am, is there something a human must do right now?** If not, it is a dashboard, not an alert.

```yaml
groups:
  - name: symptoms
    rules:
      - alert: HighErrorRate
        expr: |
          sum(rate(http_requests_total{status=~"5.."}[5m]))
            / sum(rate(http_requests_total[5m])) > 0.05
        for: 5m                    # ← must persist; ignores single-scrape blips
        labels: { severity: page }
        annotations:
          summary: "5xx rate is {{ $value | humanizePercentage }}"
          runbook: "https://wiki/runbooks/high-error-rate"
```

`for:` is what turns a noisy signal into an alert. Without it, one bad scrape pages someone.

**Alert fatigue is a real, measurable failure mode.** A team that receives 40 alerts a night stops reading them, and then misses the one that mattered. Fewer, better alerts is not laziness — it is the whole design goal.

---

## Day 4 — Reading a system under load

### 3.1 The 60-second triage

Brendan Gregg's checklist. Run it in order on any sick Linux box:

```bash
uptime                 # load averages - trend over 1/5/15 min
dmesg | tail -20       # OOM kills, disk errors, network resets
vmstat 1 5             # r=run queue, si/so=SWAPPING, us/sy/id/wa
mpstat -P ALL 1 3      # per-CPU - is ONE core pinned? (a single-threaded bottleneck)
pidstat 1 3            # per-process CPU over time, unlike top's snapshot
iostat -xz 1 3         # per-device: %util, await (latency!), aqu-sz (queue)
free -m                # available, not free
sar -n DEV 1 3         # network throughput per interface
sar -n TCP,ETCP 1 3    # retransmits - a network-quality signal
top                    # last, not first
```

**What each is really for:**
- `vmstat`'s `r` column is the **run queue** — processes waiting for CPU. Greater than the core count means saturation.
- `vmstat`'s `si`/`so` are **swap in/out**. Anything non-zero on a server is a serious problem: swapping makes latency wildly bimodal.
- `iostat`'s **`await`** is disk latency in milliseconds. `%util` near 100% with low `await` can be fine on SSD/NVMe; high `await` never is.
- `mpstat -P ALL` reveals a single pinned core, which means a single-threaded bottleneck no amount of extra CPU will fix.

### 4.2 Latency triage with curl

```bash
curl -sS -o /dev/null -w \
  'dns=%{time_namelookup} conn=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total}\n' \
  https://app.example.com/api/items
```

| Inflated field | Look at |
|---|---|
| `dns` | the resolver, `/etc/resolv.conf`, upstream DNS latency |
| `conn` | network path, firewall, a full accept backlog |
| `tls` | certificate chain, CPU on the server, handshake settings |
| **`ttfb`** | **the server is thinking.** The network is innocent — go to the app |
| `total` − `ttfb` | body size, bandwidth, compression |

This one command splits "it's slow" into "the network is slow" versus "the server is slow", and those go to completely different people.

### 4.3 Correlating logs with metrics

The workflow, concretely: a metric shows the error rate rising at 14:05. You then need the logs **for that minute**, for that service:

```bash
journalctl -u myapp --since "14:04" --until "14:10" -p err --no-pager
docker compose logs --since 14:04 --until 14:10 api
```

In Loki:

```logql
{service="api"} |= "error" | json | status >= 500
sum(rate({service="api"} |= "error" [5m])) by (level)
```

**This is why structured logging (Week 6) matters.** `| json | status >= 500` is a real filter on a real field. Against free-form text you would be writing a regex against an English sentence that someone will reword next sprint.

---

## Day 5 — Drill

```bash
cd infra
make snapshot VM=obs NAME=pre-w09
make break VM=obs DRILL=09-latency
```

Symptom: *"The site is slow. Not down. Sometimes fine, sometimes five seconds. Nothing was deployed."*

**Three simultaneous causes.** Use USE on each resource. Do not guess.

Afterwards, the cleanup commands are at the bottom of the answer key — `sudo cat /root/.drill-09-latency | base64 -d`. They are not printed here or by the drill itself, because a cleanup command names the fault it cleans up, and two of the three would be handed to you before you had measured anything.

## Recommended reading

- Brendan Gregg — <https://www.brendangregg.com/> — the USE method, the 60-second checklist, flame graphs. Free and canonical
- *Google SRE Book* — **free online** at <https://sre.google/books/> — chapters on monitoring, alerting and postmortems
- Prometheus docs — <https://prometheus.io/docs/> — especially "Instrumentation best practices"
- Grafana Loki docs — <https://grafana.com/docs/loki/latest/>
- *Systems Performance*, Brendan Gregg — the reference, if you buy one book
