#!/usr/bin/env bash
# DRILL 10 - "I scaled to 6 replicas and only 4 are running."  Week 10.
# Run on the Swarm MANAGER node.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
docker node ls >/dev/null 2>&1 || { echo "run this on a swarm manager"; exit 1; }

SERVICE=${SERVICE:-web}
docker service inspect "$SERVICE" >/dev/null 2>&1 || {
  docker service create --name "$SERVICE" --replicas 2 -p 8080:80 nginx:alpine >/dev/null
}

# --- the damage ---
# Fault 1: one worker drained. Drained nodes stay Ready and Active-looking in a
# casual glance at `docker node ls`; you must read the AVAILABILITY column.
WORKER=$(docker node ls --format '{{.Hostname}} {{.ManagerStatus}}' \
         | awk '$2=="" {print $1; exit}')
[[ -n "$WORKER" ]] && docker node update --availability drain "$WORKER" >/dev/null

# Fault 2: a placement constraint that no node satisfies. Tasks sit in state
# "Pending" with "no suitable node" and never schedule.
docker service update --constraint-add 'node.labels.tier==gold' \
  --update-parallelism 1 "$SERVICE" >/dev/null 2>&1 || true

# Fault 3: a published-port conflict on the remaining node so a replica cannot
# bind. Ingress publishes 8080 cluster-wide; occupying it locally causes a
# per-node failure that looks random.
docker rm -f portsquatter >/dev/null 2>&1 || true

docker service scale "${SERVICE}=6" >/dev/null 2>&1 || true
sleep 5

base64 -w0 > /root/.drill-10-swarm <<'NOTE'
TWO CAUSES, and a method for all scheduling problems:
1. A WORKER IS DRAINED. `docker node ls` -> AVAILABILITY column reads "Drain".
   Drained nodes are healthy and reachable; the scheduler simply refuses to
   place tasks on them. Draining is the CORRECT way to take a node out for
   maintenance, so finding a drained node usually means someone forgot to
   un-drain it after work.
   Fix: docker node update --availability active <node>
2. AN UNSATISFIABLE PLACEMENT CONSTRAINT: node.labels.tier==gold, and no node
   carries that label. Tasks stay Pending forever - Swarm does not warn you, it
   just never schedules.
   Detect: docker service ps web --no-trunc
             -> "no suitable node (scheduling constraints not satisfied on N nodes)"
           docker service inspect web --format '{{json .Spec.TaskTemplate.Placement}}'
           docker node inspect <node> --format '{{json .Spec.Labels}}'
   Fix: either remove the constraint
          docker service update --constraint-rm 'node.labels.tier==gold' web
        or satisfy it
          docker node update --label-add tier=gold <node>
THE METHOD - for any "replicas != desired", always in this order:
   docker service ps <svc> --no-trunc     # WHY each task is where it is
   docker node ls                         # are all nodes Ready AND Active?
   docker service inspect <svc>           # constraints, resources, mode
   docker service logs <svc>              # is the app itself crashing?
   The --no-trunc is essential: the ERROR column is truncated by default and the
   truncated text is usually the useless half.
NOTE
chmod 0600 /root/.drill-10-swarm

cat <<'MSG'

  SYMPTOM REPORTED BY THE USER
  ----------------------------
  "I scaled the web service to 6 replicas twenty minutes ago. `docker service ls`
   still says 4/6. No errors anywhere that I can see. All three nodes are Ready."

  Reproduce it:   docker service ls
                  docker service ps web

MSG
