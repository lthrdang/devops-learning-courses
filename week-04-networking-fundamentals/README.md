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

Also memorise this shortcut, which resolves half of all cases immediately. There are **three** outcomes, not two:

> **Connection refused** = the packet arrived, and the host actively said "nothing is listening here" (a TCP RST, or an ICMP port-unreachable). Routing and firewall are FINE. The problem is the service.
>
> **Connection timed out** = no answer at all. The packet was silently dropped somewhere — a firewall, a wrong route, a dead host. The service may be perfectly healthy.
>
> **No route to host** = something in the path *answered*, with ICMP type 3 "administratively prohibited" or "host unreachable". Fast like a refusal, but it means a **firewall in the path said no** — a router ACL, a cloud security group, a corporate edge. The kernel reports it to the application as `EHOSTUNREACH`.

The third is the one people have never been taught, and it is the one that cloud infrastructure actually sends. Measured against nftables on Ubuntu 24.04:

| What the far end does | What you see |
|---|---|
| nothing listening, no firewall | Connection refused |
| `reject` (no arguments) | Connection refused |
| `reject with tcp reset` | Connection refused |
| `reject with icmp type admin-prohibited` | No route to host |
| `reject with icmp type host-unreachable` | No route to host |
| `drop` | *nothing at all — you time out* |

Getting these backwards sends you down the wrong path for an hour: "refused" sends you to the service, "no route to host" sends you to whoever owns the path, "timed out" sends you hunting for a silent drop.

`nc -vz host port` tells you which one you have. **`curl` does not.** Every one of the first five rows above comes back from curl as the same sentence — `Failed to connect to <host> port <n> after <x> ms: Couldn't connect to server` — refusal and admin-prohibited alike. So "curl says it can't connect" is a symptom, never a diagnosis. Test layer 4 with `nc`, *then* reach for `curl`.

### 1.2 Addresses and subnets

An IPv4 address is 32 bits, written as four bytes. A **CIDR prefix** says how many leading bits identify the *network*:

```
10.0.5.23/24     network 10.0.5.0     hosts .1 - .254     broadcast 10.0.5.255
10.0.5.23/16     network 10.0.0.0     hosts .0.1 - .255.254
10.0.5.23/32     just this one address
```

| Prefix | Addresses | Usable hosts | Where you meet it |
|---|---|---|---|
| /24 | 256 | 254 | the default subnet everywhere |
| /25 | 128 | 126 | a /24 split in half |
| /26 | 64 | 62 | typical cloud subnet per availability zone |
| /30 | 4 | 2 | the old way to number a link between two routers |
| /31 | 2 | 2 | the modern way to do it (RFC 3021) |
| /32 | 1 | 1 | a single host: a VIP, a loopback alias, one firewall rule |

A `/30` spends four addresses to connect two devices, because it reserves a network address and a broadcast address that a two-node link has no use for. RFC 3021 defines the **`/31`**, where both addresses are simply the two ends — that is what routers actually configure on point-to-point links today, and it is what you will see in a cloud transit or VPN config. A `/32` has no room for anything but itself, which is exactly why it is the right way to say "this one host and nothing else".

**Why this matters operationally:** two machines on the same subnet talk **directly** (layer 2, via ARP). Machines on different subnets must go through a **router**. If you misconfigure a netmask, a machine believes a peer is local, ARPs for it, gets no answer, and the connection times out — with a perfectly correct-looking IP address and default route.

