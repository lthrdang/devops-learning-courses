# Week 10 — Docker Swarm

**VM profile:** `make w10-up` → `node1`, `node2`, `node3`
**You will be able to:** run a service across three machines, deploy a new version with no downtime, survive a node dying, and diagnose why a task will not schedule.

> Compose describes containers on one host. Swarm describes a **desired state** across several, and a control loop works continuously to make reality match it. That shift — from *"run this"* to *"keep this true"* — is the whole idea of orchestration, and it is the same idea Kubernetes implements with far more surface area.

---

## Day 1 — The model

### 1.1 Desired state and the reconciliation loop

You declare "I want 5 replicas of `web`". Swarm then, forever:

```
observe actual state → compare to desired → act to close the gap → repeat
```

A node dies with 2 replicas on it? Actual is now 3, desired is 5, so it starts 2 elsewhere. Nobody was paged. **This loop is the product.** Everything else — overlay networks, secrets, rolling updates — is support for it.

The practical consequence: **you stop running commands that do things and start editing a declaration.** `docker service scale web=8` does not start containers; it changes the desired state, and the loop does the rest.

### 1.2 Managers and workers

| | Does |
|---|---|
| **Manager** | maintains cluster state in a Raft log, schedules tasks, serves the API |
| **Worker** | runs tasks. Nothing else |

Managers replicate state via **Raft**, which requires a **quorum** — a strict majority — to make any change.

| Managers | Quorum | Can lose |
|---|---|---|
| 1 | 1 | 0 |
| **3** | **2** | **1** |
| 5 | 3 | 2 |
| 2 | 2 | **0** ← worse than 1 |

**Always use an odd number of managers.** Two managers is strictly worse than one: you have doubled the chance of a failure while still tolerating none, because losing either breaks quorum.

**Losing quorum does not stop your applications.** Running tasks keep running; you simply cannot *change* anything — no deploys, no scaling, no rescheduling. That is a bad afternoon, not an outage, and knowing the difference matters when you are deciding how urgently to react.

Recommended shape: **3 managers, and workers for everything else.** Managers should not run application workload in production (`docker node update --availability drain <manager>`), so that a runaway container cannot destabilise the control plane.

### 1.3 Services and tasks

A **service** is the declaration. A **task** is one instance of it — a slot that Swarm fills with exactly one container. Tasks are immutable: they are never updated, only replaced.

| Mode | Behaviour |
|---|---|
| `--mode replicated --replicas 5` | five tasks, anywhere the constraints allow |
| `--mode global` | exactly one task on **every** eligible node — for agents: log shippers, node_exporter, monitoring |

Task states you must be able to read: `NEW → PENDING → ASSIGNED → PREPARING → STARTING → RUNNING`, and the terminal ones `COMPLETE`, `FAILED`, `SHUTDOWN`, `REJECTED`.

> **`PENDING` means the scheduler could not place it.** Not "starting soon" — *could not place*. `docker service ps <svc> --no-trunc` gives the reason, and `--no-trunc` is essential because the default truncation cuts off the useful half of the message.

---

## Day 2 — Networking

### 2.1 Overlay networks

An **overlay** network spans hosts using VXLAN: container traffic is encapsulated in UDP and routed between nodes. Containers on the same overlay reach each other by service name regardless of which machine they are on.

```bash
docker network create --driver overlay --attachable appnet
docker network create --driver overlay --opt encrypted secure_net   # IPsec, at a CPU cost
```

Ports that must be open between nodes — this is the single most common cause of a Swarm that "joins but does not work":

| Port | Protocol | For |
|---|---|---|
| 2377 | TCP | cluster management (managers only) |
| 7946 | TCP **and** UDP | node discovery / gossip |
| 4789 | UDP | VXLAN data plane |

Miss 4789/UDP and nodes join happily, services deploy, and cross-node traffic silently fails. Miss 7946/UDP and nodes flap between `Ready` and `Down`.

### 2.2 Service discovery, done properly

Swarm gives each service a **virtual IP (VIP)**. Resolving `api` returns one stable address; the kernel's IPVS load-balances across the healthy tasks behind it.

> **This is what fixes the Week 8 nginx problem.** There, nginx cached the single IP it resolved at startup and kept sending everything to one replica. With a VIP, the address never changes — it is a stable front for a changing set of tasks — so caching it is harmless. Swarm solved structurally what we worked around with a `resolver` directive.

The alternative, when you want the individual addresses (for a client-side balancer or a stateful set):

```bash
docker service create --endpoint-mode dnsrr --name db ...   # DNS returns every task IP
```

### 2.3 The routing mesh

Publish a port and **every node accepts traffic on it**, whether or not it runs a task, forwarding as needed:

```bash
docker service create --name web --replicas 2 -p 8080:80 nginx:alpine
# curl node1:8080, node2:8080, node3:8080 - all work, all reach a replica
```

This is why you can point a simple external load balancer at all three nodes without tracking which one has a replica today.

To opt out — when you want traffic only where a task actually runs, e.g. behind an external LB doing its own health checks:

```bash
--publish mode=host,target=80,published=8080
```

---

## Day 3 — Rolling updates, the reason you are here

### 3.1 The knobs

```bash
docker service update \
  --image myapp:2.0 \
  --update-parallelism 1 \        # how many tasks at a time
  --update-delay 10s \            # pause between batches - MUST exceed startup+healthcheck
  --update-order start-first \    # start the new one BEFORE stopping the old
  --update-failure-action rollback \
  --update-max-failure-ratio 0.2 \
  myapp
```

