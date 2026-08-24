# Week 10 — Lab

```bash
cd infra && make w10-up        # node1, node2, node3
./scripts/lab-up.sh hosts node1 node2 node3
```

You will want **three terminals**, one per node.

---

## Part 1 — Form the cluster (Day 1)

On **node1**:

```bash
NODE1_IP=$(hostname -I | awk '{print $1}')
./swarm-init.sh init "$NODE1_IP"
```

Copy the printed `docker swarm join` command and run it on **node2** and **node3**. Then back on node1:

```bash
./swarm-init.sh verify
docker node ls
```

> **`--advertise-addr` is not optional on a multi-homed host.** Without it, Swarm may advertise the wrong interface; workers join "successfully", services deploy, and overlay traffic silently fails. That is a genuinely miserable afternoon.

```bash
# 1.1 Read the columns. BOTH of them.
docker node ls
# ID   HOSTNAME   STATUS   AVAILABILITY   MANAGER STATUS
#                 ^Ready   ^Active        ^Leader / Reachable
```

`STATUS` is *can I reach it*. `AVAILABILITY` is *may I schedule on it*. A node can be `Ready` and `Drain` — healthy, reachable, and deliberately empty. **This is fault 1 of the drill.**

```bash
# 1.2 Quorum arithmetic
docker node ls --filter role=manager
docker info --format '{{.Swarm.Managers}} managers, {{.Swarm.Nodes}} nodes'
```

Promote node2 to manager and observe:

```bash
docker node promote node2
docker node ls
```

> You now have **two** managers: quorum is 2, so you tolerate **zero** failures — strictly worse than one manager. Promote node3 as well (three managers, quorum 2, tolerates one), or demote node2 back. Write the reasoning in your logbook.

```bash
# 1.3 Label the nodes - placement depends on this
./swarm-init.sh label
docker node inspect node2 --format '{{json .Spec.Labels}}'
```

---

## Part 2 — Services, and the ports that must be open (Day 2)

```bash
docker service create --name web --replicas 3 -p 8080:80 nginx:alpine
docker service ls
docker service ps web
```

### 2.1 The routing mesh, proved

```bash
for n in node1 node2 node3; do
  echo -n "$n: "; curl -s -o /dev/null -w '%{http_code}\n' "http://$n:8080/"
done
```

All three answer — **including any node that runs no replica.** Confirm which nodes actually host tasks:

```bash
docker service ps web --format 'table {{.Name}}\t{{.Node}}\t{{.CurrentState}}'
```

### 2.2 Break the overlay deliberately

On **node3**:

```bash
sudo nft add table inet swarmtest
sudo nft add chain inet swarmtest input '{ type filter hook input priority 0; policy accept; }'
sudo nft add rule inet swarmtest input udp dport 4789 drop
```

From node1, hit `node3:8080` repeatedly and watch what happens to requests that need to reach a task on another node.

```bash
for i in $(seq 1 10); do curl -s -m3 -o /dev/null -w '%{http_code} ' http://node3:8080/; done; echo
```

> **This is the failure mode to recognise.** The cluster is healthy, `docker node ls` says `Ready`, services say `3/3`, and traffic silently fails. Missing **4789/udp** is the single most common Swarm networking fault. Remove the rule afterwards: `sudo nft delete table inet swarmtest`.

Now try blocking `7946/udp` on node3 and watch `docker node ls` from node1 for a minute. Different fault, different fingerprint — the node flaps between `Ready` and `Down`.

### 2.3 Service discovery and the VIP

```bash
docker network create --driver overlay --attachable appnet
docker service create --name api --network appnet --replicas 3 \
  nginx:alpine

docker run --rm --network appnet alpine sh -c 'apk add -q bind-tools; dig +short api; dig +short tasks.api'
```

- `api` → **one** address: the **VIP**. Stable, load-balanced by the kernel's IPVS.
- `tasks.api` → **every** task address.

