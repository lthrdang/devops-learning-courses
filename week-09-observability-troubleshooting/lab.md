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
docker run --rm --entrypoint promtool -v "$PWD/prometheus:/etc/prometheus:ro" \
  prom/prometheus:v3.14.0 check config /etc/prometheus/prometheus.yml
docker run --rm --entrypoint promtool -v "$PWD/prometheus:/etc/prometheus:ro" \
  prom/prometheus:v3.14.0 check rules /etc/prometheus/alerts.yml
```

Expected — the first command prints `SUCCESS: 1 rule files found` (it followed `rule_files:` and validated the file it points at), the second prints `SUCCESS: 8 rules found`. Both exit 0.

> **Look hard at that mount path, because it is the whole point of this step.** The obvious thing to write is `-v "$PWD/prometheus:/p:ro"` — short, and it is only a lab. Do that and `check config` exits **1** with `"/etc/prometheus/alerts.yml" does not exist`, because `prometheus.yml` declares its `rule_files:` as an **absolute path** and an absolute path does not care where *you* chose to mount the directory. The config is right, the container is right, the `-v` flag is wrong.
>
> This is not a promtool quirk. It is the single most common way config validation goes wrong in CI: the pipeline mounts the repo at `/workspace`, the config references `/etc/something`, and the check either fails for the wrong reason or — worse — passes while validating nothing. **Mount the directory where the config says it lives.** If you cannot, make the paths relative and be consistent about the working directory.
>
> Note the pinned `v3.14.0` too. Validating your config with whatever `:latest` resolved to this morning, then running a different Prometheus in the stack, means you validated a different program than the one you are deploying.

Open from your host browser:
- Prometheus — `http://<OBS_IP>:9090` → **Status → Targets**. All four jobs — `prometheus`, `node`, `cadvisor`, `app` — must be `UP`. Check it from the command line too, because the UI makes a down target easy to scroll past:

```bash
curl -s localhost:9090/api/v1/targets \
  | jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.health)\t\(.lastError)"'
```

> The `node` and `app` jobs both target `host.docker.internal`, and on **Docker Engine that name does not exist** — it is a Docker Desktop feature. The compose file earns it with `extra_hosts: ["host.docker.internal:host-gateway"]` on the prometheus service. Delete that line, `docker compose up -d`, and watch both jobs go DOWN with `dial tcp: lookup host.docker.internal`; then put it back. Worth doing once, because the failure is silent everywhere except this page — the USE dashboard just draws nothing and `MemoryPressure`, `DiskWillFillSoon` and `InodesWillRunOut` evaluate happily against no data and never fire.

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
  prom/prometheus:v3.14.0 check metrics
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

Measured result — **four** series, from twenty-four requests across five distinct URLs:

```
http_requests_total{method="GET",route="/items",status="200"} 20
http_requests_total{method="GET",route="/items/:id",status="200"} 2   ← both IDs collapse here
http_requests_total{method="GET",route="/metrics",status="200"} 1
http_requests_total{method="GET",route="/other",status="404"} 2       ← both scans collapse here
```

Count them against what you ran, and account for every one — this is the one exercise whose entire job is to leave you *confident* the instrumentation is right, so a series you cannot explain matters. Only three of those routes came from the commands above. **`/metrics` is there because of step 3.1**: you scraped it once to check the exposition format, and a scrape is a request like any other. (It reads `1`, not `2`, because the counter for the scrape you are reading right now is incremented *after* the response body has been rendered.) Skip 3.1 and you will see three series, which is equally correct.

Now **break it deliberately.** Edit `route_of()` to `return path` and restart:

```bash
for i in $(seq 1 200); do curl -s "localhost:8000/items/$i" >/dev/null; done
curl -s localhost:8000/metrics | grep -c '^http_requests_total{'
```

> 200+ series from 200 requests, and it grows without bound. Extrapolate to a million users. **This is the single most common way teams destroy their own monitoring**, and it always happens at the worst moment because that is when traffic is highest. Restore the function afterwards.

### 3.2b Now measure it on something you did not write — cAdvisor

The million hypothetical users are easy to nod along to. Here is the same failure sitting inside the stack you just started, with real numbers you can count yourself.

cAdvisor's default is `--store_container_labels=true`, which promotes **every Docker label on a container** into a Prometheus label on **every series that container produces**. Compose sets a lot of labels. Count them:

```bash
# how many distinct container_label_* labels does cAdvisor emit?
curl -s localhost:8081/metrics \
  | grep -o 'container_label_[a-z0-9_]*' | sort -u | tee /tmp/cadvisor-labels.txt | wc -l
```