**`--update-order start-first` is the important one.** The default, `stop-first`, removes capacity before adding it: with 2 replicas you drop to 1 during the update, and to 0 momentarily if both are updated. `start-first` needs headroom but keeps capacity constant.

> This is exactly the manual procedure you wrote by hand in Week 5 (C5.1): *add before you remove, drain before you stop*. Swarm gives you it for free — **but only if you configured the healthcheck**, because without one Swarm considers a task healthy the instant the container starts, and happily rolls a broken version across your whole fleet in 30 seconds.

### 3.2 Health checks are what make it safe

```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
  interval: 10s
  timeout: 3s
  retries: 3
  start_period: 30s        # grace before failures count
```

With `--update-failure-action rollback`, a task that never becomes healthy causes Swarm to stop and **revert automatically**. That is the single highest-value line of configuration in this week.

`--stop-grace-period 30s` controls how long a task gets between `SIGTERM` and `SIGKILL`. If your drain plus your longest request exceeds it, you are cutting off live requests — Week 7's lesson, at cluster scale.

### 3.3 Rollback

```bash
docker service rollback myapp                 # revert to the PREVIOUS spec
docker service inspect myapp --format '{{json .PreviousSpec.TaskTemplate.ContainerSpec.Image}}'
```

Swarm keeps exactly **one** previous spec. Rolling back twice returns you to where you started. Real version history belongs in git, with the stack file — which is why you deploy from a committed file rather than by typing `service update`.

---

## Day 4 — Stacks, secrets, configs, placement

### 4.1 Stacks

```bash
docker stack deploy -c stack.yml myapp
docker stack services myapp
docker stack ps myapp --no-trunc
docker stack rm myapp
```

A stack file is a Compose file plus a `deploy:` section. Differences from Compose that catch people:

- **`build:` is ignored.** Swarm deploys images; it does not build them. You must build and push to a registry first. This surprises everyone migrating from Compose.
- **`depends_on` is ignored.** There are no start-order guarantees at all. Your application must retry — Week 8's lesson, now mandatory rather than merely wise.
- `deploy:` is honoured (it is ignored by plain `docker compose up`).

### 4.2 Secrets and configs

```bash
echo -n 'hunter2' | docker secret create db_password -
docker config create nginx_conf ./nginx.conf
```

Secrets are encrypted at rest in the Raft log, encrypted in transit, and mounted at `/run/secrets/<name>` in a **tmpfs** — never on disk in the container, never in `docker inspect`, never in an image layer. This is a genuine improvement on Week 8's file-based approach.

**Secrets are immutable.** To rotate, create a new one and update the service to use it:

```bash
echo -n 'new' | docker secret create db_password_v2 -
docker service update --secret-rm db_password --secret-add source=db_password_v2,target=db_password myapp
```

The `target=` keeps the in-container path stable so the application needs no change. Rotation is therefore a rolling update — which means it is zero-downtime, and also that you must have a healthcheck for it to be safe.

### 4.3 Placement

```bash
--constraint 'node.role==worker'
--constraint 'node.labels.tier==db'
--placement-pref 'spread=node.labels.zone'      # spread evenly across zones
```

```bash
docker node update --label-add tier=db node2
```

> **An unsatisfiable constraint produces tasks that sit in `PENDING` forever, with no warning.** Swarm does not tell you it cannot schedule; it simply never does. `docker service ps <svc> --no-trunc` says `no suitable node (scheduling constraints not satisfied on 3 nodes)`. This is fault 2 of this week's drill.

### 4.4 Node availability

| State | Meaning |
|---|---|
| `active` | normal |
| `pause` | existing tasks keep running; **no new tasks scheduled here** |
| `drain` | tasks are **moved off**; nothing scheduled here |

`drain` is the correct way to take a node out for maintenance. It is also the most common cause of "why are only 4 of my 6 replicas running?" — someone drained a node and forgot to reactivate it.

### 4.5 What Swarm does not give you

Being honest about this is part of knowing the tool:

- **No autoscaling.** Replica counts are manual.
- **No built-in storage orchestration.** A volume is local to a node; a task rescheduled elsewhere does not find its data. Stateful workloads need `--constraint` pinning them to one node (which forfeits the rescheduling you came for), or NFS/Ceph, or an external managed database. **For most small teams, running the database outside the cluster is the right answer.**
- **A much smaller ecosystem** than Kubernetes, and slower upstream development.

Swarm's case is that it delivers ~80% of the operational value for ~10% of the complexity, and every concept transfers. That is exactly why it is in this course and Kubernetes is not.

---

## Day 5 — Drill

```bash
cd infra
make snapshot VM=node1 NAME=pre-w10
make break VM=node1 DRILL=10-swarm
```

Symptom: *"I scaled to 6 replicas twenty minutes ago. `docker service ls` still says 4/6. All three nodes are Ready."*

The method for **every** scheduling problem, in this order:

```bash
docker service ps <svc> --no-trunc     # WHY each task is where it is
docker node ls                         # Ready AND Active? read BOTH columns
docker service inspect <svc>           # constraints, resources, mode
docker service logs <svc>              # is the app itself crashing?
```

## Recommended reading

- Swarm mode docs — <https://docs.docker.com/engine/swarm/>
- The Raft visualisation — <https://raft.github.io/> — spend ten minutes here; consensus stops being mysterious
- <https://dockerswarm.rocks/> — practical single-cluster patterns
- *Docker Deep Dive*, Nigel Poulton — the Swarm chapters
