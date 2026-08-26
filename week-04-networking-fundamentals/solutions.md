# Week 04 — Solutions & discussion

---

## C4.6 — Explain the symptom (start here; it is the core skill)

### 1. Hostname times out, IP works
**It is name resolution, and the name resolves to the WRONG address** — not to no address. If it resolved to nothing, you would get "Could not resolve host" immediately, not a timeout. So something is answering with a bad answer.

Check in order: `getent hosts NAME` (what the app will actually get) → `/etc/hosts` for a stale entry → `dig NAME` vs `dig @1.1.1.1 NAME` (local resolver vs upstream) → a search-domain suffix silently appended (`resolvectl status`).

**Fastest discriminator:** `getent hosts NAME` — compare its answer to the address you know is right. This is fault #1 in drill 04.

### 2. Works from the server, not from another host
Almost always one of three, in this order of likelihood:

`ss -tlnp | grep PORT` → bound to `127.0.0.1` instead of `0.0.0.0`.
`sudo nft list ruleset` → a rule dropping it.
`ip route get CLIENT_IP` on the server → no return path (asymmetric routing).

**Fastest discriminator:** `ss -tlnp` on the server. It resolves the most common case in one line.

### 3. ping works, curl times out
Layer 3 is fine, layer 4 is blocked. ICMP and TCP are different protocols and firewalls routinely treat them differently — which is precisely why "I can ping it, so the network is fine" is a false statement that wastes hours.

Check: `nc -vz host port` (refused vs timeout) → `ss -tlnp` on the server → firewall → `tcpdump` on the server to see whether the SYN arrives.

**Fastest discriminator:** `tcpdump -i any -n port PORT` **on the server**. Either the SYN arrives (firewall/app problem) or it does not (path problem). Nothing else answers that question.

### 4. ping fails but curl works — the interesting one
This surprises people, but it is completely normal: **ICMP is frequently blocked while TCP is allowed.** Many cloud providers and corporate firewalls drop ICMP by default, and load balancers often do not respond to ping at all because the name resolves to a VIP that is not a host.

The real lesson is the inverse of #3: **`ping` failing proves nothing.** It is a weak signal in both directions. Use `nc -vz` or `curl` against the actual port instead.

**Fastest discriminator:** you already have the answer — the service works. Stop debugging.

### 5. Intermittent ~30% timeouts — the other interesting one
"Intermittent, and roughly a fixed fraction" is a fingerprint. It means **some of the endpoints behind a name or a load balancer are bad, and requests are being distributed across them.** 30% ≈ 1 of 3 backends.

Check: `dig NAME +short` — how many A records? If three, and one host is unhealthy, you get exactly this. Then test each address individually:

```bash
for ip in $(dig +short NAME); do
  echo -n "$ip: "; curl -s -o /dev/null -w '%{http_code} %{time_total}\n' --max-time 5 "http://$ip/" || echo FAIL
done
```

Other candidates: packet loss (`ping -c 100` and read the loss percentage; `mtr` to find the hop), or a load balancer with an unhealthy member and no health check.

**Fastest discriminator:** the loop above. It converts "intermittent" into "deterministic per backend", and intermittent problems are only hard until you find the axis they vary along.

### 6. Connects but hangs before data
The TCP handshake completed, so the network is fine and something is listening. The **application** accepted the connection and is not responding — blocked on a database, a deadlock, an exhausted thread pool, or waiting on a dependency that is itself hanging.

Check: `curl -v` (it prints "Connected to..." then stalls) → on the server, `ss -tn state established | wc -l` → thread/worker pool metrics → `journalctl -u SERVICE` → is the app's own dependency healthy?

**Fastest discriminator:** `curl -w '%{time_connect} %{time_starttransfer}\n'`. A fast `time_connect` with a huge `time_starttransfer` says unambiguously: the network is fine, the server is thinking.

### 7. Port open, no response
Same family as #6 but usually a protocol mismatch: something is listening, but not the thing you expect — an HTTPS service on a port you are speaking HTTP to, a proxy waiting for a protocol preamble, or the wrong service on a reused port.

Check: `curl -v` and read what comes back → `openssl s_client -connect host:port` if you suspect TLS → `ss -tlnp` on the server to see **which process** owns the port. That last one frequently reveals it is not the service you assumed.

---

