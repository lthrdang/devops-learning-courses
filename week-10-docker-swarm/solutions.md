# Week 10 — Solutions & discussion

---

## The drill (10-swarm) — worked

**Start with the number, not the logs.** `docker service ls` reads `0/6`. Every single task is unplaced — and that is a *classification*, not just a bad result:

- **all tasks pending** → the cause lives in the **service spec**. Constraints, resource reservations and the image reference apply to every task identically, so they fail every task identically.
- **some running, some pending** → the cause is about **capacity or particular nodes**: too few eligible nodes, insufficient memory, a per-node replica cap, a drained node.

`0/6` therefore rules out the drained node as *the* explanation before you look at anything, because a drained node cannot stop tasks landing on the other two.

```bash
docker service ls                    # 0/6 — classify first
docker service ps web --no-trunc     # ALWAYS second for a scheduling problem
docker node ls                       # read BOTH columns
```

**Fault A — an unsatisfiable constraint. This is the 0/6.**

```
"no suitable node (scheduling constraints not satisfied on 3 nodes)"
```

`node.labels.tier==gold`, and no node carries the label. Tasks sit `PENDING` **forever** with no warning — Swarm never reports that it cannot schedule, it simply never does. Either remove the constraint or satisfy it:

```bash
docker service inspect web --format '{{json .Spec.TaskTemplate.Placement}}' | jq
docker node inspect node1 --format '{{json .Spec.Labels}}'
docker service update --constraint-rm 'node.labels.tier == gold' web   # EXACT string
# or
docker node update --label-add tier=gold node1
```

**Fault B — a drained worker. This is why fixing fault A gets you 4/6, not 6/6.**

Here is where most people declare victory and walk away. The service moved, so it must be fixed. It is not: you asked for six and you have four.

```
ID   HOSTNAME   STATUS   AVAILABILITY   MANAGER STATUS
xxx  node2      Ready    Drain
```

`Ready` is the `STATUS` column — *can I reach it*. `AVAILABILITY` is *may I schedule on it*, and it reads `Drain`: healthy, reachable, deliberately empty. Someone drained it for maintenance and forgot to reactivate it. `docker node update --availability active node2`.

Note **why** this produced a shortfall at all. The service carries `--replicas-max-per-node 2`, so the cluster has 3 × 2 = 6 slots; drain a node and 2 of them vanish. The remaining tasks say:

```
"no suitable node (max replicas per node limit exceed)"
```

Without that cap, Swarm would have stacked all six replicas onto the two surviving nodes and the count would have read a perfectly green `6/6` — with your entire service one machine away from a bad day. That cap is not a fault to be removed; it is the thing that made the drain *visible*.

**The three things to carry away:**

1. **Classify on the replica count first.** `0/N` and a partial count have disjoint sets of causes. One glance eliminates most of the search.
2. **`--no-trunc` is not optional.** The default truncation cuts the `ERROR` column at exactly the point where it becomes useful.
3. **`--constraint-rm` is an exact string match, including spaces.** Swarm stores `node.role == worker` with the spacing you wrote; `--constraint-rm 'node.role==worker'` matches nothing, the command **succeeds**, and nothing changes. Always verify with `docker service inspect`, never with the exit code. This one wasted real time during the writing of this course.

---

## C10.4 — The scheduling puzzle

| # | Cause | `docker service ps --no-trunc` says |
|---|---|---|
| 1 | unsatisfiable constraint | `no suitable node (scheduling constraints not satisfied on N nodes)` |
| 2 | not enough memory anywhere | `no suitable node (insufficient resources on N nodes)` |
| 3 | every node drained | `no suitable node (N nodes not available for new tasks)` |
| 4 | published port in use | `rejected: port '8080' is already in use on N nodes` |
| 5 | image cannot be pulled | `No such image: repo/img:tag` (state **Rejected**, not Pending) |
| 6 | global, task already present | no error — the service is simply `1/1`, and that is correct |

**The distinction that matters: `PENDING` versus `REJECTED`.**

- **`PENDING`** = the *scheduler* has not placed the task. Every task passes through this state normally, in milliseconds; what is diagnostic is a task **stuck** here. It means nobody has tried to run anything yet. Look at constraints, resources, node availability.
- **`REJECTED`** = a node accepted the task and the *agent* could not start it. Look at the image, the registry credentials, the mounts.

