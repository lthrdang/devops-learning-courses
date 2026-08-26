#!/usr/bin/env bash
# DRILL 10 - "I scaled to 6 replicas and NONE of them are running."  Week 10.
# Run on the Swarm MANAGER node.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
docker node ls >/dev/null 2>&1 || { echo "run this on a swarm manager"; exit 1; }

SERVICE=${SERVICE:-web}
docker service inspect "$SERVICE" >/dev/null 2>&1 || {
  docker service create --name "$SERVICE" --replicas 2 -p 8080:80 nginx:alpine >/dev/null
}

# NOT a fault - a spread policy the "team" already had. `--replicas-max-per-node`
# caps how many tasks of this service any one node may run, so a single machine
# cannot end up hosting the entire service. With 3 nodes and a cap of 2 the
# cluster has room for exactly 6 tasks, which is what makes fault 1 below
# produce a real, deterministic shortfall instead of Swarm quietly stacking all
# six replicas onto whatever nodes remain. Leave it in place while debugging;
# understanding it is part of the exercise.
docker service update --replicas-max-per-node 2 "$SERVICE" >/dev/null 2>&1 || true

# --- the damage ---
# Fault 1: one worker drained. Drained nodes stay Ready and Active-looking in a
# casual glance at `docker node ls`; you must read the AVAILABILITY column.
# Combined with the cap above this removes 2 of the 6 available slots, so the
# service settles at 4/6 once fault 2 is cleared.
WORKER=$(docker node ls --format '{{.Hostname}} {{.ManagerStatus}}' \
         | awk '$2=="" {print $1; exit}')
[[ -n "$WORKER" ]] && docker node update --availability drain "$WORKER" >/dev/null

# Fault 2: a placement constraint that no node satisfies. A constraint is part
# of the SERVICE spec, not a per-task property, so it applies to every task at
# once: all six go Pending and the service reads 0/6, not "mostly fine". That
# all-or-nothing signature is the tell, and it is what the learner has to name.
docker service update --constraint-add 'node.labels.tier==gold' \
  --update-parallelism 1 "$SERVICE" >/dev/null 2>&1 || true

# There is no fault 3. Earlier versions of this drill intended a port-squatter
# container holding 8080 on one node, and it cannot work: the service itself
# publishes 8080 through the ingress mesh, so the squatter has nowhere to bind
# and simply fails to start. A genuine port conflict shows up as REJECTED
# rather than Pending, which is a different lesson - it lives in C10.4, where
# you reason about it without needing to reproduce it. This line only cleans up
# after anyone who ran the older script.
docker rm -f portsquatter >/dev/null 2>&1 || true

docker service scale "${SERVICE}=6" >/dev/null 2>&1 || true
sleep 5

base64 -w0 > /root/.drill-10-swarm <<'NOTE'
TWO FAULTS, and they surface IN ORDER - you cannot see the second until you
have fixed the first. That sequencing is the point of the drill.

READ THE NUMBER FIRST. `docker service ls` says 0/6: not one task is running.
  * ALL tasks Pending  -> the cause is SERVICE-WIDE. Constraints, resource
    reservations and image references live in the service spec and apply to
    every task identically, so they fail every task identically.
  * SOME running, some Pending -> the cause is about CAPACITY or specific
    NODES: not enough nodes, not enough memory, a per-node cap, drained nodes.
  Getting this classification right in one glance saves you most of the search.

FAULT A (why it is 0/6): AN UNSATISFIABLE PLACEMENT CONSTRAINT.
  node.labels.tier==gold, and no node carries that label. Tasks stay Pending
  forever - Swarm does not warn you, it just never schedules.
  Detect: docker service ps web --no-trunc
            -> "no suitable node (scheduling constraints not satisfied on 3 nodes)"
          docker service inspect web --format '{{json .Spec.TaskTemplate.Placement}}'
          docker node inspect <node> --format '{{json .Spec.Labels}}'
  Fix: either remove the constraint
         docker service update --constraint-rm 'node.labels.tier==gold' web
       or satisfy it
         docker node update --label-add tier=gold <node>
  NOTE: --constraint-rm is an EXACT STRING MATCH including spaces. If it does
  not match, the command still SUCCEEDS and nothing changes. Verify with
  `docker service inspect`, never with the exit code.

FAULT B (why it then stops at 4/6, not 6/6): A DRAINED WORKER.
  `docker node ls` -> the AVAILABILITY column reads "Drain". Drained nodes are
  healthy and reachable; the scheduler simply refuses to place tasks on them.
  Draining is the CORRECT way to take a node out for maintenance, so a drained
  node usually means someone forgot to un-drain it afterwards.
  This only produces a shortfall because the service also carries
  --replicas-max-per-node 2: 3 nodes x 2 = 6 slots, minus a drained node = 4.
  Without that cap Swarm would happily pack all 6 onto the 2 remaining nodes
  and you would never notice the drain - which is its own lesson about why a
  green replica count is not the same as the placement you designed.
  Detect: docker service ps web --no-trunc
            -> "no suitable node (max replicas per node limit exceed)"
          docker node ls        # read AVAILABILITY, not just STATUS
  Fix: docker node update --availability active <node>

THE METHOD - for any "replicas != desired", always in this order:
   docker service ls                      # 0/N or partial? classify FIRST
   docker service ps <svc> --no-trunc     # WHY each task is where it is
   docker node ls                         # are all nodes Ready AND Active?
   docker service inspect <svc>           # constraints, resources, mode, caps
   docker service logs <svc>              # is the app itself crashing?
   The --no-trunc is essential: the ERROR column is truncated by default and the
   truncated text is usually the useless half.
NOTE
chmod 0600 /root/.drill-10-swarm

cat <<'MSG'

  SYMPTOM REPORTED BY THE USER
  ----------------------------
  "I scaled the web service to 6 replicas twenty minutes ago. `docker service ls`
   still says 0/6 - not one of them is running. No errors anywhere that I can
   see. All three nodes are Ready."

  Reproduce it:   docker service ls
                  docker service ps web

MSG
