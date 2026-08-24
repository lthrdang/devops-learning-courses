# Glossary

Every term this course introduces, defined once, with the week that uses it.

Where a definition has an operational consequence, it is stated — a definition
you cannot act on is trivia.

---

## A

**ARP** *(W4)* — Address Resolution Protocol. Maps an IP address to a MAC address on the local segment. `ip neigh`. A `FAILED` entry for a host you believe is local usually means your netmask is wrong.

**Availability (Swarm)** *(W10)* — whether the scheduler may place tasks on a node: `active`, `pause`, `drain`. **Independent of `STATUS`.** A node can be `Ready` and `Drain` — healthy, reachable and deliberately empty.

---

## B

**Backoff** *(W6)* — increasing the delay between retries. With **jitter** (randomisation), it prevents a thundering herd. Without jitter, every client that failed together retries together and re-breaks the recovering service.

**Bind address** *(W4, W7)* — the address a service listens on. `0.0.0.0` = every interface; `127.0.0.1` = this machine only. A service bound to loopback is unreachable from anywhere else, which is one of the most common causes of "it's running but nobody can reach it".

**Bind mount** *(W7)* — mounting a host path into a container. **Hides whatever was at the mount point** — the cause of "my code disappeared".

**Blast radius** — how much breaks when one thing breaks. Resource limits, network segmentation and least privilege all exist to shrink it.

---

## C

**Cardinality** *(W9)* — the number of distinct time series a metric produces. Every unique label-value combination is one series. A `user_id` label creates one per user and will kill Prometheus. **Labels must be bounded and small.**

**cgroups** *(W7)* — kernel control groups: limit and account for CPU, memory, I/O and process count. "OOM killed" means a cgroup memory limit was exceeded.

**CIDR** *(W4)* — `10.0.5.0/24`. The prefix length says how many leading bits identify the network. Two hosts on the same subnet talk directly; otherwise they need a router.

**cloud-init** *(W0)* — the standard mechanism for configuring a Linux machine on first boot. Runs **once**. Failures are usually silent — always check `cloud-init status --long`.

**CLOSE_WAIT** *(W4)* — a TCP state meaning the remote closed and your application has not. Any significant number is **unambiguously an application bug**.

**Config drift** *(W0)* — the accumulation of undocumented manual changes. The reason a pet server cannot be rebuilt or reasoned about.

---

## D

**Desired state** *(W10)* — you declare what should be true; a control loop continuously makes reality match. The core idea of orchestration.

**Distroless** *(W7)* — an image with no shell and no package manager. Most secure, hardest to debug.

**Drain** *(W10)* — remove a node from scheduling and move its tasks off. The correct way to do maintenance, and a very common cause of "why are only 4 of my 6 replicas running?".

---

## E

**Error budget** *(W9)* — the amount of unreliability an SLO permits. 99.9% over 30 days = 43m 12s. **If nothing changes when it runs out, you do not have an SLO.**

**Exec form** *(W7)* — `CMD ["python", "app.py"]`. Your process becomes PID 1 and receives `SIGTERM`. The **shell form** (`CMD python app.py`) makes `/bin/sh` PID 1, which does not forward signals — so `docker stop` always ends in `SIGKILL` and exit 137.

---

## H

**Healthcheck** *(W5, W7, W10)* — a probe deciding whether an instance should receive traffic. **Readiness** ("send me work?") differs from **liveness** ("am I alive?"). A readiness check that tests a shared dependency will remove **every** replica at once when that dependency blips — turning degradation into an outage.

**Hysteresis** *(W5, W6)* — `fall`/`rise`: requiring N consecutive results before changing state. What stops one blip from paging someone.

---

## I

**Idempotent** *(W3)* — safe to run twice. A provisioning script that is not idempotent is one nobody dares run during an incident.

**Inode** *(W2)* — a filesystem's per-file metadata record. A **separate exhaustible resource** from blocks: `df -h` can show 3% used while writes fail with `No space left on device`. Always check `df -i`.

**Ingress / routing mesh** *(W10)* — Swarm's published-port mechanism: every node accepts the port and forwards to a healthy task, whether or not it runs one.

---

## L

**Layer** *(W7)* — one filesystem diff in an image. **Additive only**: deleting a file in a later layer hides it but does not remove it, so a secret in any layer is in the image forever.

**Least connections** *(W5)* — send the next request to the backend with fewest active connections. Usually a better default than round-robin, because request durations vary.

**Load average** *(W1, W9)* — the average number of processes runnable **or** blocked on uninterruptible I/O. Only meaningful relative to core count. Includes I/O wait, which is why a disk problem raises load without raising CPU.

---

## M

**Manager / quorum** *(W10)* — Swarm managers replicate state via Raft and need a strict majority to change anything. Use an **odd** number: two managers tolerate the same failures as one while doubling the chance of having one. Losing quorum stops *changes*, not running containers.

