#!/usr/bin/env bash
#
# swarm-init.sh - form a 3-node swarm from the manager.
#
#   On node1:  ./swarm-init.sh init <NODE1_IP>
#   It prints the exact join commands to run on node2 and node3.
#
set -euo pipefail

log() { printf '[swarm] %s\n' "$*"; }
die() { printf '[swarm] %s\n' "$*" >&2; exit 1; }

cmd_init() {
  local advertise=${1:?usage: swarm-init.sh init <THIS_NODE_IP>}

  # --advertise-addr is REQUIRED on a multi-homed host. Without it Swarm may
  # advertise the wrong interface, workers join "successfully", and overlay
  # traffic silently fails - a genuinely miserable thing to debug.
  docker swarm init --advertise-addr "$advertise"

  echo
  log "Run this on each WORKER:"
  echo
  docker swarm join-token worker | grep 'docker swarm join'
  echo
  log "Run this to add another MANAGER (use an ODD total: 1, 3 or 5):"
  echo
  docker swarm join-token manager | grep 'docker swarm join'
  echo
  log "Then, back here:  ./swarm-init.sh verify"
}

cmd_verify() {
  docker node ls >/dev/null 2>&1 || die "not a swarm manager"

  echo
  log "nodes:"
  docker node ls
  echo
  log "REQUIRED PORTS between nodes (a swarm that joins but does not work is"
  log "almost always one of these):"
  cat <<'EOF'
    2377/tcp        cluster management        (managers only)
    7946/tcp+udp    node discovery / gossip   (all nodes)
    4789/udp        VXLAN overlay data plane  (all nodes)

  Miss 4789/udp and services deploy fine while cross-node traffic silently
  fails. Miss 7946/udp and nodes flap between Ready and Down.
EOF

  echo
  log "quorum check:"
  local managers
  managers=$(docker node ls --filter role=manager --format '{{.ID}}' | wc -l)
  local quorum=$(( managers / 2 + 1 ))
  printf '    %d manager(s), quorum = %d, can lose %d\n' \
    "$managers" "$quorum" "$(( managers - quorum ))"
  if (( managers % 2 == 0 )); then
    log "WARNING: an EVEN number of managers. ${managers} managers tolerate the"
    log "         same failures as $(( managers - 1 )) while doubling the chance of one."
  fi
}

cmd_label() {
  # Labels drive placement constraints and spread preferences.
  local i=1
  for node in $(docker node ls --format '{{.Hostname}}'); do
    docker node update --label-add "zone=z$(( (i % 3) + 1 ))" "$node" >/dev/null
    log "labelled ${node} zone=z$(( (i % 3) + 1 ))"
    i=$(( i + 1 ))
  done
  docker node ls --format '{{.Hostname}}' \
    | while read -r n; do
        printf '  %-12s %s\n' "$n" "$(docker node inspect "$n" --format '{{json .Spec.Labels}}')"
      done
}

case "${1:-}" in
  init)   shift; cmd_init "$@" ;;
  verify) cmd_verify ;;
  label)  cmd_label ;;
  *) die "usage: swarm-init.sh {init <ip>|verify|label}" ;;
esac
