# Week 04 — Networking Fundamentals

**VM profile:** `make w04-up` → two VMs, `alpha` and `beta`
**You will be able to:** answer "why can't this machine reach that port?" by evidence, at every layer, in under five minutes.

> This is the week that separates people who can operate systems from people who can only start them. Almost every production incident is, at some level, a networking question: something cannot reach something else, or reaches it too slowly.

---

## Day 1 — Layers, addresses, and the path a packet takes

### 1.1 The layer model, used as a debugging tool

Forget memorising seven OSI layers. Use these five, because they map onto commands you actually run:

| # | Layer | Unit | Address | Ask | Tool |
|---|---|---|---|---|---|
| 5 | Application | message | URL | Does the app respond correctly? | `curl -v` |
| 4 | Transport | segment | **port** | Is the port open? Refused or timed out? | `ss`, `nc` |
| 3 | Network | packet | **IP** | Is there a route? Does it reply to ping? | `ip route`, `ping` |
| 2 | Link | frame | MAC | Is the neighbour reachable on this segment? | `ip neigh`, `arp` |
| 1 | Physical | bits | — | Is the interface up? | `ip link` |

**The method:** when something cannot connect, walk *up* from layer 1 and prove each layer before moving on. Most people start at layer 5, get a confusing error, and guess. Walking up takes four minutes and is never wrong.

Also memorise this shortcut, which resolves half of all cases immediately:

> **Connection refused** = the packet arrived, and the host actively said "nothing is listening here" (a TCP RST). Routing and firewall are FINE. The problem is the service.
>
> **Connection timed out** = no answer at all. The packet was dropped somewhere — a firewall, a wrong route, a dead host. The service may be perfectly healthy.

Getting these two backwards sends you down the wrong path for an hour. `nc -vz host port` tells you which one you have.

### 1.2 Addresses and subnets

An IPv4 address is 32 bits, written as four bytes. A **CIDR prefix** says how many leading bits identify the *network*:

```
10.0.5.23/24     network 10.0.5.0     hosts .1 - .254     broadcast 10.0.5.255
10.0.5.23/16     network 10.0.0.0     hosts .0.1 - .255.254
10.0.5.23/32     just this one address
```

| Prefix | Addresses | Usable hosts |
|---|---|---|
| /24 | 256 | 254 |
| /25 | 128 | 126 |
| /26 | 64 | 62 |
| /30 | 4 | 2 (point-to-point links) |

**Why this matters operationally:** two machines on the same subnet talk **directly** (layer 2, via ARP). Machines on different subnets must go through a **router**. If you misconfigure a netmask, a machine believes a peer is local, ARPs for it, gets no answer, and the connection times out — with a perfectly correct-looking IP address and default route.

**Private ranges** (RFC 1918), which never appear on the public internet: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`. Multipass uses one of these. Also worth knowing: `127.0.0.0/8` loopback, `169.254.0.0/16` link-local (an address in this range means **DHCP failed**), and `0.0.0.0` which means "all addresses" when binding.

### 1.3 The routing table

```bash
ip route
# default via 10.223.1.1 dev ens3 proto dhcp src 10.223.1.42 metric 100
# 10.223.1.0/24 dev ens3 proto kernel scope link src 10.223.1.42
```

Read it as a decision procedure. For each outgoing packet the kernel picks the route with the **longest matching prefix**; `default` (`0.0.0.0/0`) matches everything and therefore always loses to anything more specific. Ask the kernel directly rather than reasoning about it:

```bash
ip route get 8.8.8.8          # which route, which interface, which source IP
ip route get 10.223.1.99
```

`ip route get` is enormously underused and answers "where would this packet go?" definitively.

### 1.4 ARP: how layer 3 becomes layer 2

To send to a local IP, the kernel needs the peer's MAC address. It broadcasts "who has 10.0.5.7?" and caches the answer:

```bash
ip neigh
```

States you will see: `REACHABLE`, `STALE` (cached but unverified — normal), **`FAILED`** (no answer — the host is off, or you are wrong about it being on this subnet), `INCOMPLETE` (asking now).

A `FAILED` neighbour entry for a machine you believe is local is a strong signal that your netmask is wrong.

---

## Day 2 — Ports, sockets, and binding

### 2.1 What a socket actually is

A TCP connection is identified by a **four-tuple**: `(source IP, source port, destination IP, destination port)`. That is why one server port can serve thousands of clients — each connection differs in the client's IP/port.

Ports 0–1023 are **privileged**: binding them traditionally requires root. This is why web servers start as root and drop privileges, and why containers often serve on 8080 internally and are published on 80 externally.

### 2.2 Binding — the single most common configuration bug

```bash
ss -tlnp
# State  Local Address:Port
# LISTEN 127.0.0.1:5432       ← ONLY reachable from this machine
# LISTEN 0.0.0.0:80           ← reachable from anywhere that can route here
# LISTEN [::]:22              ← all IPv6 addresses
```

`0.0.0.0` is not an address; it is a wildcard meaning "every IPv4 address on this host". `127.0.0.1` means loopback only.

> **The bug:** a service is running, the port is listening, the firewall is open, and the connection still times out from another machine — because the process is bound to `127.0.0.1`. `ss -tlnp` on the *server* is the only thing that shows this, and it is the first command to run when a remote connection fails but a local one succeeds. Drill 04 includes this fault.

Learn these `ss` invocations:

```bash
ss -tlnp          # TCP, Listening, Numeric, with Process   ← the one to memorise
ss -tunap         # TCP+UDP, All states, Numeric, Process
ss -tn state established
ss -tn '( dport = :443 or sport = :443 )'
ss -s             # summary counts by state
```

`-n` matters: without it, `ss` resolves every address via DNS, which is slow and — when DNS is the thing that is broken — hangs.

### 2.3 TCP states you will actually see

```
Client                          Server
  |------ SYN ------------------>|
  |<----- SYN-ACK ---------------|      three-way handshake
  |------ ACK ------------------>|
        ESTABLISHED
  |------ FIN ------------------>|
  |<----- ACK -------------------|
  |<----- FIN -------------------|
  |------ ACK ------------------>|      TIME_WAIT for 2*MSL (60s on Linux)