Those send you to completely different places, and reading the state column before the error string saves you from investigating the wrong half of the system.

```bash
# Reproduce #2 and read the message yourself:
docker service create --name hog --reserve-memory 64G --replicas 1 nginx:alpine
docker service ps hog --no-trunc
docker service rm hog
```

---

## C10.1 — Truly zero downtime

The counting harness — do not eyeball this:

```bash
#!/usr/bin/env bash
# count-failures.sh - run during any change; prints a total on Ctrl-C.
ok=0; bad=0
trap 'echo; echo "OK=$ok FAILED=$bad ($(awk "BEGIN{printf \"%.2f\", 100*$bad/($ok+$bad)}")%)"; exit' INT
while true; do
  if curl -sf -m3 -o /dev/null "http://node1:8080/"; then
    ok=$(( ok + 1 ))
  else
    bad=$(( bad + 1 )); echo "$(date +%T.%3N) FAIL"
  fi
  sleep 0.2
done
```

| Change | Config required for zero failures |
|---|---|
| **Image update** | `order: start-first`, a real `healthcheck`, `delay` > start_period + healthcheck settle, `parallelism: 1` |
| **Config rotation** | same — configs are immutable, so a change *is* a rolling update |
| **Secret rotation** | same, plus `target=` so the in-container path does not change |
| **Drain a node** | `order: start-first` and **spare capacity**: with 3 replicas across 3 nodes and no headroom, draining one forces a rescheduling that cannot start-first |
| **Hard node stop** | **Not achievable.** See below |

**Why a hard node stop always drops requests, and why that is not a configuration failure:**

Swarm detects a dead node by missed heartbeats — typically **5–30 seconds**. During that window it believes the node is healthy and the routing mesh keeps forwarding to tasks that no longer exist. Nothing in Swarm's configuration shortens this to zero; you cannot detect a failure faster than you can distinguish it from slowness.

The mitigations live *above* Swarm: an external load balancer with a fast health check that removes the node in ~2 seconds, and client-side retries on idempotent requests. **The honest engineering answer is that "zero downtime on unplanned node loss" is not a property any single orchestrator provides** — it is a property of the whole request path, and anyone who claims otherwise has not measured it.

That distinction — planned changes can be seamless, unplanned failures can only be *brief* — is worth being able to state clearly. It is the difference between a marketing claim and an SLO.

---

## C10.3 — Stateful in a stateless system

| Approach | Node dies | Recovery time | Silent corruption risk |
|---|---|---|---|
| **1. Pin + local volume** | The service is **down** until the node returns. Swarm cannot reschedule it — the data is on that disk | as long as the node takes; if the disk is gone, restore from backup | Low. One writer, always |
| **2. NFS volume** | Rescheduled elsewhere, remounts, comes back in ~30s | ~30 seconds | **HIGH.** If the old task is not truly dead (a network partition, not a crash), two Postgres instances can mount the same data directory. Postgres has a lock file, but NFS locking is unreliable — this corrupts databases in the real world |
| **3. External database** | Irrelevant to Swarm; the database has its own HA | seconds, with a replica | Low. It is the database's own well-tested failover |

**For a five-person startup: option 3, without hesitation** — a managed Postgres, or a dedicated pair outside the cluster with streaming replication.

**The reasoning:** options 1 and 2 both ask you to solve distributed-storage consistency yourself, as a side quest, while you are trying to ship a product. Option 1 gives up the rescheduling you adopted Swarm for. Option 2 introduces a failure mode — split-brain over unreliable NFS locking — whose consequence is *silent data corruption discovered weeks later*, which is the single worst outcome in operations.

**The general principle: orchestrators are excellent at stateless workloads and mediocre at stateful ones.** Keep state in something built for it. That advice is not Swarm-specific; the Kubernetes community arrived at operators and CSI drivers precisely because this problem is genuinely hard.

---

## C10.6 — Compose to Swarm

**Changes required:**