> **This is what structurally fixes the Week 8 nginx problem.** There, nginx cached the one IP it resolved at startup and sent everything to a single replica. Here the VIP never changes, so caching it is harmless — a stable front for a changing set of backends. Swarm solved by design what we worked around with a `resolver` directive.

---

## Part 3 — Deploy a stack (Day 4)

```bash
cd /opt/lab/w10
echo -n 'hunter2' | docker secret create db_password -
docker secret ls
docker stack deploy -c stack.yml lab
```

### 3.1 Read the failures — they are the lesson

```bash
docker stack services lab
docker stack ps lab --no-trunc --format 'table {{.Name}}\t{{.CurrentState}}\t{{.Error}}'
```

Measured output on a fresh cluster:

```
lab_agent.xxx    Running 16 seconds ago
lab_api.1        Rejected 11 seconds ago   "No such image: lab/swarm-api:1.0"
lab_web.1        Pending                   "no suitable node (scheduling constraints not satisfied on 1 node)"
```

**Two distinct lessons in one output:**

1. **`lab_api` — "No such image".** `build:` is **ignored** by Swarm. It deploys images; it does not build them. You must build and push to a registry that every node can pull from. This is the number-one surprise when migrating from Compose. (Week 11 sets up a registry.)

2. **`lab_web` — "no suitable node".** The stack constrains it to `node.role == worker`. On a single-node cluster, or if you deployed before joining workers, nothing satisfies it and tasks sit in `PENDING` **forever**. Swarm does not warn you; it simply never schedules.

```bash
# Diagnose it properly - this is the method for EVERY scheduling problem
docker service ps lab_web --no-trunc
docker service inspect lab_web --format '{{json .Spec.TaskTemplate.Placement}}' | jq
docker node ls
```

### 3.2 The `--constraint-rm` gotcha

```bash
docker service update --constraint-rm 'node.role==worker' lab_web    # does NOTHING
docker service update --constraint-rm 'node.role == worker' lab_web  # works
```

> The constraint is stored **verbatim, with the spacing you wrote**. `--constraint-rm` is an exact string match, and removing a constraint that does not match fails silently — the command succeeds and nothing changes. Always confirm with `docker service inspect ... .Spec.TaskTemplate.Placement` rather than trusting the exit code.

### 3.3 Global mode and configs

```bash
docker service ps lab_agent            # exactly one task per node
docker service logs lab_agent --tail 5
```

```
lab_agent.0.xxx@node1  | 2026-08-24T08:23:52+00:00 agent on 8e27b66ed866
```

> The `$$(date -Is)` in the stack file is **doubled on purpose**. Compose interpolates `${VAR}` and `$(...)` in the stack file *before* Docker sees it, so a substitution meant for the container's shell must be escaped as `$$`. Getting it wrong gives `invalid interpolation format` — or, worse, a silently empty value.

```bash
curl -s http://node1:8080/            # served from the docker config
docker config ls
docker config inspect lab_web_index --format '{{.Spec.Name}}'
```

---

## Part 4 — Rolling updates, measured (Day 3)

This is the centrepiece of the week. **Run a request loop in one terminal for the whole exercise:**

```bash
# terminal A - never stop this
while true; do
  code=$(curl -s -o /dev/null -m3 -w '%{http_code}' http://node1:8080/ || echo FAIL)
  [ "$code" = "200" ] || echo "$(date +%T) BAD: $code"
  sleep 0.3
done
```

```bash
# terminal B
docker service update --image nginx:1.27-alpine --detach lab_web

# terminal C - watch capacity
for i in $(seq 1 15); do
  printf '%s  replicas=%-6s  update=%s\n' "$(date +%T)" \
    "$(docker service ls --filter name=lab_web --format '{{.Replicas}}')" \
    "$(docker service inspect lab_web --format '{{.UpdateStatus.State}}')"
  sleep 8
done
```

Measured result:

```
08:25:16  replicas=3/3     update=updating
...
08:26:12  replicas=4/3     update=updating      ← FOUR of three
08:26:20  replicas=3/3     update=updating
...
```

