#!/usr/bin/env bash
# DRILL 09 - "it's slow. not down. just slow."  Week 09.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

# --- the damage ---
# Fault 1: a CPU hog with a nice name nobody questions, pinned to one core so
# it competes with the real workload instead of being spread thin across all of
# them. The disguise matters: half of troubleshooting is noticing that the
# plausible-looking process at the top of `top` is not something you installed.
# stress-ng takes its worker names from argv[0], so we install a copy of the
# binary under an innocuous name and run THAT - `pkill -f labmetrics` then has
# something to match, which is also what makes re-running this drill idempotent
# instead of stacking a second hog on top of the first.
command -v stress-ng >/dev/null || { apt-get update -qq && apt-get install -y -qq stress-ng; }
HOG=/usr/local/bin/labmetrics-collector
install -m 0755 "$(command -v stress-ng)" "$HOG"

# Kill anything left over from a previous run BEFORE starting a new one, or the
# drill gets progressively harder every time you run it.
pkill -f 'labmetrics-collector' 2>/dev/null || true
sleep 1

# taskset pins it to CPU 0. On a multi-core box an unpinned 85% hog is barely
# visible in the average; pinned, `mpstat -P ALL` shows one core buried and the
# rest idle - the signature of a single-threaded bottleneck.
setsid taskset -c 0 "$HOG" --cpu 1 --cpu-load 85 --quiet \
  --log-file /dev/null >/dev/null 2>&1 < /dev/null &

# Fault 2: artificial latency on the loopback/egress path. 150 ms added to every
# packet leaving this host - so the app's own timings look fine while anything
# that calls a dependency crawls.
if command -v tc >/dev/null; then
  IFACE=$(ip route show default | awk '{print $5; exit}')
  tc qdisc del dev "$IFACE" root 2>/dev/null || true
  tc qdisc add dev "$IFACE" root netem delay 150ms 40ms distribution normal 2>/dev/null || true
  echo "$IFACE" > /root/.drill09-iface
fi

# Fault 3: memory pressure pushing the box into swap, so p99 spikes while the
# median stays acceptable - the classic "only sometimes slow" signature. Same
# disguised binary, so the same pkill cleans both up.
setsid "$HOG" --vm 1 --vm-bytes 55% --vm-keep --quiet \
  >/dev/null 2>&1 < /dev/null &

base64 -w0 > /root/.drill-09-latency <<'NOTE'
THREE CONCURRENT CAUSES. Use the USE method (Utilisation, Saturation, Errors)
on each resource rather than guessing:
1. CPU: a stress-ng worker consuming ~85% of ONE core, pinned there with
   taskset, and running under the name "labmetrics-collector" out of
   /usr/local/bin - a name chosen to look like it belongs. Nothing in the
   package manager owns that file; `dpkg -S /usr/local/bin/labmetrics-collector`
   says so in one line.
   Detect: top / htop (sort by CPU), `pidstat 1`, or load average vs nproc.
           mpstat -P ALL 1 - ONE core buried, the rest idle, which no amount
           of extra CPU would fix.
           Key idea: load average of 2.0 on a 1-core box means SATURATION - a
           run queue, i.e. work waiting - not merely "busy".
   Fix: pkill -f labmetrics-collector
2. NETWORK: `tc qdisc` netem adds 150ms +/- 40ms to every packet on the default
   interface. The application's internal timers look normal; only calls that
   cross the network are slow, which is why "the app logs say it's fast".
   Detect: tc qdisc show ; ping your gateway and compare to a known baseline ;
           curl -w '%{time_connect} %{time_starttransfer} %{time_total}\n'
           - time_connect inflated points at network, time_starttransfer
           inflated points at the server thinking.
   Fix: tc qdisc del dev "$(cat /root/.drill09-iface)" root
3. MEMORY: a stress-ng vm worker holding ~55% of RAM, pushing the box towards
   swap. Symptom is a bimodal latency distribution: fine median, terrible p99.
   Detect: free -m ; vmstat 1 (watch si/so columns) ; `sar -B` for page faults.
   Fix: pkill -f labmetrics-collector   (same process name as fault 1)
LESSON: averages hide incidents. A p50 of 40ms with a p99 of 3s is an outage for
        1 request in 100 - and if a page makes 50 calls, that is most pages.
        Always measure percentiles, and always check saturation, not just usage.

FULL CLEANUP (both faults 1 and 3, then fault 2):
  sudo pkill -f labmetrics-collector
  sudo rm -f /usr/local/bin/labmetrics-collector
  sudo tc qdisc del dev "$(sudo cat /root/.drill09-iface)" root
NOTE
chmod 0600 /root/.drill-09-latency

cat <<'MSG'

  SYMPTOM REPORTED BY THE USER
  ----------------------------
  "The site is slow. Not down - everything eventually loads. It's been like this
   since about an hour ago. Nothing was deployed. Sometimes it's fine, sometimes
   a page takes five seconds."

  Reproduce it:   curl -o /dev/null -s -w 'connect=%{time_connect} ttfb=%{time_starttransfer} total=%{time_total}\n' http://localhost/
                  uptime ; free -m

  Cleanup steps are in the answer key, not here - naming the commands names the
  faults, and two of the three would be given away before you had measured
  anything. After your timebox:

      sudo cat /root/.drill-09-latency | base64 -d

MSG
