# Assessment

How to tell, honestly, whether this course worked.

---

## 1. Weekly checkpoints

Each week has a single question. If you cannot answer it **from memory, out loud, to another person**, you are not ready for the next week — go back rather than forward. Falling behind compounds; this course is built so that Week 9 assumes Week 4.

| Week | The question | Pass means |
|---:|---|---|
| 00 | *Rebuild your lab VM from scratch.* | under 3 minutes, from a file, with no manual steps |
| 01 | *A script can't write to a directory it has read access to. Why?* | you explain directory `w`/`x` without hedging |
| 02 | *A service works now and is dead after every reboot. Why?* | `enabled` vs `active`, and you check with `systemctl cat` |
| 03 | *Show me a script that reports success while doing nothing.* | you can write one, and then the version that cannot |
| 04 | *`curl` times out. `curl` is refused. What differs?* | dropped vs RST, and which layer each sends you to |
| 05 | *You get a 502. Where do you look, in order?* | nginx `error.log`, and the errno tells you which of four causes |
| 06 | *When would you not write this in Bash?* | a specific boundary, with reasons, not a preference |
| 07 | *`docker ps` says Up. Users see connection reset. Explain.* | crash loop; `docker ps -a`, RestartCount, `docker logs` |
| 08 | *All containers Up, every request 500. First three commands?* | app logs, `compose config`, `exec ... env` |
| 09 | *"It's slow." What do you do first?* | get a number — `curl -w` — before touching anything |
| 10 | *You scaled to 6, you have 4. Why?* | `service ps --no-trunc`, then `node ls` **both columns** |
| 11 | *How long to recover from total loss of the database host?* | a **measured** number, not an estimate |
| 12 | *What is the weakest part of your own system?* | a specific, honest answer |

---

## 2. The exit checklist

The full list is in [week-12-capstone/solutions.md](week-12-capstone/solutions.md). Tick honestly — an untested tick is worth nothing, and the person it misleads is you.

---

## 3. Grading the capstone

| Weight | Dimension |
|---|---|
| 25% | Troubleshooting — the game-day hypothesis trail |
| 20% | Operability — can a stranger run it from your docs? |
| 15% | Observability |
| 15% | Resilience — **measured**, not claimed |
| 10% | Security |
| 10% | Automation |
| 5% | Communication |

**Building it is the price of entry. Operating it is the assessment.**

---

## 4. What "junior platform engineer" actually means

Not: knows every tool. Not: can recite the OSI layers.

**It means:** given a system they did not build and a symptom they have not seen, they make measurable progress toward the cause without breaking anything, and they can explain what they did afterwards.

Everything in this course serves that sentence.

---

## 5. Signals you are ready — and signals you are not

**Ready:**
- You reach for `ss -tlnp` before you reach for a restart.
- You notice when a test you just ran could not have distinguished anything.
- You say "I don't know" and then describe how you would find out.
- You write things down while investigating, without being told to.
- You are suspicious when a fix works and you cannot explain why.

**Not yet:**
- You restart things hopefully.
- You change several things and re-test.
- You go straight to the component you understand best.
- You stop at the first fault you find.
- Your documentation has never been read by anyone else.

The second list is not a character flaw; it is the untrained default. The drills exist specifically to replace it.

---

## 6. After this course — months 4 to 6

In this order. The order matters more than the list.

1. **Kubernetes.** *Now*, not before. You already know scheduling, service discovery, rolling updates, health checks and desired state — K8s is those ideas with much more surface area. Start with `k3s` or `kind` locally. *Kubernetes the Hard Way* (free) is excellent **once you can already operate a cluster**, and bewildering before.
2. **Terraform.** Real infrastructure as code. `cloud-init` gave you the mindset; Terraform adds state, dependency graphs and drift detection.
3. **One cloud provider, deeply.** Not three. The difficulty is IAM and networking, not compute.
4. **Go.** Docker, Kubernetes, Prometheus and Traefik are written in it. Reading their source stops being intimidating, and that changes what you can debug.
5. **CI/CD at scale.** Multi-environment promotion, artefact provenance, GitOps (Argo CD, Flux).

**And the habit that outperforms all five: keep the logbook.** The engineers who progress fastest are the ones who write down what broke and why, and re-read it on Fridays.
