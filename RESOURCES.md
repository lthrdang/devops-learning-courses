# Resources

Free and open-source only. Everything here is genuinely free — not a trial, not a
limited tier. Where a book is paid, it is marked and there is a free alternative.

---

## The short list

If you only ever bookmark five things:

| | |
|---|---|
| <https://linuxcommand.org/tlcl.php> | *The Linux Command Line* — free PDF, the best Linux starting point |
| <https://jvns.ca/> | Julia Evans — short, brilliant explanations of exactly the confusing bits |
| <https://www.brendangregg.com/> | Performance and troubleshooting. The USE method lives here |
| <https://sre.google/books/> | The Google SRE books — free online, and the reference for monitoring and postmortems |
| <https://explainshell.com/> | Paste any command line, get every flag annotated |

---

## Week by week

### 00–02 · Linux
- *The Linux Command Line*, William Shotts — <https://linuxcommand.org/tlcl.php> (free PDF)
- `man hier`, `man 7 signal`, `man systemd.service`, `man systemd.exec`
- systemd docs — <https://www.freedesktop.org/software/systemd/man/>
- Multipass docs — <https://documentation.ubuntu.com/multipass/>
- cloud-init examples — <https://cloudinit.readthedocs.io/en/latest/reference/examples.html>
- OverTheWire **Bandit** — <https://overthewire.org/wargames/bandit/> — a free game that teaches shell skills properly. Highly recommended alongside Weeks 1–2.

### 03 · Bash
- Google Shell Style Guide — <https://google.github.io/styleguide/shellguide.html>
- **BashPitfalls** — <https://mywiki.wooledge.org/BashPitfalls> — all 60 are real; read them all
- BashGuide — <https://mywiki.wooledge.org/BashGuide>
- ShellCheck wiki — <https://www.shellcheck.net/wiki/> — every warning code explained
- `bats-core` — <https://github.com/bats-core/bats-core>

### 04–05 · Networking, HTTP, TLS
- *High Performance Browser Networking*, Ilya Grigorik — **free online** at <https://hpbn.co/>
- Julia Evans' networking and DNS material — <https://jvns.ca/>
- MDN HTTP reference — <https://developer.mozilla.org/en-US/docs/Web/HTTP>
- Mozilla SSL Configuration Generator — <https://ssl-config.mozilla.org/> — copy TLS settings from **here**, never from a blog post
- Nginx docs — <https://nginx.org/en/docs/> · HAProxy — <https://docs.haproxy.org/>
- <https://badssl.com/> — deliberately broken TLS endpoints to test against
- Practical tcpdump — <https://danielmiessler.com/study/tcpdump/>

### 06 · Python
- *Automate the Boring Stuff* — **free online** at <https://automatetheboringstuff.com/>
- Python docs, `library` index — `logging`, `argparse`, `subprocess`, `pathlib`
- Ruff — <https://docs.astral.sh/ruff/> · uv — <https://docs.astral.sh/uv/>
- <https://calmcode.io/> — short, free, practical videos
- AWS Architecture Blog, *Exponential Backoff and Jitter* — the canonical explanation

### 07–08 · Containers
- Docker docs, Dockerfile best practices — <https://docs.docker.com/build/building/best-practices/>
- Compose specification — <https://github.com/compose-spec/compose-spec/blob/master/spec.md>
- Awesome Compose — <https://github.com/docker/awesome-compose>
- **hadolint** — <https://github.com/hadolint/hadolint> — Dockerfile linter
- **dive** — <https://github.com/wagoodman/dive> — explore layers, find the waste
- **Trivy** — <https://trivy.dev/> — image and filesystem scanning
- Liz Rice's free talks on building a container from scratch in Go
- *Twelve-Factor App* — <https://12factor.net/> — especially III (Config) and IX (Disposability)

### 09 · Observability
- **Brendan Gregg** — <https://www.brendangregg.com/> — USE method, 60-second checklist, flame graphs
- *Google SRE Book* — <https://sre.google/books/> — monitoring, alerting, SLOs, postmortems
- *The Site Reliability Workbook* — <https://sre.google/workbook/> — free, and more practical
- Prometheus docs, especially *Instrumentation best practices* — <https://prometheus.io/docs/practices/instrumentation/>
- Grafana Loki — <https://grafana.com/docs/loki/latest/>
- <https://promlabs.com/promql-cheat-sheet/> — free PromQL reference

### 10 · Swarm
- Swarm mode docs — <https://docs.docker.com/engine/swarm/>
- **The Raft visualisation** — <https://raft.github.io/> — ten minutes here and consensus stops being mysterious
- <https://dockerswarm.rocks/>

### 11 · Production
- CIS Benchmarks — free registration — Ubuntu and Docker
- OWASP Docker Security Cheat Sheet — <https://cheatsheetseries.owasp.org/cheatsheets/Docker_Security_Cheat_Sheet.html>
- Gitea Actions — <https://docs.gitea.com/usage/actions/overview>
- SSH hardening: `man sshd_config`, and <https://www.sshaudit.com/>
- **age** — <https://github.com/FiloSottile/age> · **SOPS** — <https://github.com/getsops/sops>

### 12 · Incidents
- *Google SRE Book*, postmortem chapter — <https://sre.google/sre-book/postmortem-culture/>
- <https://github.com/danluu/post-mortems> — a large collection of real public postmortems. Read ten; it is the fastest way to learn what failure actually looks like
- *The Field Guide to Understanding Human Error*, Sidney Dekker (paid, but the free talks cover the core)

---

## Practice environments, all free

| | |
|---|---|
| <https://overthewire.org/wargames/bandit/> | shell fundamentals, gamified. Start here in Week 1 |
| <https://labs.iximiuz.com/> | free browser-based Linux and container playgrounds |
| <https://killercoda.com/> | free interactive scenarios, including Docker and Kubernetes |
| <https://sadservers.com/> | **"fix the broken server" puzzles.** The closest thing to this course's drills that exists publicly — do these all the way through |
| <https://exercism.org/tracks/bash> | free Bash exercises with mentoring |

> **SadServers deserves special mention.** If you finish this course and want more troubleshooting practice, it is the best free resource for exactly that skill.

---

## Books worth paying for, eventually

Nothing here is required for this course.

- *Systems Performance*, Brendan Gregg — the reference for performance
- *Docker Deep Dive*, Nigel Poulton — clear and current
- *Continuous Delivery*, Humble & Farley — the definitive book on pipelines
- *Database Reliability Engineering*, Campbell & Majors
- *SSH Mastery*, Michael W. Lucas — short, and you will use it for years

---

## Communities

- <https://reddit.com/r/devops> — read the weekly threads; ignore the tool wars
- <https://reddit.com/r/sysadmin> — where the real war stories are
- CNCF Slack — free to join, and specific channels are genuinely helpful
- Your local Linux user group. Underrated.

---

## A word on tutorials

Most container and DevOps tutorials on the internet are wrong in the same
predictable ways: they run as root, use `:latest`, put secrets in `ENV`, use the
shell form of `CMD`, and expose ports on `0.0.0.0`. You now know why each of
those is wrong.

**Treat that as a skill, not a complaint.** Being able to read a popular tutorial
and immediately spot four production problems in its `docker run` line is a
reasonable definition of having finished this course.
