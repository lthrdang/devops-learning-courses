#!/usr/bin/env bash
# DRILL 12 - GAME DAY.  Week 12.  No hints. Multiple simultaneous faults.
#
# Run on the swarm manager. Faults are chosen pseudo-randomly from a fixed set,
# seeded by an argument so an instructor can reproduce a given scenario:
#     sudo bash 12-gameday.sh 7
#
# You are on call. You get a page. That is all you get.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

SEED=${1:-1}
pick() { echo $(( (SEED * 7919 + $1 * 104729) % 100 )); }

APPLIED=()

# --- fault pool ---
if [[ $(pick 1) -lt 60 ]]; then
  # log flood -> disk pressure
  cat > /opt/lab/.flood.sh <<'INNER'
#!/bin/bash
while :; do
  head -c 1M /dev/urandom | base64 >> /var/log/lab-flood.log
  sleep 1
done
INNER
  chmod +x /opt/lab/.flood.sh
  setsid /opt/lab/.flood.sh >/dev/null 2>&1 </dev/null &
  APPLIED+=("log flood filling / via /var/log/lab-flood.log (find with du -x / | sort -h | tail; kill /opt/lab/.flood.sh)")
fi

if [[ $(pick 2) -lt 55 ]]; then
  W=$(docker node ls --format '{{.Hostname}} {{.ManagerStatus}}' | awk '$2=="" {print $1; exit}')
  [[ -n "$W" ]] && { docker node update --availability pause "$W" >/dev/null; \
    APPLIED+=("node ${W} set to availability=pause: existing tasks keep running, NO new tasks are scheduled there. Subtler than drain."); }
fi

if [[ $(pick 3) -lt 50 ]]; then
  IFACE=$(ip route show default | awk '{print $5; exit}')
  tc qdisc del dev "$IFACE" root 2>/dev/null || true
  tc qdisc add dev "$IFACE" root netem loss 7% 2>/dev/null || true
  APPLIED+=("7% packet LOSS on ${IFACE} via tc netem. Causes retransmits and tail latency, not hard failure. Find with: tc qdisc show; ping -c50 and read the loss line.")
fi

if [[ $(pick 4) -lt 45 ]]; then
  # clock skew - breaks TLS validation and makes correlating logs impossible
  timedatectl set-ntp false 2>/dev/null || true
  date -s '+00:47:00' >/dev/null 2>&1 || true
  APPLIED+=("clock skewed +47 minutes and NTP disabled. Breaks certificate validity windows and makes log correlation across hosts impossible. Find with: timedatectl; compare date across nodes.")
fi

if [[ $(pick 5) -lt 40 ]]; then
  # file descriptor limit on a unit
  install -d -m 0755 /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/99-limits.conf <<'INNER'
[Service]
LimitNOFILE=256
INNER
  systemctl daemon-reload
  APPLIED+=("docker.service LimitNOFILE lowered to 256 via drop-in. Manifests as 'too many open files' only under load. Find with: systemctl show docker -p LimitNOFILE; cat /proc/\$(pidof dockerd)/limits")
fi

{
  echo "GAME DAY seed=${SEED}"
  echo "faults applied:"
  # ${arr[@]} on an empty array is an unbound-variable error under `set -u`,
  # hence the length guard. This bites people in real scripts constantly.
  if [[ ${#APPLIED[@]} -gt 0 ]]; then
    printf '  - %s\n' "${APPLIED[@]}"
  else
    echo "  (none - re-run with a different seed)"
  fi
} | base64 -w0 > /root/.drill-12-gameday
chmod 0600 /root/.drill-12-gameday

cat <<'MSG'

  ############################################################
  #  PAGE: "Checkout is failing for some users."             #
  #  Severity: SEV-2                                          #
  #  Reported: just now                                       #
  ############################################################

  You are on call. Nobody is going to give you more information than that.

  Your deliverables, in this order:
    1. A one-line status update within 10 minutes ("investigating, impact is X").
    2. Mitigation (stop the bleeding) - not necessarily a root-cause fix.
    3. A written postmortem using week-12/files/postmortem-template.md.

  Remember: MITIGATE FIRST, understand second. A rollback at minute 5 beats a
  root cause at minute 90.

MSG
