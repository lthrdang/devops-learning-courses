# Week 12 — Lab: the five days

---

## Day 1 — Build it

Start from the repository you have been accumulating. **Do not start from scratch** — Week 8's stack, Week 9's observability and Week 10's Swarm config are the foundation.

```bash
cd infra && make w12-up
./scripts/lab-up.sh hosts node1 node2 node3
# on node1:
./swarm-init.sh init "$(hostname -I | awk '{print $1}')"
```

### Suggested repository layout

```
linkr/
├── README.md                 # how to deploy, operate and recover it
├── .gitea/workflows/ci.yml
├── api/
│   ├── Dockerfile
│   ├── app.py
│   └── tests/
├── stack.yml
├── observability/            # week 9's compose stack
├── runbooks/
│   ├── high-error-rate.md
│   ├── replicas-below-desired.md
│   └── disk-filling.md
└── scripts/
    ├── backup-verify.sh
    ├── smoke-test.sh
    └── load-test.sh
```

**Build order that avoids rework:**

1. The API, running locally, with tests. Prove the logic first.
2. Containerise it (Week 7 rules: non-root, exec-form `CMD`, healthcheck, `.dockerignore`).
3. Compose stack with Postgres and Redis, working locally.
4. Registry, push, `docker stack deploy`.
5. **Only then** observability, backups and CI.

> Getting to step 4 by the end of Day 1 is the goal. If you are still writing application code on Day 2, cut scope — the assessment weights operability at four times the weight of features.

### Design decisions to make deliberately, and write down

- **Code generation:** random, or a hash of the URL? What happens on collision?
- **The cache:** what do you cache, for how long, and what happens on a cache miss versus a cache *outage*? (Requirement 5 says degrade, not fail.)
- **Hit counting:** incrementing a database row on every redirect makes every read a write. What are the alternatives, and what do they cost you in accuracy?
- **Health:** what exactly does `/health` check, and what does it deliberately *not* check? (Week 5 §4.3 — the trap where checking the database takes every replica out at once.)

---

## Day 2 — Make it operable

### 2.1 Observability

```bash
# metrics - week 9 rules
#   RED for HTTP, bounded route labels, a histogram for latency
curl -s localhost:8000/metrics | docker run --rm -i --entrypoint promtool \
  prom/prometheus:latest check metrics
```

Cardinality check — **do this before you deploy, not after**:

```bash
for i in $(seq 1 200); do curl -s "localhost:8000/$(openssl rand -hex 4)" >/dev/null; done
curl -s localhost:8000/metrics | grep -c '^http_requests_total{'
```

> A URL shortener is the *worst possible* case for cardinality: every path is a unique code. If that number grew with the loop, your `route_of()` is wrong and you will kill Prometheus in production. It must stay constant.

### 2.2 Dashboard and alerts

One dashboard, at most six panels, answering *"is it healthy, and if not, which layer?"* in under ten seconds without scrolling.

At least three alert rules. For each, answer honestly: **if this fires at 3am, is there something a human must do right now?**

### 2.3 Backups and CI

```bash
./scripts/backup-verify.sh backup
./scripts/backup-verify.sh verify /var/backups/pg/<latest>
```

Pipeline: test → build → scan → push → deploy → smoke test → rollback on failure. **Prove each gate by breaking it.**

---

## Day 3 — Prove it

Everything today produces a **number** you write down. Claims without measurements do not count.

### 3.1 Load

```bash
docker run --rm --network host williamyeh/hey \
  -z 60s -c 50 http://node1:8080/api/stats
```

Record: requests/second, p50, p95, p99, error rate. Then find the point where p99 exceeds 500 ms and record the request rate at which that happens. **That is your capacity number.**

### 3.2 Failure injection — the required experiments

| Experiment | Measure |
|---|---|
| Hard-stop a node (`multipass stop node3`) | failed requests, time to reschedule |
| Stop Redis | does it degrade or fail? error rate during |
| Stop Postgres | correct status code? (503, not 500) does it recover **without a restart**? |
| Rolling deploy under load | failed requests — target zero |
| Deploy a broken image | does it auto-roll-back? how long? |
| Fill the disk on one node | what breaks first, and did an alert fire before it did? |

Use a failure counter, not your eyes:

```bash
ok=0; bad=0
trap 'echo "OK=$ok FAILED=$bad"; exit' INT
while true; do
  curl -sf -m3 -o /dev/null http://node1:8080/api/stats && ok=$((ok+1)) || { bad=$((bad+1)); echo "$(date +%T.%3N) FAIL"; }
  sleep 0.2
done
```

### 3.3 Recovery

```bash
# destroy the database and restore it, against a stopwatch
./scripts/backup-verify.sh restore <backup> --yes
```

Record the RTO. Then answer: what would halve it?

### 3.4 Exposure audit

From outside the cluster: `nmap -Pn -p- <each node>`. Justify every open port.

---

## Day 4 — Game day

```bash
cd infra
make snapshot VM=node1 NAME=pre-gameday
make snapshot VM=node2 NAME=pre-gameday
make break VM=node1 DRILL=12-gameday
```

You get: **"Checkout is failing for some users." SEV-2.**

Start a timer. Open a file called `incident-log.md` and write in it as you go:

```markdown
## 14:34 — acknowledged
STATUS UPDATE POSTED: impact ~?, investigating.

## 14:36 — H1: bad deploy?
TEST: docker service ps linkr_api --format '{{.Name}} {{.Image}}'; docker image ls
RESULT: last image 3 days old. DISPROVED.

## 14:41 — H2: ...
```

**Rules:** status update within 10 minutes · mitigate before you understand · every hypothesis written down with its test · timebox 90 minutes.

Afterwards:

```bash
multipass exec node1 -- sudo cat /root/.drill-12-gameday | base64 -d
```

Compare your trail with the truth. The questions that matter:

1. Which hypothesis took longest, and what would have disproved it faster?
2. Did you run any test whose result could not have distinguished anything?
3. Did you find **all** the faults, or stop when the symptom improved?
4. What single alert or dashboard panel would have cut the time most?

Then restore and, if you have time, **run it again with a different seed**:

```bash
make restore VM=node1 NAME=pre-gameday
make break VM=node1 DRILL=12-gameday   # edit the script's SEED argument
```

The second run is where the improvement shows.

---

## Day 5 — Write it up and defend it

**Morning — the postmortem.** Use `files/postmortem-template.md`. Timeline with real timestamps including the wrong turns. Action items with owners and dates.

**Midday — the README test.** Hand your repository to someone who has never seen it and ask them to deploy it from scratch and diagnose a fault you introduce. Every question they must ask you is a defect in your documentation. Fix them.

**Afternoon — the review.** Present for 20 minutes and take questions for 20. Expect:

- "Walk me through what happens when I `curl` your short link."
- "A user says it's slow. What do you do first, and why that?"
- "Your health check — what does it deliberately not check, and why?"
- "You have 3 replicas and a node dies. Describe the next 60 seconds."
- "Show me a metric label that would have killed Prometheus, and how you avoided it."
- "What in this system are you least confident about?"

**That last question is the real one.** An engineer who can name the weakest part of their own system, precisely, is far more trustworthy than one who claims everything is solid. Prepare an honest answer — it is the strongest thing you can say in the review.
