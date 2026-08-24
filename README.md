# Zero-to-Junior Platform Engineer

A 12-week, full-time, hands-on training program that takes an engineer who **can already write basic code** but has **never administered a Linux system** to the level of a **junior platform engineer** who can build, run, observe and troubleshoot containerised systems on Linux.

Everything runs on **free and open-source software**, inside **Multipass Ubuntu VMs** on your own machine. No cloud account, no credit card, no vendor free-tier is required at any point.

---

## 1. Who this is for

**You are ready for Week 1 if you can:**

- Write a function, a loop and a conditional in *some* language (Python, JS, Java, Go — any).
- Read a stack trace and understand that it points at a line of code.
- Use `git clone`, `git add`, `git commit` at a basic level.

**You do *not* need to know:** Linux commands, SSH, networking, Docker, systemd, or what a "port" is. Week 1 starts from `cd`.

**You will graduate able to:**

- Live in a Linux shell without a GUI, and script it in Bash and Python.
- Explain what happens between typing `curl https://example.com` and seeing HTML — at every layer.
- Build, optimise, secure and debug container images.
- Run a multi-service stack with Docker Compose and a multi-node cluster with Docker Swarm.
- Read logs and metrics, and **find the cause of a failure by evidence rather than by guessing**.

---

## 2. The core skill: troubleshooting

Most courses teach you to make things work. Very few teach you what to do when they **stop** working — which is 80% of a platform engineer's actual job.

Every week in this course therefore ends with a **Break/Fix drill**. A script (in `infra/chaos/`) deliberately damages your VM or your stack. You are told only the symptom, as a user would report it:

> "The website is slow." · "It worked yesterday." · "I get a 502."

You then have to find the cause. The chaos scripts print **nothing** about what they did — that is the point. Solutions are provided, but reading them before you have spent your allotted time is the one way to waste this course.

The method you will drill until it is automatic is documented in
**[week-09 · The Troubleshooting Method](week-09-observability-troubleshooting/README.md)** — but you start practising it in Week 1.

---

## 3. Program at a glance

| Week | Module | Core question you will be able to answer |
|-----:|--------|------------------------------------------|
| 00 | [Pre-flight: Multipass & the lab](week-00-preflight/README.md) | How do I create, snapshot and destroy a Linux machine in 10 seconds? |
| 01 | [Linux Foundations](week-01-linux-foundations/README.md) | Where do files live, who may touch them, and what is a process? |
| 02 | [Linux System Administration](week-02-linux-sysadmin/README.md) | How does a service start at boot, and where did it write its error? |
| 03 | [Bash Scripting for Operators](week-03-bash-scripting/README.md) | How do I turn a fragile one-liner into a script I can trust at 3am? |
| 04 | [Networking Fundamentals](week-04-networking-fundamentals/README.md) | Why can't this machine reach that port? |
| 05 | [HTTP, TLS, Proxy & Load Balancing](week-05-http-tls-proxy-lb/README.md) | What is a reverse proxy really doing, and why is it returning 502? |
| 06 | [Python for Platform Engineering](week-06-python-for-platform/README.md) | How do I build a reliable CLI tool that other engineers depend on? |
| 07 | [Docker Fundamentals](week-07-docker-fundamentals/README.md) | What *is* a container, and why is my image 1.2 GB? |
| 08 | [Docker Compose](week-08-docker-compose/README.md) | How do I run six services that depend on each other, reproducibly? |
| 09 | [Observability & Troubleshooting](week-09-observability-troubleshooting/README.md) | How do I know *why* it is slow, instead of guessing? |
| 10 | [Docker Swarm](week-10-docker-swarm/README.md) | How do I survive a node dying at 2am without downtime? |
| 11 | [Production: Security, Backup, CI/CD](week-11-production-security-ci/README.md) | How do I ship a change safely and get it back if it breaks? |
| 12 | [Capstone: Build, Operate, Break, Postmortem](week-12-capstone/README.md) | Can I run a system on-call and write up what happened? |

**Load:** 12 weeks × 5 days × ~8 hours. Each week is 4 days of new material + 1 day of consolidation, break/fix drills and challenges.

### Daily rhythm

| Time | Activity |
|------|----------|
| 09:00–10:30 | Read the day's section of `README.md` (theory), take notes **by hand** |
| 10:30–12:30 | Work through the matching part of `lab.md` |
| 13:30–16:00 | Continue the lab; you *will* get stuck — that is the work |
| 16:00–17:00 | `challenges.md` — no step-by-step instructions given |
| 17:00–17:30 | Write your daily log (see §6) |

---

## 4. Repository layout