**Private ranges** (RFC 1918), which never appear on the public internet: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`. Multipass uses one of these. Also worth knowing: `127.0.0.0/8` loopback, and `0.0.0.0`, which is not an address at all but means "all addresses" when binding.

`169.254.0.0/16` is link-local, and you have to read it twice depending on where it appears:

- **As an address on your interface** (`ip -brief address` shows `169.254.x.y`) it means the host self-assigned one because **DHCP failed** (RFC 3927). This machine has no usable network configuration.
- **As a destination you are talking to**, the overwhelmingly common one in DevOps is **`169.254.169.254`** — the instance metadata endpoint on AWS, GCP, Azure and most others. Traffic to it on a healthy cloud VM is completely normal, and it is where instance credentials, user-data and instance identity come from. Seeing it in a `tcpdump` or a routing table is not a fault.

One is a broken interface; the other is a working cloud. Do not pattern-match on `169.254` alone.

### 1.3 The routing table

```bash
ip route
# default via 10.223.1.1 dev ens3 proto dhcp src 10.223.1.42 metric 100
# 10.223.1.0/24 dev ens3 proto kernel scope link src 10.223.1.42
```

Every field in those two lines is load-bearing (`man 8 ip-route` has the full set):

| Field | Means |
|---|---|
| `default` | shorthand for `0.0.0.0/0` — matches every destination, which is why it always loses to anything more specific |
| `10.223.1.0/24` | the destination prefix this route covers |
| `via 10.223.1.1` | hand the packet to this **next-hop router**. A route with no `via` needs no router at all |
| `dev ens3` | send the frame out of this interface |
| `proto dhcp` | who put this route here: the DHCP client did. It will come back after a reboot or a lease renewal, and it will overwrite what you added by hand |
| `proto kernel` | the kernel installed this one itself, automatically, the moment an address was configured on the interface. You get one free with every address |
| `scope link` | the destination is **directly reachable on this segment** — no router involved. Find the peer's MAC with ARP and put the frame on the wire |
| `src 10.223.1.42` | the source address to stamp on packets taking this route. This is what the far end will see, and what your peer's firewall rules have to allow |
| `metric 100` | the tie-break. Among routes with the same prefix length, **lowest metric wins**. This is how a laptop on Wi-Fi and Ethernet at once prefers Ethernet, and how a VPN takes over the default route without deleting anything |

**`scope link` is the one to internalise**, because it is the kernel writing down "these addresses are my neighbours" — the exact concept §1.2 and §1.4 are built on. Its prefix comes straight from your netmask, so a wrong netmask corrupts *this line*: the `scope link` prefix becomes too wide, the kernel decides some host on the far side of a router is a neighbour, ARPs for it (§1.4), gets silence, and the connection times out — with a perfectly correct-looking address and default route.

Read the table as a decision procedure. For each outgoing packet the kernel picks the route with the **longest matching prefix**; `default` matches everything and therefore always loses to anything more specific. Ask the kernel directly rather than reasoning about it:

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
# LISTEN 0.0.0.0:80           ← every IPv4 address on this host
# LISTEN *:8080               ← every address, IPv4 AND IPv6 — one dual-stack socket
# LISTEN [::]:22              ← IPv6 only. This socket will NOT take IPv4
```

`0.0.0.0` is not an address; it is a wildcard meaning "every IPv4 address on this host". `127.0.0.1` means loopback only.

> **The bug:** a service is running, the port is listening, the firewall is open, and the connection still times out from another machine — because the process is bound to `127.0.0.1`. `ss -tlnp` on the *server* is the only thing that shows this, and it is the first command to run when a remote connection fails but a local one succeeds. Drill 04 includes this fault.

**Now the last two lines**, which are where almost everyone goes wrong. Linux ships `net.ipv6.bindv6only=0`, so a socket bound to `::` is **dual-stack by default**: it accepts IPv4 connections too, and reports the peer as an IPv4-mapped address like `::ffff:10.0.5.7`. An application can opt out per socket with the `IPV6_V6ONLY` option — and `ss` shows you which one it chose:

| `ss` prints | The socket is | An IPv4 client gets |
|---|---|---|
| `*:8080` | an IPv6 wildcard with `IPV6_V6ONLY` **off** — one socket serving both families | served |
| `[::]:8080` | an IPv6 wildcard with `IPV6_V6ONLY` **on** | connection refused |

