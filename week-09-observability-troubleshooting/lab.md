# Week 09 — Lab

```bash
cd infra && make w09-up && multipass shell obs
# copy files/ into the VM, then:
cd /opt/lab/w09
```

---

## Part 1 — Read a healthy system first (Day 1)

**You cannot recognise abnormal without having looked at normal.** Before anything else, capture a baseline.

```bash
uptime ; nproc
vmstat 1 5
mpstat -P ALL 1 3
iostat -xz 1 3
free -m
sar -n DEV 1 3
```

Save all of it: `{ uptime; vmstat 1 5; free -m; } > ~/baseline-healthy.txt`

Write down, in your logbook:
- load average versus core count;
- `vmstat`'s `r` (run queue) and `wa` (I/O wait) at rest;
- `si`/`so` — should be **0**;
- `iostat`'s `await` for your main device.

Now generate load and watch the same numbers move:

```bash
stress-ng --cpu 2 --timeout 30s &
vmstat 1 10          # watch r climb, id fall
mpstat -P ALL 1 5    # is the load spread or on one core?
uptime               # load average lags - note HOW LONG it takes to react
```

```bash
stress-ng --vm 1 --vm-bytes 60% --vm-keep --timeout 30s &
vmstat 1 10          # watch free fall, and si/so if it reaches swap
free -m
```

```bash
stress-ng --io 4 --hdd 2 --timeout 30s &
iostat -xz 1 10      # %util, await, aqu-sz
vmstat 1 10          # note that wa rises and CPU is NOT the problem
```

> **The last one is the important one.** I/O saturation raises the load average without raising CPU usage. An engineer who only looks at `top` sees a high load and idle CPUs and concludes the machine is fine.

---

## Part 2 — Stand up the stack (Day 3)

```bash
cd /opt/lab/w09/obs
docker compose up -d
docker compose ps
```

```bash
# validate BEFORE trusting anything - promtool is the ground truth
docker run --rm --entrypoint promtool -v "$PWD/prometheus:/p:ro" \
  prom/prometheus:latest check config /p/prometheus.yml
docker run --rm --entrypoint promtool -v "$PWD/prometheus:/p:ro" \
  prom/prometheus:latest check rules /p/alerts.yml
```

Expected: `SUCCESS: 8 rules found`.

Open from your host browser:
- Prometheus — `http://<OBS_IP>:9090` → **Status → Targets**. Everything must be `UP`. A `DOWN` target here is your first exercise.
- Grafana — `http://<OBS_IP>:3000` (admin/admin)

```bash
# 2.1 node_exporter runs on the HOST, not in a container. Confirm and reason.
curl -s localhost:9100/metrics | head -5
curl -s localhost:9100/metrics | grep -c '^node_'
systemctl status prometheus-node-exporter
```

> Why not containerise it? A container sees a namespaced `/proc` and `/sys`, so host metrics gathered inside one are subtly wrong. This is a mistake teams ship to production and then puzzle over.

---

## Part 3 — Instrument an application (Day 2–3)

```bash
cd /opt/lab/w09/app
python3 metered.py --port 8000 &
curl -s localhost:8000/metrics | head -20
```

```bash
# 3.1 Validate the exposition format
curl -s localhost:8000/metrics | docker run --rm -i --entrypoint promtool \
  prom/prometheus:latest check metrics
```

Clean output means it is valid.

### 3.2 See cardinality control working

```bash
for i in $(seq 1 20); do curl -s localhost:8000/items > /dev/null; done
curl -s localhost:8000/items/12345 >/dev/null
curl -s localhost:8000/items/99999 >/dev/null
curl -s localhost:8000/some-scanner-path >/dev/null
curl -s localhost:8000/another-random-url >/dev/null

curl -s localhost:8000/metrics | grep '^http_requests_total{'
```

Measured result — **five** series, despite five distinct URLs:

```
http_requests_total{method="GET",route="/flaky",status="200"}
http_requests_total{method="GET",route="/items",status="200"}
http_requests_total{method="GET",route="/items/:id",status="200"}     ← both IDs collapse here
http_requests_total{method="GET",route="/metrics",status="200"}
http_requests_total{method="GET",route="/other",status="404"}         ← both scans collapse here
```

Now **break it deliberately.** Edit `route_of()` to `return path` and restart:

```bash
for i in $(seq 1 200); do curl -s "localhost:8000/items/$i" >/dev/null; done
curl -s localhost:8000/metrics | grep -c '^http_requests_total{'
```

> 200+ series from 200 requests, and it grows without bound. Extrapolate to a million users. **This is the single most common way teams destroy their own monitoring**, and it always happens at the worst moment because that is when traffic is highest. Restore the function afterwards.