---

## N

**Namespace** *(W7)* — a kernel feature giving a process a private view of one global resource (pids, network, mounts…). The isolation half of a container; cgroups are the limits half.

**nftables** *(W4)* — the modern Linux packet filter. `ufw` is a front end; `iptables` commands are translated to it. **Docker inserts its own rules ahead of ufw's**, so a published container port is reachable regardless of your firewall.

---

## O

**OOM killer** *(W7, W9)* — the kernel killing a process when memory is exhausted. Presents as exit code **137**; check `docker inspect --format '{{.State.OOMKilled}}'` first.

**Overlay network** *(W10)* — a multi-host container network using VXLAN. Requires **4789/udp** between nodes; missing it makes cross-node traffic fail silently while everything looks healthy.

---

## P

**p50 / p95 / p99** *(W9)* — latency percentiles. Averages hide outages: 250 ms average can mean everyone gets 250 ms, or 99 get 50 ms and one waits 20 s. If a page makes 50 calls, a p99 of 1 s affects ~40% of page loads. **Never average percentiles across servers.**

**PID 1** *(W7)* — in a container, usually your application. It must handle `SIGTERM` (signals it does not handle are *ignored*) and reap orphaned children, or zombies accumulate. `--init`/tini provides both.

**pipefail** *(W3)* — `set -o pipefail`. Without it a pipeline's status is the **last** command's, so `curl … | jq …` reports success when curl fails.

---

## R

**Rate limiting** *(W5)* — capping request rate per key. Keying on IP punishes shared NAT and misses distributed attackers; there is no single correct key, so layer several.

**RED** *(W9)* — Rate, Errors, Duration. The three metrics for a **service**.

**Reverse proxy** *(W5)* — sits in front of servers (a forward proxy sits in front of clients). Must set `X-Forwarded-For` and `X-Forwarded-Proto`, or backends see the proxy as the client and build `http://` redirect loops.

**Rolling update** *(W5, W10)* — replacing instances in batches. `start-first` adds before removing (capacity never dips); `stop-first` is the reverse. Safe only with a real healthcheck.

**RPO / RTO** *(W11)* — how much data you may lose (sets backup *frequency*) and how long recovery may take (sets backup *method*). **Both are only real once measured.**

---

## S

**Saturation** *(W9)* — how much work is **queued**. Utilisation caps at 100% and stops informing you; saturation does not. Run queue, I/O wait and swap activity are saturation signals. This is the metric juniors miss.

**Secret** *(W8, W10, W11)* — a credential. Never in an image layer, never in `ENV`. Swarm secrets are encrypted at rest and mounted in tmpfs. **Immutable** — rotation means creating a new one and rolling the service.

**setuid / sticky bit** *(W1)* — setuid runs a program as its owner (how `passwd` works; also a privilege-escalation surface). The sticky bit on a shared directory (`/tmp`) lets anyone create but only owners delete.

**SNI** *(W5)* — the hostname sent unencrypted in the TLS handshake so a server can choose a certificate. Always pass `-servername` to `openssl s_client`, or you test the wrong certificate.

**SLO** *(W9)* — a reliability target with a measurement window, from which an error budget follows.

---

## T

**Task** *(W10)* — one instance of a Swarm service; a slot filled by exactly one container. Immutable — never updated, only replaced. **`PENDING`** = the scheduler could not place it; **`REJECTED`** = a node tried and failed. Different causes, different places to look.

**TIME_WAIT** *(W4)* — a TCP state after closing, held ~60 s so stray packets are not misattributed. Thousands indicate high connection churn — consider keep-alive.

**Timeout vs refused** *(W4)* — **refused** (RST) means the packet arrived and nothing was listening: routing and firewall are fine. **Timed out** means no answer at all: something dropped it. The single most useful distinction in network debugging.

**tmpfs** *(W7)* — a filesystem in RAM. Where secrets belong inside a container.

---

## U

**Union filesystem / overlayfs** *(W7)* — stacks read-only image layers under one thin writable layer per container, so many containers share one image cheaply.

**USE** *(W9)* — Utilisation, Saturation, Errors. The three metrics for a **resource**.

---

## V

**VIP** *(W10)* — Swarm's stable virtual IP per service, load-balanced by IPVS across healthy tasks. Because it never changes, caching it is safe — which is what structurally fixes the nginx DNS-caching problem from Week 8.

**Volume** *(W7)* — persistent storage outside a container's writable layer. Local to a node, which is why stateful workloads are the hard part of orchestration.

---

## W

**Whiteout** *(W7)* — the marker a layer writes to hide a file deleted in an earlier layer. The reason `rm` in a Dockerfile does not remove a secret from the image.