```

| State | Means | Concerning when |
|---|---|---|
| `LISTEN` | accepting connections | — |
| `ESTABLISHED` | in use | count grows without bound → a leak |
| `TIME_WAIT` | recently closed, waiting for stray packets | thousands → high connection churn; consider keep-alive |
| `CLOSE_WAIT` | **the remote closed; your app has not** | **any significant number is an application bug** — it is not closing its sockets |
| `SYN-SENT` | handshake unanswered | a firewall is dropping, or the host is gone |

`CLOSE_WAIT` piling up is worth memorising: it is unambiguously a bug in the local application, and it eventually exhausts file descriptors.

---

## Day 3 — DNS, and the resolution path

### 3.1 What actually happens

```
getaddrinfo("api.example.com")
   ↓
/etc/nsswitch.conf  →  "hosts: files dns"    ← the ORDER is here
   ↓
1. /etc/hosts                                 ← static overrides win
2. the resolver in /etc/resolv.conf
   ↓
On Ubuntu, /etc/resolv.conf usually points at 127.0.0.53
   = systemd-resolved, a local stub resolver
   ↓
systemd-resolved forwards to the real upstream servers
   (see: resolvectl status)
   ↓
recursive lookup: root → .com → example.com → answer, cached by TTL
```

**Two consequences that bite people:**

1. **`dig` bypasses this whole path.** `dig api.example.com` queries a DNS server directly; it does *not* read `/etc/hosts` or `nsswitch.conf`. So `dig` can succeed while your application fails, or vice versa. To test what an application will actually see, use `getent hosts name` — that goes through NSS exactly like `getaddrinfo`.

2. **`/etc/resolv.conf` is usually a symlink managed by systemd-resolved.** Editing it directly appears to work and is silently reverted. Use `resolvectl` or netplan.

```bash
getent hosts api.example.com      # what the application will get
resolvectl status                 # which upstream servers, per interface
resolvectl query api.example.com  # with cache and DNSSEC detail
dig api.example.com               # direct query - shows TTL, authority, timing
dig +trace api.example.com        # follow the delegation from the root
dig @1.1.1.1 api.example.com      # bypass the local resolver entirely
resolvectl flush-caches
```

### 3.2 DNS record types you need

| Type | Maps to | Note |
|---|---|---|
| `A` | IPv4 address | |
| `AAAA` | IPv6 address | a host with both may prefer IPv6 and fail differently |
| `CNAME` | another name | cannot coexist with other records at the same name |
| `MX` | mail servers | |
| `TXT` | arbitrary text | SPF, domain verification |
| `SRV` | service host+port | how Swarm/Consul-style discovery works |
| `PTR` | reverse: IP → name | separate zone; frequently missing |

**TTL is why DNS changes are not instant.** A record with `TTL 3600` may be cached by resolvers you do not control for an hour after you change it. Before a planned migration, lower the TTL a day in advance. Discovering this during a cutover is a classic and entirely avoidable incident.

---

## Day 4 — Firewalls and packet capture

### 4.1 nftables (and ufw, which is a front end to it)

Modern Ubuntu uses **nftables**. `iptables` commands are translated to it. `ufw` is a simplified front end.

```bash
sudo nft list ruleset             # the truth, whatever created it
sudo ufw status verbose
sudo ufw allow 8080/tcp
sudo ufw allow from 10.0.0.0/8 to any port 5432 proto tcp
sudo ufw delete allow 8080/tcp
```

Traffic traverses **chains** at **hooks**: `input` (to this host), `output` (from this host), `forward` (through this host), plus `prerouting`/`postrouting` for NAT. Each chain has a **policy** (default action) and a list of rules evaluated in order; **the first match wins**.

> **A firewall that DROPs produces timeouts; one that REJECTs produces "connection refused".** DROP is preferred externally because it gives a scanner no information — and it is also why external timeouts are so confusing to debug. Knowing your own firewall's policy tells you how to interpret the symptom.

### 4.2 NAT, briefly

Your Multipass VMs share the host's IP for outbound traffic. The host rewrites the source address and remembers the mapping, so replies can be sent back. Consequences: **outbound works, inbound does not**, unless a port is explicitly forwarded. This is exactly the model of Docker's default bridge network in Week 7 — learning it here makes that week much easier.

### 4.3 tcpdump — seeing the packets

When logs disagree with each other, packets are the ground truth.

```bash
sudo tcpdump -i any -n port 8080
sudo tcpdump -i any -n host 10.0.5.7 and port 443
sudo tcpdump -i any -n 'tcp[tcpflags] & tcp-syn != 0'    # handshake attempts only
sudo tcpdump -i any -n -c 20 -A port 80                  # print payload as ASCII
sudo tcpdump -i any -n -w /tmp/cap.pcap port 8080        # save for Wireshark
```

`-n` prevents DNS lookups (essential — otherwise tcpdump generates the very traffic you are trying to observe). `-i any` captures on all interfaces.

**What to look for:**
- You see `SYN` leaving, nothing coming back → dropped somewhere outbound, or the peer is not there.
- You see `SYN` arriving and `RST` leaving → your host received it and refused: **nothing is listening**, or a REJECT rule.
- Nothing arrives at all on the server → it never got there; the problem is between you and it.

That three-way distinction — *did the packet arrive?* — is exactly what neither side's logs can tell you, and it is why tcpdump is the arbiter.

### 4.4 The complete diagnostic sequence

Run this top to bottom whenever "X cannot reach Y". Do not skip steps because one "must be fine".

```bash
# On the CLIENT
ip -brief address                       # 1. do I have an address? (169.254.x = DHCP failed)
ip route get <TARGET_IP>                # 2. is there a route, and via which interface?
getent hosts <TARGET_NAME>              # 3. does the name resolve, and to what?
ping -c3 <TARGET_IP>                    # 4. layer 3 reachability (may be blocked by policy)
nc -vz -w3 <TARGET_IP> <PORT>           # 5. REFUSED vs TIMEOUT - the key branch
curl -v --max-time 5 http://<T>:<PORT>/ # 6. does the application answer?