### 3.3 Generate a realistic latency distribution

```bash
for i in $(seq 1 300); do curl -s localhost:8000/slow >/dev/null; done &
for i in $(seq 1 300); do curl -s localhost:8000/flaky >/dev/null; done &
wait
```

In Prometheus, run these and compare the answers:

```promql
rate(http_requests_total[5m])

sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))

histogram_quantile(0.50, sum by (le) (rate(http_request_duration_seconds_bucket{route="/slow"}[5m])))
histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{route="/slow"}[5m])))

# and the average, for contrast:
rate(http_request_duration_seconds_sum{route="/slow"}[5m])
  / rate(http_request_duration_seconds_count{route="/slow"}[5m])
```

> **Write the p50, p99 and the average into your logbook.** The gap between the average and the p99 is the entire argument for percentiles, and seeing it on your own data is more persuasive than any explanation.

---

## Part 4 — Logs (Day 3)

```bash
# 4.1 Confirm Promtail is shipping
curl -s "http://localhost:3100/loki/api/v1/labels" | jq
curl -s "http://localhost:3100/loki/api/v1/label/container/values" | jq
```

In Grafana → **Explore** → Loki datasource:

```logql
{job="systemd-journal"}
{job="systemd-journal", unit="ssh.service"}
{container=~".+"} |= "error"
{container="obs-prometheus-1"} | json | level="error"
sum by (container) (rate({container=~".+"}[5m]))
```

### 4.2 The correlation workflow — practise it

```bash
# generate a burst of errors at a known time
date
for i in $(seq 1 200); do curl -s localhost:8000/flaky >/dev/null; done
date
```

Now, in Grafana:
1. On a **Prometheus** panel, find the error-rate spike and note the exact minute.
2. Switch to **Explore → Loki** and query that same minute.
3. Confirm the log lines explain what the metric showed.

> That two-step — *metric to localise, log to explain* — is the core observability workflow. Do it until it is muscle memory, because under pressure you will not invent it.

---

## Part 5 — Dashboards and alerts (Day 3–4)

Build a RED dashboard for the app, by hand, in Grafana. Four panels:

| Panel | Query |
|---|---|
| **Rate** | `sum(rate(http_requests_total[5m])) by (route)` |
| **Errors** | `sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))` |
| **Duration** | p50, p95 and p99 as three series on one panel |
| **In flight** | `app_in_flight_requests` |

Then a USE dashboard for the host: CPU utilisation, **run queue** (saturation), memory available, disk `await`, network throughput.

> Note which panel you would look at *first* during an incident, and arrange the dashboard so that panel is top-left. A dashboard whose most important number requires scrolling has failed at its only job.

```bash
# 5.1 Make an alert fire, for real
curl -s "http://localhost:9090/api/v1/rules" | jq -r '.data.groups[].rules[].name'

# drive the error rate above 5% and hold it
while true; do curl -s localhost:8000/flaky >/dev/null; done &
sleep 360        # the rule has for: 5m
curl -s "http://localhost:9090/api/v1/alerts" | jq
kill %1
```

Watch it move `inactive → pending → firing`. **`pending` is the `for:` clause working** — that is the state that stops a single bad scrape from paging someone.

### 5.2 Audit the alert rules

For each of the 8 rules in `alerts.yml`, answer:
- Would it fire at 3am? Is there something a human must do immediately?
- Is it a symptom or a cause?
- What is its false-positive rate likely to be?

Then propose one rule to **delete** and one to **add**. Deleting is harder and more valuable.

---

## Part 6 — The 60-second triage, drilled

Run the full checklist on a healthy machine. Then have someone (or a script) apply an unknown load, and run it again, timing yourself.

```bash
uptime ; dmesg | tail -20 ; vmstat 1 5 ; mpstat -P ALL 1 3
pidstat 1 3 ; iostat -xz 1 3 ; free -m ; sar -n DEV 1 3 ; sar -n TCP,ETCP 1 3
```

**Target: form a correct hypothesis about which resource is saturated within 60 seconds.**

---

## Part 7 — Drill (Day 5)

```bash
# host
cd infra
make snapshot VM=obs NAME=pre-w09
make break VM=obs DRILL=09-latency
```

Symptom: *"The site is slow. Not down. Sometimes fine, sometimes five seconds. Nothing was deployed."*

**Three simultaneous causes.** Before you start:

1. Write down the problem statement properly (step 1 of the method).
2. Write down three hypotheses and the single cheapest test for each.
3. Only then start typing.

Timebox 45 minutes. Afterwards:

```bash
sudo pkill stress-ng
sudo tc qdisc del dev $(sudo cat /root/.drill09-iface) root
```
