#!/usr/bin/env bash
# DRILL 04 - "ping works but nothing else does".  Week 04.
# Run this on VM 'alpha'. 'beta' should be running a service on :8080.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

# Make sure there is something to fail against: a listener on beta's port is
# assumed; locally we add one too so the drill is self-contained.
install -d -m 0755 /opt/lab
cat > /etc/systemd/system/labecho.service <<'INNER'
[Unit]
Description=Lab echo listener
After=network.target
[Service]
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
[Install]
WantedBy=multi-user.target
INNER
systemctl daemon-reload && systemctl enable --now labecho.service >/dev/null 2>&1 || true

# --- the damage ---
# Fault 1: an nftables rule dropping outbound TCP to port 8080 only. ICMP is
# untouched, so ping succeeds and misleads everyone.
nft add table inet labfilter 2>/dev/null || true
nft add chain inet labfilter output '{ type filter hook output priority 0; policy accept; }' 2>/dev/null || true
nft add rule inet labfilter output tcp dport 8080 drop 2>/dev/null || true

# Fault 2: a stale /etc/hosts entry pointing 'beta' at an address nobody owns.
sed -i '/[[:space:]]beta$/d' /etc/hosts 2>/dev/null || true
echo "10.99.99.99 beta" >> /etc/hosts

# Fault 3: the service binds loopback only, so it is unreachable from outside
# even once the firewall is fixed. Layered on purpose.
install -d -m 0755 /etc/systemd/system/labecho.service.d
cat > /etc/systemd/system/labecho.service.d/10-bind.conf <<'INNER'
[Service]
ExecStart=
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 127.0.0.1
INNER
systemctl daemon-reload && systemctl restart labecho.service

base64 -w0 > /root/.drill-04-network <<'NOTE'
THREE LAYERED FAULTS, each hiding the next:
1. NAME RESOLUTION: /etc/hosts maps 'beta' to 10.99.99.99, which does not exist.
   Detect: getent hosts beta ; compare with `multipass list`.
   Note that ping 'beta' then fails too - but ping <real-ip> works, and that
   difference is the tell.
2. FIREWALL: `nft list ruleset` shows a rule dropping outbound tcp dport 8080 in
   table inet labfilter. ICMP is not filtered, which is exactly why ping lies.
   Detect: nft list ruleset ; or notice `nc -vz <ip> 8080` hangs then times out,
   while a REFUSED (RST) would mean "reached the host, nothing listening".
   Timeout vs refused is the single most useful distinction in network debugging.
   Fix: nft delete table inet labfilter
3. BINDING: a drop-in makes labecho bind 127.0.0.1 instead of 0.0.0.0, so it is
   reachable only from the machine itself.
   Detect: ss -tlnp | grep 8080  ->  127.0.0.1:8080 rather than 0.0.0.0:8080
   Fix: remove /etc/systemd/system/labecho.service.d/10-bind.conf, daemon-reload,
   restart.
LESSON: work bottom-up through the layers and prove each one before moving on:
        resolve -> route -> reachable -> port open -> process listening on the
        right address -> application answers.
NOTE
chmod 0600 /root/.drill-04-network

cat <<'MSG'

  SYMPTOM REPORTED BY THE USER
  ----------------------------
  "From alpha I can ping beta, so the network is obviously fine. But
   curl http://beta:8080 just hangs and eventually times out."

  Reproduce it:   ping -c2 beta
                  curl -m 5 -v http://beta:8080/ ; echo "exit=$?"
                  curl -m 5 -v http://localhost:8080/ ; echo "exit=$?"

MSG