Run the stack once with the two flags in `docker-compose.yml` commented out, and once with them in place:

| `--store_container_labels` | distinct `container_label_*` labels |
|---|---|
| `true` (the default) | **24** |
| `false` + a two-entry allow-list | **2** |

Twenty-four is what this five-container stack measured; the number is not fixed, because it is the union of the Docker labels on whatever you happen to be running. Every extra image with a full set of `org.opencontainers.image.*` labels adds more, so it grows as the stack does — which is precisely the wrong direction for a cardinality problem to grow in.

Read `/tmp/cadvisor-labels.txt` from the first run before you move on. Two entries deserve your attention:

```
container_label_com_docker_compose_config_hash
container_label_com_docker_compose_project_working_dir
```

The second is a **full filesystem path** — which is at least stable. The first is a hash of the compose file, so **it changes every time you edit `docker-compose.yml`**. A changed label value does not update a series; it starts a **new** one and abandons the old. Every edit to a compose file, forever, on every container in the project.

```bash
# total series cAdvisor is producing, before and after
curl -s localhost:8081/metrics | grep -c '^container_'
```

> **This is the same bug as `route_of()` returning the raw path, and it arrived pre-installed.** You did not write cAdvisor and you did not choose its defaults — you just ran the image the internet told you to run, inside the very week that teaches cardinality control. That is the honest lesson: the cardinality bombs you have to find are rarely in your own code. They are in a default you never read. Check the `/metrics` output of anything you deploy, count the labels, and ask which of them can change.

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
{container=~".+"}                                    # every container, raw
{container="obs-prometheus-1"}                       # one container
{container=~".+"} |= "error"                         # substring filter
{container=~".+", stream="stderr"}                   # stdout vs stderr
{job="varlogs", filename="/var/log/auth.log"}        # host files, not containers
{container="obs-loki-1"} | logfmt | level="error"    # parse, then filter a field
{container="obs-grafana-1"} | json | logger="provisioning.alerting"   # JSON producer
sum by (container) (rate({container=~".+"}[5m]))     # a METRIC, out of logs
```

### 4.1b Pick the parser to match the producer

**Two of those queries do the same thing with different parsers, and swapping them gives you nothing — silently.** Run the wrong-parser version and look at what happens:

```logql
{container="obs-prometheus-1"}                       # 1. rows. good.
{container="obs-prometheus-1"} | json                # 2. still rows! read on
{container="obs-prometheus-1"} | json | __error__="" # 3. ZERO
{container="obs-prometheus-1"} | json | level="error"# 4. ZERO
{container="obs-prometheus-1"} | logfmt | level="ERROR"  # 5. rows
```

Measured against the live stack, Loki 3.7.6 (your absolute counts depend on how
long the stack has been up and the range you select — what matters is which
rows are **zero** and which are not, and that rows 1 and 2 are *identical*):

| Query | Result |
|---|---|
| `{container="obs-prometheus-1"}` | N entries (37 in this run) |
| `… \| json` | **the same N** — the parser failed but every line still came through |
| `… \| json \| __error__=""` | **0** — not one of them actually parsed |
| `… \| json \| level="error"` | **0** |
| `… \| logfmt \| level="ERROR"` | the real error lines |

Prometheus 3.x does not log JSON. It logs **logfmt**:

```
time=2026-08-26T03:29:34.371Z level=ERROR source=main.go:1389 msg="Error reloading config" err="..."
```

Loki's Go JSON parser is handed that, fails, and attaches an error label instead of dropping the line:

```
__error__="JSONParserErr"
__error_details__="Value looks like object, but can't find closing '}' symbol"
```

> **Row 2 is the whole lesson.** `| json` did not error your query, did not turn the panel red, and did not return an empty screen — it returned *rows*, so everything looked fine. The failure only surfaced one stage later, when `| level="error"` filtered against a field that was never extracted and quietly matched nothing. **An empty result in Loki looks identical whether the label is wrong, the range is wrong, the parser is wrong, or the logs genuinely are not arriving.** That ambiguity is exactly why people conclude their log tooling is broken and go back to `grep`. `| __error__=""` (or `| __error__!=""` to see the casualties) is how you tell the four apart — make it the first thing you add when a parsed query comes back empty.

**It fails in the other direction too, and just as quietly.** Grafana in this stack is configured with `GF_LOG_CONSOLE_FORMAT=json`, so it is a genuine JSON producer. Point the logfmt parser at it:

| Query | Result |
|---|---|
| `{container="obs-grafana-1"} \| json \| logger="provisioning.alerting"` | rows (3 in this run) |
| `{container="obs-grafana-1"} \| logfmt \| logger="provisioning.alerting"` | **0** |

**One more thing you will trip over, and it is worth understanding rather than memorising.** Try this, with no parser at all:

```logql
{container="obs-grafana-1", level="error"}      # rows, with no parser at all
{container="obs-prometheus-1", level="error"}   # 0 entries
```

`level` is doing double duty. `promtail.yml` has a `json:` pipeline stage that promotes a `level` field to a real stream **label** at ingest — so for JSON producers it is already there before you write any parser, and for logfmt producers the stage extracts nothing and the label is simply absent. That is why the Grafana example above filters on `logger` instead: `logger` is only ever a *parsed field*, so it tests the parser and nothing else. **Know which of the two you are filtering — a label filter and a parsed-field filter are written identically and behave completely differently**: labels are indexed and exist before the query runs, parsed fields are computed per line at query time and vanish if the parser fails.

**And check the case while you are there.** Row 5 needs `level="ERROR"`, uppercase, because Prometheus 3.x logs Go `slog` levels in caps — `{container="obs-prometheus-1"} | logfmt | level="error"` returns **0 rows** against a container that is definitely logging errors. Loki's own logs, two containers away in the same stack, use lowercase `level=error`. Use `level=~"(?i)error"` if you need to span both, and never assume a field's *values* are normalised just because the field name is.

**Three producers, three answers, one stack:**

| Producer | Format | Parser |
|---|---|---|
| Prometheus 3.x, Loki, Promtail | logfmt (`level=INFO` / `level=error`) | `\| logfmt` |
| Grafana, with `GF_LOG_CONSOLE_FORMAT=json` (set in `docker-compose.yml`) | JSON | `\| json` |
| `metered.py` (week 6's habit) | JSON, lowercase `level` | `\| json` |

> **`metered.py` is the honest asterisk on that table.** It really does emit JSON — read `log_message()` — but as Part 3 runs it, `python3 metered.py --port 8000 &` on the host, **its lines never reach Loki at all**. Promtail's `docker` job discovers containers, and its `varlogs` job reads only `/var/log/{syslog,auth.log,nginx/*.log}`. Check for yourself: `curl -s localhost:3100/loki/api/v1/label/container/values` lists containers only. So a query against it comes back empty — not because the parser is wrong, but because **the logs were never shipped**, which is the fourth cause of an empty screen from the box above and the one people diagnose last. If you want it in Loki, containerise it so `docker_sd_configs` finds it; a host process writing to a terminal is invisible to a log shipper no matter how beautifully structured its output is.

That is the argument in `README.md` about structured logging, made concrete: `| json | status >= 500` is a real filter on a real field **only when the producer actually emits that field**. The parser is not a formality you bolt on to every query — it is a claim about the thing on the other end, and it is a claim you can be wrong about without being told.

> **Every label in those queries came out of step 4.1** — you listed them before you queried them. Do that in the order shown. Guessing a label name gets you an empty result set, and an empty result set in Loki looks identical whether the label is wrong, the time range is wrong, or the logs genuinely are not arriving. Three very different problems, one identical screen.
>
> **You will find `{job="systemd-journal"}` in half the Promtail tutorials online, and it does not work here.** The journal reader has to be compiled in — `CGO_ENABLED=1` plus the `promtail_journal_enabled` build tag — and the official `grafana/promtail` image is built with neither. Add the `journal:` scrape config and Promtail starts cleanly, logs one warning, and ships nothing at all. That is why `promtail.yml` has a comment where that job would be instead of the job. Host logs reach Loki here through the `varlogs` file job; if you want the journal properly, that is one of the things Grafana Alloy fixes.

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

**Then look hard at `HighLatency`, because it carries the scars of getting this wrong.** It used to aggregate with `sum by (le)` and no filter. Run both versions against the traffic you generated in 3.3 and compare:

```promql
# the OLD expression: every route of every job blended into one distribution
histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))

# the CURRENT expression, per route
histogram_quantile(0.99,
  sum by (job, route, le) (rate(http_request_duration_seconds_bucket{route!="/slow"}[5m])))
```

> The blended number was measured at **3.22** on this lab's own synthetic load — over the 2s threshold, at `severity: page`, with nothing wrong. `/slow` is doing exactly what it was written to do and it pages you for it. That is the false positive. The false *negative* is quieter and worse: a p99 computed across all traffic cannot be moved by an endpoint serving 1% of it, so a genuinely broken route stays invisible behind healthy volume from everything else. **A global p99 is not a summary of your service, it is a summary of your traffic mix** — and the traffic mix changes without you.

**Now the question that exclusion is hiding.** `route!="/slow"` is honest here because `/slow` is a test fixture. But suppose `/slow` were real — a report export that legitimately takes six seconds, and whose users are perfectly happy about that. You cannot exclude it (nobody would notice when it broke) and you cannot hold it to 2s (it would page forever). Write down what you would actually do.

There is no expression that solves this, and that is the point: you have hit the limit of what a single global threshold can express. The answer is a **per-route latency objective** — `/api/items` 200ms, `/reports/export` 10s — recorded as data rather than hard-coded in a rule, with the alert comparing each route against *its own* budget. Once you are writing that down you have started writing SLOs, and the follow-on question ("how much of the month's budget has this burned?") is what error-budget burn-rate alerting answers. **That is challenge C9.1 this week** — do it after this lab, with this question fresh.

### 5.3 Prove that an alert can fire — the audit nobody does

Every rule in that file passes `promtool check rules`. That proves the YAML parses and the PromQL is syntactically legal. It proves **nothing** about whether the expression measures what it claims to.

`ContainerRestartLoop` used to read:

```promql
rate(container_start_time_seconds[15m]) > 0
```

Read it. It looks right. Now go and test it, with a real crash loop of your own:

```bash
docker run -d --name loopy --restart=always alpine sh -c 'sleep 45; exit 1'
sleep 300
docker inspect -f '{{.RestartCount}}' loopy       # ← the ground truth
```

> **Why `sleep 45` and not `sleep 5`?** Try `sleep 5` first and look at what Prometheus has: `count_over_time(container_start_time_seconds{name="loopy"}[15m])` returns **2 samples in fifteen minutes**. cAdvisor housekeeps every 10s and Prometheus scrapes every 15s, so a container that only exists for 5 seconds at a time is almost never *observed alive*. **No expression can alert on data that was never sampled.** That is a lesson in its own right, and it is worth thirty seconds of your time before you move on — your sampling interval sets a hard floor on what you are able to detect at all.

Now run all four against the observable loop:

```promql
container_start_time_seconds{name="loopy"}
rate(container_start_time_seconds{name="loopy"}[15m])
changes(container_start_time_seconds{name="loopy"}[15m])
sum by (name) (changes(container_start_time_seconds{name!=""}[15m]))
```

Measured here, against `RestartCount = 4`:

| Expression | Result |
|---|---|
| `rate(...)` | **0.219** |
| `changes(...)` | 4 on the live series, 1 on a stale one |
| `sum by (name) (changes(...))` | **5** — and **0** for all twelve healthy containers |

So the old rule *did* produce a non-zero number. That is worse than being broken, not better. **`rate()` is for counters, and this metric is a gauge holding a unix timestamp.** Ask what 0.219 is supposed to *mean*: `rate()` took "the start time jumped forward by about 200 seconds", divided it by the 900-second window, and returned seconds per second. It is not a restart count, it is not a frequency, it is not anything. And because *any* value passes `> 0`, the rule fires identically for one ordinary redeploy and for a container looping every forty seconds — which is the single distinction the alert existed to make.

There is a second failure mode underneath it. cAdvisor keys containers by cgroup, so a restart can land in a **brand-new series** whose value is flat from birth — `rate()` over that is exactly 0 and the restart disappears. The rewritten rule uses `changes()`, which is the right primitive for a gauge, and sums by `name` so that restarts split across several series still add up.

Clean up with `docker rm -f loopy`.

> **`promtool check rules` is a syntax checker, not a proof.** The only proof that an alert works is that you made it fire — and that you looked at the number it produced and could say what the number means. Do this once for every rule you write. It takes ten minutes and it is the difference between monitoring and the appearance of monitoring.

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

Timebox 45 minutes. Afterwards, read the answer key — the cleanup commands are the last three lines of it:

```bash
sudo cat /root/.drill-09-latency | base64 -d
```

> **The cleanup steps are deliberately not printed here, and the drill script no longer prints them either.** They used to be, and it gave the game away: `pkill stress-ng` names the CPU fault and `tc qdisc del` names the network fault, so two of the three causes were handed to you in the banner before you had run a single command. A cleanup command is an answer wearing a hard hat.