# On the SERVER
ss -tlnp | grep <PORT>                  # 7. listening? on 0.0.0.0 or on 127.0.0.1?
sudo nft list ruleset                   # 8. is a rule dropping it?
sudo tcpdump -i any -n port <PORT>      # 9. do the packets even arrive?
journalctl -u <SERVICE> -n 50           # 10. what does the app say?
```

Memorise the shape of it. In an interview, walking through this list out loud is the single most convincing thing a junior platform engineer can do.

---

## Day 5 — Drill

```bash
cd infra
make snapshot VM=alpha NAME=pre-w04
make break VM=alpha DRILL=04-network
```

Symptom: *"From alpha I can ping beta's IP address just fine, so the network is obviously up. But curl http://beta:8080 just hangs and eventually times out. ping beta by name gets nothing either - I assume ICMP is filtered for hostnames or something. Can someone open port 8080 on the firewall?"*

There are **three** layered faults. Find all three. The first one you fix will not make it work, and that is the lesson.

## Recommended reading

- *Computer Networking: A Top-Down Approach* — chapters 1–3 (many universities host free copies)
- Julia Evans, *How DNS Works* and *Networking Zines* — <https://jvns.ca/>
- <https://www.brendangregg.com/linuxperf.html> — the network sections
- `man 8 ip`, `man 8 ss`, `man 8 tcpdump`
- <https://danielmiessler.com/study/tcpdump/> — a practical tcpdump primer