```
.
├── README.md              ← you are here: the roadmap
├── Makefile               ← `make docs` to read all of this as a website
├── mkdocs.yml             ← the site configuration
├── SETUP.md               ← install Multipass, size your VMs, fix common install problems
├── ASSESSMENT.md          ← weekly checkpoints + the "junior-ready" exit checklist
├── RESOURCES.md           ← curated free/open-source references per topic
├── GLOSSARY.md            ← every term the course introduces, defined once
├── infra/
│   ├── Makefile           ← `make w04-up`, `make snapshot`, `make clean` …
│   ├── cloud-init/        ← declarative VM provisioning (base, docker node, observability)
│   ├── scripts/           ← lab lifecycle helpers
│   └── chaos/             ← the break/fix scripts. Run them; do not read them.
└── week-NN-topic/
    ├── README.md          ← theory + explanation, split by day
    ├── lab.md             ← guided, step-by-step hands-on work
    ├── challenges.md      ← unguided problems; you design the solution
    ├── solutions.md       ← read only after you have genuinely tried
    └── files/             ← configs, Dockerfiles, source code used by the lab
```

---

## 5. Reading this course as a website

Fifty-two markdown files are tedious to browse in an editor. The whole course
renders as a searchable site with one command:

```bash
make docs          # http://localhost:8000, with live reload
```

Everything runs in Docker — nothing is installed on your machine and the system
Python is never touched, which is the same reasoning Week 6 gives for virtual
environments.

| Command | Does |
|---|---|
| `make docs` | serve on `localhost` only; edits to any `.md` reload the page |
| `make docs-lan` | same, but bound to `0.0.0.0` so your team can read it |
| `make docs-build` | render a static site into `./site/` to host anywhere |
| `make docs-check` | fail on any broken link — use this in CI |
| `make check` | every gate: shellcheck, tests, YAML, and the docs build |

Port 8000 by default; override when something already holds it:

```bash
make docs-lan PORT=8888
```

If the port is taken, the target says so and names the process holding it
rather than letting Docker emit a bind error.

> **`make docs-lan` binds `0.0.0.0`.** Anyone who can reach the host can read
> the whole site — including `solutions.md` and the chaos-drill answers under
> `infra/chaos/`. That is fine for a training room and wrong for a shared
> office network. `make docs` binds loopback only.

Full-text search covers all 12,000 lines, so `pipefail`, `exit 137` or
`start-first` will find the exact section that explains it. The lab files under
each `files/` directory are served too, so you can download `backup.sh` straight
from the page that discusses it.

---

## 6. How to start

```bash
# 1. Install Multipass and verify your machine can run the labs
#    (read this properly — it covers the no-KVM / low-RAM cases)
less SETUP.md

# 2. Create your first VM and prove the lab works
cd infra && make w00-up

# 3. Begin
less ../week-00-preflight/README.md
```

---

## 7. Rules of engagement

These are not suggestions. They are what separates people who finish this course able to work from people who finish it able to recite.

1. **Type every command. Never copy-paste during theory.** Muscle memory and typo-recovery are part of the skill. Copy-paste is allowed only for long config files in `files/`.
2. **Before running any command that changes something, say out loud what you expect to happen.** Then compare. The gap between expectation and reality *is* the learning.
3. **When something breaks, do not immediately re-run it or reboot.** Read the error. All of it. Then form one hypothesis and test it.
4. **Timebox being stuck at 45 minutes.** Under 45 min: keep digging, that is where the skill grows. Over 45 min: read `solutions.md`, then **destroy the VM and redo the task from scratch**.
5. **Keep a daily engineering log** in `~/logbook/YYYY-MM-DD.md`. Three headings: *What I built* · *What broke and why* · *What I still don't understand*. The third heading is the most valuable one; revisit it every Friday.
6. **Destroy and rebuild your VMs often.** If rebuilding your environment feels expensive, your environment is not reproducible — and reproducibility is the entire discipline.

---

## 8. What is deliberately *not* in this course

Being explicit about scope keeps the 12 weeks honest:

- **Kubernetes.** You are not ready. Swarm teaches the same primitives (scheduling, service discovery, rolling updates, desired state) with 10% of the surface area. Learn K8s in month 4+, after this.
- **Cloud providers (AWS/GCP/Azure).** Console-clicking is not platform engineering, and it obscures the Linux underneath. Every concept here transfers to any cloud.
- **Terraform.** Requires a cloud to be meaningful. `cloud-init` in Week 11 teaches the declarative-infrastructure mindset first.
- **Paid tooling of any kind.** Grafana OSS, Prometheus, Loki, Nginx, HAProxy, Trivy and Gitea cover everything needed.

A suggested path for months 4–6 is at the end of [ASSESSMENT.md](ASSESSMENT.md).