## C4.1 — The diagnostic script

```bash
#!/usr/bin/env bash
set -uo pipefail          # note: NOT -e. We want to keep testing after a failure.

HOST=${1:?usage: netdiag.sh HOST PORT}
PORT=${2:?usage: netdiag.sh HOST PORT}

row() { printf '%-22s %-5s %s\n' "$1" "$2" "${3:-}"; }

# --- name resolution -------------------------------------------------------
if [[ $HOST =~ ^[0-9]+(\.[0-9]+){3}$ || $HOST == *:* ]]; then
  IP=$HOST
  row "NAME RESOLUTION" "SKIP" "already an IP address"
else
  # getent, not dig: this is the path the application will take.
  #
  # `getent hosts` on a dual-stack host lists the AAAA record first, and taking
  # the first line silently makes this an IPv6-only diagnostic. On a host with
  # no working IPv6 route that reports a bogus "layer 4 timeout" for a service
  # that is perfectly healthy over IPv4 - the tool diagnoses the wrong protocol
  # and you debug a firewall that was never involved. This was a real bug found
  # by running the script, not a hypothetical.
  #
  # `getent ahostsv4` asks specifically for IPv4. Support both, and SAY which
  # one you tested - a diagnostic that hides which protocol it used is worse
  # than no diagnostic.
  IP4=$(getent ahostsv4 "$HOST" 2>/dev/null | awk '{print $1; exit}')
  IP6=$(getent ahostsv6 "$HOST" 2>/dev/null | awk '/:/{print $1; exit}')
  IP=${FORCE_IP:-${IP4:-$IP6}}

  if [[ -z $IP ]]; then
    row "NAME RESOLUTION" "FAIL" "$HOST does not resolve"
    row "" "" "  -> check /etc/hosts, resolvectl status, dig @1.1.1.1 $HOST"
    exit 2
  fi

  src=$(grep -qE "[[:space:]]${HOST}(\$|[[:space:]])" /etc/hosts && echo "/etc/hosts" || echo "DNS")
  fam=$([[ $IP == *:* ]] && echo IPv6 || echo IPv4)
  row "NAME RESOLUTION" "OK" "$HOST -> $IP  ($fam, source: $src)"
  [[ -n $IP4 && -n $IP6 ]] && \
    row "" "" "  note: dual-stack. also has ${IP6}. Test it with FORCE_IP=$IP6"
fi

# --- layer 3: route --------------------------------------------------------
if route=$(ip route get "$IP" 2>/dev/null | head -1); then
  dev=$(sed -n 's/.*dev \([^ ]*\).*/\1/p' <<<"$route")
  src=$(sed -n 's/.*src \([^ ]*\).*/\1/p' <<<"$route")
  row "LAYER 3 (route)" "OK" "via ${dev}, src ${src}"
else
  row "LAYER 3 (route)" "FAIL" "no route to $IP"
  row "" "" "  -> check ip route, and your netmask"
  exit 3
fi

# --- layer 3: icmp ---------------------------------------------------------
ping_cmd=$([[ $IP == *:* ]] && echo ping6 || echo ping)
if ping_out=$($ping_cmd -c3 -W2 "$IP" 2>&1); then
  avg=$(awk -F'/' '/rtt|round-trip/ {print $5}' <<<"$ping_out")
  row "LAYER 3 (icmp)" "OK" "avg ${avg}ms"
else
  # NOT fatal - ICMP is commonly blocked while TCP works fine.
  row "LAYER 3 (icmp)" "WARN" "no ICMP reply (often blocked by policy - not conclusive)"
fi

# --- layer 4: tcp ----------------------------------------------------------
start=$(date +%s%N)
nc_err=$(nc -vz -w4 "$IP" "$PORT" 2>&1); nc_rc=$?
elapsed_ms=$(( ($(date +%s%N) - start) / 1000000 ))

if (( nc_rc == 0 )); then
  row "LAYER 4 (tcp/$PORT)" "OK" "connected in ${elapsed_ms}ms"
else
  # THE KEY BRANCH. There are THREE outcomes here, not two, and they send you
  # to three different places. Classify once, then report - an earlier version
  # of this script had only two branches, so an ICMP admin-prohibited fell into
  # the "else" and printed "TIMED OUT after 2ms ... packets are being DROPPED":
  # a self-contradicting verdict (2ms is not a timeout) pointing at the wrong
  # layer entirely.
  #
  #   refused    -> RST or ICMP port-unreachable. This host answered.
  #   prohibited -> ICMP admin-prohibited / host-unreachable (EHOSTUNREACH).
  #                 Something in the PATH answered. Fast, like a refusal.
  #   dropped    -> silence until the timeout expired.
  if grep -qi 'refused' <<<"$nc_err"; then
    outcome=refused
  elif grep -qiE 'no route to host|unreachable' <<<"$nc_err"; then
    outcome=prohibited
  else
    outcome=dropped
  fi

  case $outcome in
    refused)
      row "LAYER 4 (tcp/$PORT)" "FAIL" "connection REFUSED after ${elapsed_ms}ms"
      row "" "" "  -> the host is up and answered with RST. Routing and firewall are FINE."
      row "" "" "  -> nothing is listening on $PORT, or it is bound to 127.0.0.1."
      row "" "" "  -> next: on the server, ss -tlnp | grep $PORT"
      ;;
    prohibited)
      row "LAYER 4 (tcp/$PORT)" "FAIL" "HOST UNREACHABLE after ${elapsed_ms}ms"
      row "" "" "  -> ICMP admin-prohibited/host-unreachable: something in the PATH said no."
      row "" "" "  -> a router ACL, a cloud security group, or a firewall between us - not this"
      row "" "" "     host's service, and not a silent drop. Note how FAST it came back."
      row "" "" "  -> next: traceroute -T -p $PORT $IP; check security groups and router ACLs"
      ;;
    dropped)
      row "LAYER 4 (tcp/$PORT)" "FAIL" "TIMED OUT after ${elapsed_ms}ms"
      row "" "" "  -> no reply at all. Packets are being DROPPED silently."
      row "" "" "  -> next: on the server, nft list ruleset; tcpdump -i any -n port $PORT"
      row "" "" "  -> and on THIS host: nft list ruleset. tcpdump cannot show you an"
      row "" "" "     outbound packet your own output chain dropped."
      ;;
  esac
  row "LAYER 7 (http)" "SKIP" "(transport failed)"
  echo
  # "Refused", "prohibited" and "dropped" are three different verdicts owned by
  # three different people. Saying "blocked" for a refusal sends the next person
  # to the firewall, which is the wrong place.
  case $outcome in
    refused)
      echo "VERDICT: host reachable, NOTHING LISTENING on ${PORT}. Look at the service, not the network." ;;
    prohibited)
      echo "VERDICT: a firewall IN THE PATH rejected this. Look at network policy, not at the service." ;;
    dropped)
      echo "VERDICT: reachable at layer 3, packets DROPPED at layer 4. Look at filtering, or the return path." ;;
  esac
  exit 4
fi

# --- layer 7 ---------------------------------------------------------------
if out=$(curl -sS -o /dev/null -m5 -w '%{http_code} %{time_connect} %{time_starttransfer}' \
         "http://${HOST}:${PORT}/" 2>&1); then
  read -r code tconn tfirst <<<"$out"
  row "LAYER 7 (http)" "OK" "HTTP ${code}  connect=${tconn}s ttfb=${tfirst}s"
  echo; echo "VERDICT: fully working."
  exit 0
else
  row "LAYER 7 (http)" "FAIL" "$out"
  row "" "" "  -> TCP connects but HTTP does not complete: wrong protocol, or the app is hung."
  echo; echo "VERDICT: transport OK, application failing."
  exit 7
fi
```

