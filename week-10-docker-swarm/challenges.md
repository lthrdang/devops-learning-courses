# Week 10 — Challenges

---

### C10.1 — Truly zero downtime

Run a continuous request loop and perform each of these **without a single failed request**. Count failures with a script; do not eyeball it.

1. A rolling image update.
2. A configuration change (rotate the `docker config`).
3. A secret rotation.
4. Draining and reactivating a node.
5. A node being hard-stopped.

For any that produce failures, find out why and fix the configuration. Report the settings you needed and the failure count before and after each fix.

---

### C10.2 — Scale from evidence

Instrument the stack (Week 9), put load through it, and determine the replica count needed to keep p99 under 500 ms at 200 requests/second.

Then answer: what is the bottleneck at that point? Would adding replicas keep helping? Show the measurement that proves it.

---

### C10.3 — Stateful in a stateless system

Deploy Postgres in the Swarm. Then honestly evaluate three approaches:

1. `--constraint node.hostname==node2` plus a local volume.
2. An NFS volume shared across nodes.
3. Postgres outside the cluster entirely.

For each: what happens when the node dies? What is the recovery time? What can silently corrupt?

Then state which you would choose for a 5-person startup, and why.

---

### C10.4 — The scheduling puzzle

Construct a stack where a service **cannot** be scheduled, for each of these distinct reasons, and capture the exact `docker service ps --no-trunc` message for each:

1. an unsatisfiable placement constraint;
2. insufficient memory reservation on every node;
3. every node drained;
4. a published port already in use;
5. an image that cannot be pulled;
6. a `global` service on a node that already has the task.

That table of six error strings is a genuinely useful artefact. Keep it.

---

### C10.5 — Survive the manager

With three managers, work out and then **verify experimentally**:

1. What still works when one manager is down?
2. What still works when two are down?
3. Do running containers keep serving traffic with zero managers?
4. How do you recover a cluster that has permanently lost quorum?

Question 4 requires `docker swarm init --force-new-cluster`. Read the documentation *before* you need it, and write the runbook.

---

### C10.6 — Compose to Swarm

Take the Week 8 Compose stack and migrate it. Produce a written list of every change required and every capability lost.

Then answer the hard one: the Week 8 stack relies on `condition: service_healthy` for startup ordering, which Swarm does not have. **What breaks, and what do you do about it?**

---

### C10.7 — Is Swarm enough?

Write an honest assessment for a team of five running twelve services:

- three things Swarm does that they need;
- three things it does not do that they will eventually want;
- the specific event that would tell them it is time to move to Kubernetes;
- the cost of moving, in weeks.

An answer that concludes "use Kubernetes because it is the standard" fails this challenge.
