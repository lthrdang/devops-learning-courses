# Week 12 — Assessment guide & discussion

*For the trainer, and for a learner self-assessing honestly.*

---

## The exit checklist

A junior platform engineer, ready to be useful on a team, can do all of these
**without help**. Tick them honestly; an untested tick is worth nothing.

### Linux
- [ ] Navigate, inspect and modify a system entirely from the shell
- [ ] Explain the difference between `r`/`w`/`x` on a file and on a **directory**
- [ ] Find which process holds a deleted file consuming disk space
- [ ] Read `df -h` **and** `df -i`, and know why both matter
- [ ] Write a systemd unit, explain `enabled` vs `active`, and use `systemctl cat`
- [ ] Find any log on any Linux box, including the previous boot's

### Scripting
- [ ] Write Bash with `set -euo pipefail`, proper quoting, traps and locking
- [ ] Explain why `(( count++ ))` can kill a script under `set -e`
- [ ] Pass `shellcheck` cleanly, and justify any suppression
- [ ] Write a Python CLI with argparse, logging, retries and tests
- [ ] Say when Bash is the wrong tool, and why

### Networking
- [ ] Diagnose "X cannot reach Y" layer by layer, without guessing
- [ ] Explain **refused vs timed out** and what each implies
- [ ] Read `ss -tlnp` and spot a service bound to `127.0.0.1`
- [ ] Use `tcpdump` to determine whether a packet arrived
- [ ] Explain why `ping` succeeding proves very little

### HTTP & proxies
- [ ] Triage 500 vs 502 vs 503 vs 504 and say who owns each
- [ ] Configure a reverse proxy with correct `X-Forwarded-*` headers
- [ ] Read `curl -w` timings and say whether it is the network or the server
- [ ] Explain TLS termination, SNI, and why a missing intermediate breaks curl but not a browser

### Containers
- [ ] Explain what a container is in terms of namespaces and cgroups
- [ ] Write a Dockerfile that is small, non-root, cached well and stops gracefully
- [ ] Explain why the shell form of `CMD` breaks `SIGTERM`
- [ ] Debug a crash-looping container that `docker ps` shows as "Up"
- [ ] Explain exit code 137 and what to check first

### Orchestration
- [ ] Deploy a stack to Swarm and explain desired-state reconciliation
- [ ] Perform a zero-downtime rolling update and **prove** it with a counter
- [ ] Diagnose a `PENDING` task, and distinguish it from `REJECTED`
- [ ] Explain quorum and why two managers is worse than one

### Observability & troubleshooting
- [ ] Apply USE and RED appropriately
- [ ] Explain why percentiles beat averages, with the 50-calls-per-page argument
- [ ] Recognise and prevent a cardinality bomb
- [ ] Run the 60-second triage and form a correct hypothesis
- [ ] **Investigate an unknown fault with a written hypothesis trail**

### Production
- [ ] Harden SSH without locking themselves out
- [ ] Explain why Docker bypasses ufw, and what to do about it
- [ ] Perform a **verified** restore and state the measured RTO
- [ ] Build a pipeline that refuses to ship broken things
- [ ] Rotate a credential with zero downtime, in the correct order

### Judgement — the part that cannot be crammed
- [ ] Say "I don't know, here is how I would find out"
- [ ] Mitigate before understanding, under pressure
- [ ] Write a blameless postmortem
- [ ] **Name the weakest part of their own system, precisely**

---

## Grading the game day

This is 25% of the assessment and the least fakeable part.

| Level | What it looks like |
|---|---|
| **Excellent** | Broad-then-narrow. Every hypothesis written with its test. Mitigates in parallel with investigating. **Keeps going after the first fault is fixed.** Notices non-discriminating tests and abandons them. Status updates say what was ruled out |
| **Good** | Systematic, finds most faults, occasionally goes deep too early, recovers when a test disproves them |
| **Adequate** | Finds one fault by working through the layers; stops when the symptom improves; the trail exists but is thin |
| **Not yet** | Restarts things. Changes several at once. Stays in the familiar component. No written trail — so cannot say what was ruled out |

**The single strongest signal is what happens after the first fix.** The symptom improves, the pressure drops, and the untrained engineer declares victory. The trained one asks: *"does this cause explain **all** of what I saw?"* That question is what the multi-fault game day exists to provoke, and it is the habit that most reliably prevents a repeat incident an hour later.

---

## Common capstone failure modes

| Symptom | What it really means | The fix |
|---|---|---|
| Still writing application code on Day 3 | scope not cut | features are 0% of the grade; operability is 20% |
| `/health` checks the database | one database blip removes **every** replica | Week 5 §4.3 — check narrowly, expose a separate deep-health endpoint |
| Metric labelled with the short code | a cardinality bomb, in the worst possible domain | route templates, always |
| Backups exist, never restored | a hope, not a backup | the restore drill, with a stopwatch |
| Dashboard with 20 panels | nobody can use it under pressure | six panels; the most important one top-left |
| Alerts on CPU > 80% | trains everyone to ignore alerts | alert on symptoms |
| README says "run docker compose up" | untested documentation | give it to a stranger |
| Runbook written after the incident | it was not there when needed | write it when you build the alert |

---

## The three questions worth asking in review

1. **"A user says it's slow. What do you do first?"**
   Weak: names a component. Strong: *"I'd get a number first — `curl -w` for the timing breakdown, to find out whether it's the network or the server before I touch anything."*

2. **"Your health check — what does it deliberately not check?"**
   Weak: has not thought about it. Strong: *"It doesn't check Redis, because we can serve without it, and it doesn't check the database with a query, because a database blip would fail every replica's check at once and turn degradation into a total outage."*

3. **"What are you least confident about in this system?"**
   Weak: "I think it's all pretty solid." Strong: a specific, honest answer — *"the cache invalidation on link updates; I tested the happy path but I don't have a test for the race between a write and a concurrent read, and I'm not certain it's correct."*

**Hire the third answer.** An engineer who knows precisely where their own uncertainty lives will find problems before customers do. One who believes everything is solid will be surprised, in production, at 3am.

---

## A note for the trainer

The strongest predictor of who finishes this course able to work is not aptitude
in Week 1. It is **whether they kept the logbook**, and specifically whether
they used the *"what I still don't understand"* heading honestly and revisited
it.

Learners who write that section and return to it convert confusion into
knowledge on a schedule. Learners who leave it empty are usually the ones who
looked at `solutions.md` at minute ten. The timebox is not bureaucracy — the
45 minutes of productive stuckness *is* the mechanism by which this material is
learned, and every shortcut around it is a shortcut around the course.