> **`replicas=4/3` is `order: start-first` working.** The new task started *before* the old one stopped, so capacity briefly went **above** desired and never below it. Terminal A recorded **zero** failed requests.

Now prove the contrast:

```bash
docker service update --update-order stop-first --image nginx:alpine --detach lab_web
```

Watch terminal C for `2/3` — capacity dipping **below** desired — and check terminal A for failures. With 3 replicas and a fast healthcheck you may see none; reduce to `--replicas 1` and repeat, and the difference becomes unmissable.

### 4.1 Automatic rollback

```bash
docker service update --image nginx:this-tag-does-not-exist --detach lab_web
watch -n2 'docker service inspect lab_web --format "{{.UpdateStatus.State}} {{.UpdateStatus.Message}}"'
```

Swarm tries, the tasks fail, `failure_action: rollback` triggers, and it reverts by itself. **Nobody was paged.** That is the highest-value line of configuration in this week's stack file.

### 4.2 Manual rollback

```bash
docker service inspect lab_web --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'
docker service inspect lab_web --format '{{.PreviousSpec.TaskTemplate.ContainerSpec.Image}}'
docker service rollback --detach lab_web
```

Measured:

```
current image: nginx:1.27-alpine
previous spec: nginx:alpine
after rollback: nginx:alpine
```

> Swarm keeps **exactly one** previous spec. Roll back twice and you are where you started. Real version history lives in git with the stack file — which is the argument for deploying from a committed file rather than typing `service update`.

---

## Part 5 — Node failure (Day 4)

**Keep the request loop running.**

```bash
docker service ps lab_web --format 'table {{.Name}}\t{{.Node}}'
```

```bash
# from your HOST - simulate a node dying, hard
multipass stop node3
```

```bash
# on node1
watch -n2 'docker node ls; echo; docker service ps lab_web --format "table {{.Name}}\t{{.Node}}\t{{.CurrentState}}"'
```

Time three things and write them down:
1. how long until `node3` shows `Down`;
2. how long until its tasks are rescheduled elsewhere;
3. **how many requests failed in terminal A.**

```bash
multipass start node3
docker node ls          # it rejoins
```

> Note that the rescheduled tasks do **not** move back. Swarm has no rebalancing on rejoin — a real operational wrinkle. `docker service update --force lab_web` redistributes them.

### 5.1 Drain for maintenance

```bash
docker node update --availability drain node2
docker service ps lab_web --format 'table {{.Name}}\t{{.Node}}\t{{.CurrentState}}'
docker node ls                      # node2: Ready / Drain
docker node update --availability active node2
```

> **`Ready` and `Drain` simultaneously.** Healthy, reachable, deliberately empty. Forgetting to reactivate after maintenance is fault 1 of the drill and a very common real-world cause of "why are only 4 of my 6 replicas running?".

---

## Part 6 — Secrets (Day 4)

```bash
docker service create --name sec --secret db_password alpine sleep 3600
CID=$(docker ps --filter name=sec -q)
docker exec "$CID" cat /run/secrets/db_password
docker exec "$CID" mount | grep secrets        # tmpfs - never on disk
docker inspect "$CID" --format '{{json .Config.Env}}'   # NOT there
```

Rotate it:

```bash
echo -n 'newpassword' | docker secret create db_password_v2 -
docker service update \
  --secret-rm db_password \
  --secret-add source=db_password_v2,target=db_password \
  sec
```

> `target=` keeps the in-container path stable, so the application needs no change. Rotation is therefore a **rolling update** — zero-downtime, and only safe if you have a healthcheck.

---

## Part 7 — Drill (Day 5)

```bash
cd infra
make snapshot VM=node1 NAME=pre-w10
make break VM=node1 DRILL=10-swarm
```

Symptom: *"I scaled to 6 replicas twenty minutes ago. `docker service ls` still says 4/6. All three nodes are Ready."*

Note the phrasing: **"all three nodes are Ready"**. Given Part 5.1, what has the reporter probably not looked at?