**Design points to absorb:**
- `set -uo pipefail` **without `-e`** — a diagnostic tool must keep going after a failure. This is one of the few places where omitting `-e` is correct, and it is deliberate.
- The ICMP result is a `WARN`, never a `FAIL`. Treating ICMP as authoritative is the mistake this whole week is designed to cure.
- Each failure prints **what it implies and what to check next**. A tool that says "FAIL" and stops has moved the work, not done it.
- **Three layer-4 outcomes, not two.** The `prohibited` branch is the one people leave out, and leaving it out is worse than useless: an ICMP admin-prohibited reply lands in the `else`, and the tool confidently reports a "timeout" that arrived in 2ms and blames a silent drop. A diagnostic that is wrong is more expensive than no diagnostic, because someone will believe it.
- **`nc`, not `curl`, for the layer-4 test.** curl reports all three outcomes as `Failed to connect ... Couldn't connect to server`. It cannot make this distinction, so it cannot be the thing that makes it.

---

## C4.2 — Two subnets and a router

```bash
# On the router VM (call it 'gw'), which has interfaces on both segments:
sudo sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-router.conf

# alpha
sudo ip route add 192.168.60.0/24 via <GW_IP_ON_ALPHA_SEGMENT>
# beta
sudo ip route add 192.168.50.0/24 via <GW_IP_ON_BETA_SEGMENT>

# prove traffic traverses the router
# on gw:  sudo tcpdump -i any -n icmp
# on alpha: ping -c3 192.168.60.1
```

