# Week 12 — Capstone: Build, Operate, Break, Explain

**VM profile:** `make w12-up` → `node1`, `node2`, `node3`
**This week you are not taught anything new.** You are given a system to build, then you are put on call for it.

---

## The shape of the week

| Day | You are |
|---|---|
| **1** | An engineer given a spec. Build it. |
| **2** | An engineer making it production-ready: observable, backed up, deployable. |
| **3** | An engineer proving it. Load, failure injection, evidence. |
| **4** | **On call.** Game day. Unknown faults, no hints, a stopwatch. |
| **5** | An engineer writing it up, and being reviewed. |

The deliverable is not "it works". The deliverable is **a system somebody else could operate from your documentation**, plus evidence that you know how it fails.

---

## The specification

Build **Linkr**, a URL shortener. It is deliberately boring: the interest is entirely in operating it.

### Functional requirements

| Endpoint | Behaviour |
|---|---|
| `POST /api/links` | `{"url": "https://..."}` → `{"code": "a1b2c3", "short": "http://host/a1b2c3"}` |
| `GET /{code}` | `302` redirect to the target URL; `404` if unknown |
| `GET /api/links/{code}` | metadata: target, created time, hit count |
| `GET /api/stats` | totals: links, hits, top 10 codes |
| `GET /health` | readiness (Week 5 §4.3 rules apply) |
| `GET /metrics` | Prometheus exposition (Week 9 rules apply) |

### Non-functional requirements — the actual assignment

1. **Runs on the 3-node Swarm**, with the API at ≥3 replicas.
2. **Survives any single node being hard-stopped**, with a measured, documented request-failure count.
3. **Zero-downtime deploys**, proven with a request loop and a failure counter.
4. **Persistent storage** — links survive a full stack restart.
5. **Redis cache** in front of the database for lookups, and the service must **degrade, not fail**, when Redis is unavailable.
6. **Observability**: RED metrics with bounded label cardinality, structured JSON logs, a dashboard, and at least three alert rules that would each wake someone for a good reason.
7. **Verified backups**: automated, and a restore drill with a measured RTO.
8. **CI/CD**: commit → test → build → scan → push → deploy → smoke test → rollback on failure.
9. **Hardened**: non-root containers, resource limits, no published database port, secrets not in environment variables or images.
10. **Documented**: a README someone else can follow, and one runbook per alert.

### Constraints

- Free and open-source only.
- Your own code in Python or Bash — no framework that does the operational work for you.
- Everything reproducible from a git repository plus `cloud-init`. **If you configured it by hand and did not write it down, it does not exist.**

---

## What is being assessed

You are not being marked on elegant code. You are being marked on the things that make a junior platform engineer trustworthy:

| Weight | Dimension | Evidence |
|---|---|---|
| 25% | **Troubleshooting** | the game-day timeline: hypotheses, tests, dead ends, time to mitigation |
| 20% | **Operability** | can a stranger deploy, diagnose and recover it using only your docs? |
| 15% | **Observability** | do your metrics and logs answer the question *"why is it slow?"* |
| 15% | **Resilience** | measured behaviour under node loss, dependency loss, and bad deploys |
| 10% | **Security** | exposure audit, secret handling, least privilege |
| 10% | **Automation** | is the pipeline real, and does it refuse to ship broken things? |
| 5% | **Communication** | the postmortem, and the status updates you wrote during game day |

Note what is worth the most. **Building it is the price of entry; operating it is the assessment.**

---

## Day 4 — Game day

This is the point of the week.

```bash
cd infra
make snapshot VM=node1 NAME=pre-gameday
make break VM=node1 DRILL=12-gameday        # or: DRILL=12-gameday with a seed
```

You get one line:

> **"Checkout is failing for some users." SEV-2. Reported just now.**

Nothing else. Several faults are active simultaneously, drawn from a pool that includes disk pressure, a paused node, packet loss, clock skew, and a file-descriptor limit. Some runs have two faults; some have four.

### The rules of engagement

1. **A status update within 10 minutes.** One line: what you know, what the impact is, what you are doing. Write it even though nobody is reading it — under real pressure this is the discipline that keeps an incident coordinated.
2. **Mitigate before you understand.** A rollback at minute 5 beats a root cause at minute 90. Users do not care why.
3. **Write down every hypothesis and its test, as you go**, with timestamps. This is the artefact being assessed, more than the fix.
4. **Timebox at 90 minutes.** Then reveal, and compare your trail with what actually happened.

```bash
multipass exec node1 -- sudo cat /root/.drill-12-gameday | base64 -d
```

### What good looks like

- The first three commands are **broad**, not deep: `docker service ls`, `df -h`, `uptime`. You are locating the problem, not solving it.
- You **write down what you ruled out**, and how. This is the most valuable thing you can hand the next person.
- You notice when a test **could not have distinguished anything** and do not count it as progress.
- You mitigate a symptom while still investigating, rather than serialising.
- When you are stuck, you go **down a layer** rather than sideways.

### What bad looks like

- Restarting things hopefully.
- Changing four things and re-testing.
- Spending forty minutes in the component you know best because it is comfortable.
- Finding one fault and stopping, because the symptom improved.

That last one is the trap the game day is specifically built to catch, and it is why several faults run at once.

---

## Day 5 — The postmortem

Write it using `files/postmortem-template.md`. It must be **blameless**: describe what the system allowed to happen, not who did it. The reason is practical rather than moral — people who expect blame hide information, and an incident review without information is theatre.

The two sections that matter most:

- **Timeline** — with real timestamps, including how long you spent on the wrong hypothesis. That number is more instructive than the fix.
- **What would have made this faster?** — an alert that did not exist, a dashboard panel that was missing, a runbook that was wrong. Each of these becomes an action item, and **every action item needs an owner and a date or it is a wish**.

Then present it to someone and be questioned. Being able to explain an incident calmly, without defensiveness, to someone who was not there is a genuine professional skill and it is the last thing this course asks of you.

---

## After this course

You are a junior platform engineer. The next six months, in order:

1. **Kubernetes** — now, and not before. You know scheduling, service discovery, rolling updates, health checks and desired state; K8s is those ideas with more surface area. Start with `kind` or `k3s` locally. The free *Kubernetes the Hard Way* is excellent once you can already operate a cluster.
2. **Terraform** — infrastructure as code against a real provider. `cloud-init` gave you the mindset; Terraform gives you state, dependency graphs and drift detection.
3. **A cloud provider, deeply** — one, not three. IAM and networking are where the difficulty actually is, not the compute.
4. **Go** — most of this ecosystem is written in it, and reading Docker's or Prometheus' source stops being intimidating.
5. **CI/CD at scale** — multi-environment promotion, artefact provenance, GitOps (Argo CD, Flux).

And the habit that matters more than any of them: **keep the logbook.** The engineers who progress fastest are the ones who write down what broke and why, and re-read it.