> **The trap runs in both directions.** "It only shows `*:8080`, so IPv6 must be broken" is wrong — that socket is carrying your IPv4 traffic right now. And "`::` is dual-stack, so one `listen` line is enough" is wrong for the most common web server on earth: **nginx** sets the option, so `listen [::]:80;` defaults to `ipv6only=on` and you genuinely do need both `listen 80;` and `listen [::]:80;`. The kernel default and the application's choice are two different things. Read the `ss` output — it is the only place both are already resolved.

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
  |------ FIN ------------------>|      ← whoever sends the FIRST FIN performs the
  |<----- ACK -------------------|        ACTIVE CLOSE. Here, that is the client.
  |<----- FIN -------------------|
  |------ ACK ------------------>|      the active closer — and only it — now sits
                                        in TIME_WAIT (60s on Linux)
```

| State | Means | Concerning when |
|---|---|---|
| `LISTEN` | accepting connections | — |
| `ESTABLISHED` | in use | count grows without bound → a leak |
| `TIME_WAIT` | **this side closed first** and is holding the four-tuple so stray packets cannot land in a new connection | *not* by the raw count. Thousands spread across many peers is harmless. The failure is **ephemeral-port exhaustion against a single destination**: you have ~28k ports (`net.ipv4.ip_local_port_range`) for one `(dst IP, dst port)` pair, and past that `connect()` returns `EADDRNOTAVAIL` |
| `CLOSE_WAIT` | **the remote closed; your app has not** | **any significant number is an application bug** — it is not closing its sockets |
| `SYN-SENT` | handshake unanswered | a firewall is dropping, or the host is gone |

`CLOSE_WAIT` piling up is worth memorising: it is unambiguously a bug in the local application, and it eventually exhausts file descriptors.

**`TIME_WAIT` belongs to whoever hangs up first — not to the client.** That single rule is worth more than every piece of tuning advice you will ever read about it. The side that sends the first `FIN` performs the *active close*, sends the final `ACK`, and must then hold the four-tuple: it cannot know its `ACK` arrived, and a delayed duplicate from the old connection must never be delivered to a new connection reusing the same four-tuple. RFC 9293 §3.6.1 makes it a **MUST**: *"When a connection is closed actively, it MUST linger in the TIME-WAIT state for a time 2xMSL"* — actively, meaning the side that closed first.

The diagram shows the client closing because that is what a browser does. Plenty of servers do the opposite — and one of them is in this week's lab. `python3 -m http.server` speaks HTTP/1.0 and closes after every single response, so **the `TIME_WAIT`s pile up on the server**. Twenty `curl`s, twenty `TIME_WAIT` sockets, every one of them with the server's port as its *local* address. Lab §2.3 makes you count on both machines and find out.

> **Turn it into a diagnostic:** *"which side has the `TIME_WAIT`s?"* answers *"who is hanging up?"* — for free, on a live system, with no instrumentation. A load balancer full of `TIME_WAIT` toward a backend is a load balancer that is not reusing connections. A database server full of them means your connection pool is not pooling.

**How long — and what you cannot change about it.** The spec says 2×MSL, and RFC 9293 §3.4.2 takes MSL to be 2 minutes — so, by the book, **4 minutes**. Linux does not compute that. It hardcodes `TCP_TIMEWAIT_LEN` at **60 seconds** in the kernel source, and **there is no sysctl to change it**. Every "fix" you will find for `TIME_WAIT` is aimed at a knob that does something else:

| The advice | What is actually true |
|---|---|
| "lower `net.ipv4.tcp_fin_timeout`" | It does not touch `TIME_WAIT`. It bounds **`FIN_WAIT_2`** — an orphaned connection waiting for the *peer's* `FIN`. Different state, different failure, different fix. |
| "set `net.ipv4.tcp_tw_recycle=1`" | That knob dropped connections from any client behind NAT, and it has been **removed from the kernel**. On Ubuntu 24.04 the sysctl does not exist — `sysctl net.ipv4.tcp_tw_recycle` errors out. Anything still recommending it was written for a kernel you are not running. |
| "`net.ipv4.tcp_tw_reuse` is dangerous" | It is the *supported* knob, and it is **client-side only**: it lets a new **outbound** `connect()` reuse a `TIME_WAIT` slot. It does nothing whatsoever for a server's inbound `TIME_WAIT`s. Ubuntu defaults it to `2`, meaning loopback traffic only. |

> **The real fix is almost never a sysctl — it is keep-alive.** `TIME_WAIT` is the price of tearing a connection down, so stop tearing it down. HTTP keep-alive, a real connection pool, `Connection: keep-alive` surviving your proxy — and the churn disappears at its source instead of being papered over in `/etc/sysctl.d`.

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

### 4.1 nftables (and where ufw actually lives)

Modern Ubuntu filters packets with **nftables** in the kernel. `iptables` still exists as a command, but on 24.04 `/usr/sbin/iptables` is a symlink to `xtables-nft-multi` — a compatibility layer that accepts the old syntax and writes into the new subsystem.

`ufw` is a simplified front end, and it is worth knowing precisely what it is a front end *to*, because this week's lab has you add your own nft table right next to ufw's. On 24.04, ufw 0.36.2 has exactly one backend — `backend_iptables.py` — and it works by generating **`iptables-restore`** input. So ufw's rules do end up in the nftables subsystem, and they **do** appear in `nft list ruleset`. But they arrive there through the compat layer: they live in `ip filter` / `ip6 filter` tables, in `ufw-*` chains, and they are not written as native nft rules.

Two consequences that cost people real time:

- **`nft flush ruleset` silently wipes ufw's entire policy.** `ufw status` will still cheerfully say `Status: active`. The host is now unfiltered and nothing tells you.
- **Anything you change with `nft` inside ufw's chains is lost on `ufw reload`**, because ufw regenerates the whole ruleset from `/etc/ufw/*.rules`. Manage ufw's rules with `ufw`; put your own rules in your own table, and expect both to be in the ruleset at once.

```bash
sudo nft list ruleset             # the truth, whatever created it
sudo ufw status verbose
sudo ufw allow 8080/tcp
sudo ufw allow from 10.0.0.0/8 to any port 5432 proto tcp
sudo ufw delete allow 8080/tcp
```

Traffic traverses **chains** attached to **hooks**: `input` (to this host), `output` (from this host), `forward` (through this host), plus `prerouting`/`postrouting` for NAT. Each base chain has a **policy** — what happens if no rule decides — and a list of rules evaluated in order.

"**The first match wins**" is how *iptables* works. nftables is different in two ways, and both of them bite in exactly the situation the lab puts you in — your table sitting alongside ufw's:

- **Matching is not deciding.** A rule whose statement is *non-terminal* — `counter`, `log`, `meta mark set` — matches, does its job, and then falls through to the next rule. Only `accept`, `drop`, `reject`, `queue` and `return` end evaluation. A `log` rule that "matched your packet" has decided nothing at all.
- **`accept` ends the chain, not the packet's journey.** It terminates *that base chain only*. Every other base chain registered on the same hook — in every other table, including ufw's — still runs, and any one of them can still `drop`. Chains run in `priority` order, lowest first; the lab's `priority 0` ties with ufw's filter chains, so "I added an accept rule and it still doesn't work" is the expected result, not a mystery.

Which is why `nft list ruleset` means *the whole ruleset*. Read all of the tables, not the first one that mentions your port.

> **DROP produces a timeout. REJECT produces an immediate error — but *which* error depends on what the reject sends.** A TCP RST or an ICMP port-unreachable gives "connection refused", indistinguishable from nothing listening. An ICMP admin-prohibited gives "no route to host", which is the honest answer and tells the caller that a policy blocked them. DROP is preferred at an internet edge because it gives a scanner nothing back — and it is also why external timeouts are so confusing to debug.
>
> `ufw` makes this choice for you and never mentions it: **`ufw deny` DROPs, and `ufw reject` on TCP emits `-j REJECT --reject-with tcp-reset`** — a plain RST. So a `ufw reject`ed port looks exactly like a port with no service behind it, and ufw is the one flavour that never sends the admin-prohibited that would have said "a firewall did this". Knowing your own firewall's dialect tells you how to read the symptom.

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
- **Nothing leaves at all**, even though the process definitely tried → the packet was killed by **your own `output` rule**. On the transmit path the capture tap runs *after* netfilter, so a locally-dropped packet is never captured — you see **zero** packets, not an unanswered `SYN`. Check your own `output` chain and put a `counter` on the suspect rule.
- You see `SYN` leaving, nothing coming back → it did get out of this host. It is being dropped in the path, or the peer is not there.
- You see `SYN` arriving and `RST` leaving → your host received it and refused: **nothing is listening**, or a REJECT rule.
- Nothing arrives at all on the server → it never got there; the problem is between you and it.

> **The asymmetry is the whole tool.** On *receive*, the tap runs **before** netfilter, so packets your `input` rule drops **are** captured — that is precisely what lets you say "it arrived and *we* dropped it", the most valuable sentence anyone can produce in a firewall argument. On *transmit* it is the other way round, so tcpdump can never show you your own outbound drop. Drill 04's first fault is an `output` rule, so this is not hypothetical: if tcpdump shows nothing leaving, do not conclude "the application isn't trying" — check your own OUTPUT chain first.

That four-way distinction — *did the packet even leave, and did it arrive?* — is exactly what neither side's logs can tell you, and it is why tcpdump is the arbiter.

### 4.4 The complete diagnostic sequence

Run this top to bottom whenever "X cannot reach Y". Do not skip steps because one "must be fine".

```bash
# On the CLIENT
ip -brief address                       # 1. do I have an address? (169.254.x = DHCP failed)
ip route get <TARGET_IP>                # 2. is there a route, and via which interface?
getent hosts <TARGET_NAME>              # 3. does the name resolve, and to what?
ping -c3 <TARGET_IP>                    # 4. layer 3 reachability (may be blocked by policy)
nc -vz -w3 <TARGET_IP> <PORT>           # 5. REFUSED vs NO ROUTE TO HOST vs TIMEOUT
sudo nft list ruleset                   # 6. YOUR OWN output chain. A local outbound drop
                                        #    shows ZERO packets in tcpdump, so the rules
                                        #    are the only evidence. (Drill 04, fault 1.)
curl -v --max-time 5 http://<T>:<PORT>/ # 7. does the application answer? (curl cannot
                                        #    tell step 5's three outcomes apart - do 5 first)

# On the SERVER
ss -tlnp | grep <PORT>                  # 8. listening? on 0.0.0.0 or on 127.0.0.1?
sudo nft list ruleset                   # 9. is a rule dropping it on this end?
sudo tcpdump -i any -n port <PORT>      # 10. do the packets even arrive? (on RX, a packet
                                        #     an input rule drops IS still captured)
journalctl -u <SERVICE> -n 50           # 11. what does the app say?
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
- `man 8 ip`, `man 8 ip-route`, `man 8 ss`, `man 8 tcpdump`, `man 7 ipv6`
- RFC 9293 (TCP) §3.3.2, §3.4.2 and §3.6.1 — the actual definition of `TIME_WAIT`, MSL, and the 2×MSL linger
- <https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt> — what the TCP sysctls really do
- <https://wiki.nftables.org/wiki-nftables/index.php/Configuring_chains> — priorities, hooks, and why "first match wins" is not the rule
- <https://danielmiessler.com/study/tcpdump/> — a practical tcpdump primer