**If you add the route on `alpha` but forget it on `beta`:**

The ping *request* reaches beta successfully — alpha knows how to get there. Beta receives it, tries to reply to `192.168.50.1`, has no route for that network, and sends the reply to its **default gateway** instead, where it is dropped or discarded.

The symptom from alpha is a **100% timeout**, indistinguishable at first glance from "beta is down". But `tcpdump` on **beta** shows the ICMP echo requests arriving perfectly.

**This is the single most valuable thing in this challenge: a one-way route failure looks exactly like a total failure from the client, and only a capture on the far end reveals it.** Real-world versions of this include asymmetric routing, missing return routes in VPNs, and security groups that allow inbound but not outbound.

---

## C4.3 — DNS forensics

```bash
dig github.com A +noall +answer          # 1. A records with TTLs
dig github.com NS +short                 # 2. authoritative nameservers
dig github.com CNAME +short              # 3. CNAME (empty = none at the apex)
dig +trace github.com                    # 4. delegation from the root
dig -x $(dig +short github.com | head -1) +short   # 5. reverse
```

**5.** The reverse lookup usually does *not* match — large services use shared infrastructure and the PTR record points at the provider's naming. Forward and reverse DNS agreeing is a convention, not a requirement, and mail servers are one of the few places it is actually enforced.

**6. How long a change takes to reach everyone.** The naive answer is "the TTL". The real answer is **longer, and unbounded in the tail**, because:

- Resolvers begin their countdown when *they* cached the record, so the worst case is TTL after your change, not from your change.
- Some resolvers ignore low TTLs and impose a floor (commonly 30–300s).
- Browsers and JVMs cache independently of the OS — the JVM historically cached DNS **forever** by default, which has caused real, memorable outages.
- Applications that resolve once at startup and hold the address never see the change at all until they restart. This is the big one, and it is why "we updated DNS an hour ago, why is traffic still hitting the old server?" is a question with a depressing answer.

**Operational rule:** lower the TTL to 60s at least 24h (one full old-TTL period) *before* a planned migration, and keep the old endpoint alive well past the TTL — days, not minutes.

---

## C4.5 — Bind on purpose

| Mechanism | How | Advantage | Its unique failure mode |
|---|---|---|---|
| **(a) Bind address** | listen on `127.0.0.1` + an SSH tunnel from alpha, or bind to a specific interface IP | Simplest; nothing can reach it, even if the firewall is flushed | All-or-nothing per interface. Cannot express "alpha yes, gamma no" on the same subnet. And it is invisible to anyone reading firewall config — they will conclude the port is open |
| **(b) Firewall rule** | `ufw allow from <ALPHA_IP> to any port 8080` | Expressive: per-source, per-port, logged, changeable without restarting the service | Fails **open** if the ruleset is flushed, reset, or reordered — and Docker famously inserts its own rules that bypass ufw entirely (Week 7). Source IPs are also spoofable on an untrusted network |
| **(c) Application layer** | mTLS, an API token, or an allowlist in the app config | Survives network changes; authenticates the *caller*, not the *location*; the only one that works across NAT and proxies | Depends on the application being correct. A bug in your auth code is an open door, and the service still accepts and processes the connection before rejecting it — so it is still a DoS surface |

**What you would actually use: all three, layered.** Bind to a private interface, restrict by firewall, and authenticate at the application. Each covers the others' failure modes: (a) survives a firewall flush, (b) survives a bind-address misconfiguration, (c) survives someone on the trusted network. This is **defence in depth**, and being able to explain *why* each layer is not redundant is exactly what the concept means.