| Compose | Swarm |
|---|---|
| `build: ./api` | **build and push to a registry**, then `image: registry/api:1.0` |
| `depends_on: {condition: service_healthy}` | **ignored — delete it** |
| `restart: unless-stopped` | `deploy.restart_policy.condition: on-failure` |
| `ports: ["127.0.0.1:8080:80"]` | `ports: [{target: 80, published: 8080, mode: ingress}]` — note the mesh publishes on **all** nodes; loopback-only binding is not available |
| `secrets: {file: ./x}` | `docker secret create` — external, and encrypted at rest |
| `volumes: [dbdata:/var/lib/postgresql/data]` | still local per node — see C10.3 |
| `--scale api=3` | `deploy.replicas: 3` |
| `docker compose up -d` | `docker stack deploy -c stack.yml name` |

**Capabilities lost:** start-order conditions; `build:`; `profiles:`; `docker compose exec` (use `docker exec` on the node running the task); per-interface port binding; `env_file` behaves differently.

**What breaks without `condition: service_healthy`, and what to do:**

The API will start before Postgres is accepting connections, on every deploy and every reschedule. In Compose that was a convenience; in Swarm it is guaranteed to happen, repeatedly, forever — because tasks are rescheduled at arbitrary times with no coordination.

Three answers, in order of robustness:

1. **Retry with backoff in the application.** This is not a workaround, it is the correct design. `connect_with_retry` from Week 8 already does it, and it also handles the case Compose never covered: the database restarting at 3am while the app has been up for a month. **If you only do one thing, do this.**
2. **Run migrations from CI**, as a deploy step before the service update, rather than as a stack service.
3. **Guard migrations with a database advisory lock** so that whichever replica wins runs them and the others wait — because in Swarm they *will* start simultaneously.

**The deeper point:** Compose's clean startup ordering was possible only because Compose is single-host and single-threaded. Discovering which of your conveniences depended on that assumption is the real intellectual work of this migration — and it is the same work, at larger scale, when moving to Kubernetes.

---

## C10.7 — Is Swarm enough?

> **Three things Swarm gives this team that they need now:**
> 1. **The machine stops being a single point of failure.** A node reboot is no longer an outage; tasks reschedule in under a minute without anyone waking up.
> 2. **Deploys stop being outages.** `start-first` plus a healthcheck plus `failure_action: rollback` means a bad image reverts itself. We measured zero failed requests across a rolling update.
> 3. **Secrets stop being plaintext files on one host.** Encrypted in Raft, mounted in tmpfs, rotatable as a rolling update.
>
> **Three things it does not do that they will want:**
> 1. **Autoscaling.** Replica counts are manual. At twelve services with variable load, someone will be scaling by hand at 9am every Monday.
> 2. **Storage orchestration.** Anything stateful lives outside the cluster or is pinned to a node. That is a workable constraint, but it is a constraint.
> 3. **The ecosystem.** No cert-manager, no external-dns, no service mesh, no operators. Each of those is a thing they will build by hand or do without, and upstream Swarm development is slow.
>
> **The specific event that says "move to Kubernetes":** not a headcount and not a service count — it is **when we are writing our own controllers.** The first time someone builds a script that watches the cluster and reconciles something Swarm does not model (autoscaling on a custom metric, certificate rotation, per-tenant provisioning), we are re-implementing Kubernetes badly. That is the signal. A second, independent trigger: a compliance requirement for something only the Kubernetes ecosystem provides, such as fine-grained RBAC or admission policy.
>
> **Cost of moving:** 6–10 weeks for a team of five to be genuinely productive — roughly 2 weeks to learn the object model, 2 to rebuild manifests and CI, 2 to relearn networking and ingress, and several more of paying for mistakes in production. Plus permanent ongoing cost: someone must own cluster upgrades, and that is now a real part of somebody's job. **Kubernetes is not more expensive because it is harder to learn; it is more expensive because it never stops needing an owner.**
>
> **Recommendation: Swarm now.** It removes their three actual risks this quarter, at a cost of about a week. Revisit when the trigger above fires — and if it never fires, that is a perfectly good outcome, not a failure to modernise.

**Why this answer works:** it names a *falsifiable trigger* rather than a vague "when you outgrow it", it prices both options in weeks, and it explicitly permits the outcome where they never migrate. An assessment that treats Kubernetes as the inevitable destination is not an assessment — it is a fashion statement, and experienced engineers read it as one.
