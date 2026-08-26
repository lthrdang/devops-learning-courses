# Week 04 — Lab

```bash
cd infra && make w04-up
./scripts/lab-up.sh hosts alpha beta
```

You will need **two terminals**, one on each VM. Get used to that now.

```bash
# terminal 1
multipass shell alpha
# terminal 2
multipass shell beta
```

---

## Part 1 — Where am I on the network? (Day 1)

On **both** VMs:

```bash
ip -brief address
ip -brief link
ip route
hostname -I
```

Record for each machine: interface name, IPv4 address, prefix length, default gateway.

```bash
# 1.1 Ask the kernel where a packet would go
ip route get 8.8.8.8
ip route get <BETA_IP>
ip route get 127.0.0.1
```

> Compare the `dev` and `src` in each answer. Explain in your logbook why the source address differs between the first and third.

### 1.2 Subnet arithmetic — do these by hand first

For `10.223.1.42/24`:
- network address? broadcast? first and last usable host? how many usable hosts?

For `172.20.8.100/22`:
- network address? broadcast? is `172.20.11.5` on the same subnet? is `172.20.12.5`?

Then check yourself:

```bash
sudo apt-get install -y ipcalc
ipcalc 10.223.1.42/24
ipcalc 172.20.8.100/22
```

### 1.3 ARP — layer 2 in action

On `alpha`:

```bash
ip neigh                       # what does it already know?
ip neigh flush all
ip neigh                       # now empty
ping -c1 <BETA_IP>
ip neigh                       # beta's MAC appeared - this is ARP working
ping -c1 8.8.8.8
ip neigh                       # note: the GATEWAY's MAC, not Google's. Why?
```

> That last question is important. Explain in your logbook why `ip neigh` never contains an entry for `8.8.8.8`.

Watch the ARP exchange itself:

```bash
# terminal on alpha
sudo tcpdump -i any -n arp &
ip neigh flush all
ping -c1 <BETA_IP>
sleep 2; sudo pkill tcpdump
```

### 1.4 Break the netmask deliberately

On `alpha`, note your current config, then:

```bash
IFACE=$(ip route show default | awk '{print $5; exit}')
MYIP=$(ip -4 -brief addr show "$IFACE" | awk '{print $3}')
echo "current: $MYIP on $IFACE"

sudo ip addr add 192.168.99.10/24 dev "$IFACE"
ip route
ping -c2 -W2 192.168.99.20      # a nonexistent host on a subnet you invented
ip neigh | grep 192.168.99      # FAILED / INCOMPLETE
sudo ip addr del 192.168.99.10/24 dev "$IFACE"
```

> You just produced a **timeout with a correct-looking configuration**. Write down what the symptom looked like and what the actual cause was.

---

## Part 2 — Ports and binding (Day 2)

On `beta`:

```bash
# 2.1 Bound to loopback only
python3 -m http.server 8080 --bind 127.0.0.1 &
ss -tlnp | grep 8080
curl -s -m3 http://127.0.0.1:8080/ >/dev/null && echo "local: OK"
```

On `alpha`:

```bash
curl -v -m5 http://beta:8080/ ; echo "exit=$?"
nc -vz -w3 beta 8080 ; echo "exit=$?"
```

Back on `beta` — now bind to all addresses:

```bash
kill %1
python3 -m http.server 8080 --bind 0.0.0.0 &
ss -tlnp | grep 8080
```

On `alpha`, retry. **It works now.** Write down the exact difference in the `ss` output between the two cases. This single distinction is one of the most common real-world causes of "the service is running but nobody can reach it".

### 2.2 Refused vs timed out — the key branch

On `alpha`:

```bash
# nothing listening on that port -> REFUSED, fast
time nc -vz -w5 beta 9999

# a port that is filtered -> TIMEOUT, slow
# (set up on beta first:)
```

On `beta`:

```bash
sudo nft add table inet lab
sudo nft add chain inet lab input '{ type filter hook input priority 0; policy accept; }'
sudo nft add rule inet lab input tcp dport 9998 drop
python3 -m http.server 9998 --bind 0.0.0.0 &
```

On `alpha`:

```bash
time nc -vz -w5 beta 9998        # times out
time nc -vz -w5 beta 9999        # refused, immediately
```

> **Time both.** The difference in *duration* is itself a diagnostic signal you can feel. Write down which is which and why.

Clean up on `beta`: `sudo nft delete table inet lab`

### 2.3 TCP states — and which machine ends up in TIME_WAIT

On `beta`: `python3 -m http.server 8080 --bind 0.0.0.0 &`
On `alpha`:

```bash
ss -tn state established
curl -s http://beta:8080/ >/dev/null
ss -tn | head
for i in $(seq 1 50); do curl -s http://beta:8080/ >/dev/null; done
```

Now count `TIME_WAIT`. **On both machines.** Do not skip either one — the whole point of this exercise is the difference between them.

```bash
# on alpha (the client that made all 50 requests)
ss -tn state time-wait | tail -n +2 | wc -l

# on beta (the server)
ss -tn state time-wait | tail -n +2 | wc -l
ss -tn state time-wait | head                 # keep the header - read Local Address:Port
ss -s
```

> **`tail -n +2` is not cosmetic.** `ss` prints its column header even when a state filter matches nothing at all, so a bare `ss -tn state time-wait | wc -l` is always exactly one too high — it reports `1` for zero sockets. That off-by-one is small enough to survive a code review and big enough to make an empty result look like a real one.

Alpha shows roughly nothing. Beta is full of them, and every one has **beta's own port 8080 as the local address**. Write down why you think that is before you read on.

> **The rule: `TIME_WAIT` belongs to whoever sends the first `FIN`** — the side performing the *active close*. `python3 -m http.server` speaks HTTP/1.0 and closes the connection after every single response, so in this lab the **server** is the one hanging up, and the server is the one that pays. Count on the client, find nothing, and you conclude `TIME_WAIT` is a myth — which is exactly the wrong lesson, and a very common one.
>
> Keep the diagnostic, because it works everywhere: **"which side has the `TIME_WAIT`s?" answers "who is hanging up?"** A load balancer stacked with `TIME_WAIT` toward a backend is a load balancer that is not reusing connections. A database server stacked with them means your pool is not pooling. It is a free answer, on a live system, to a question that otherwise needs a packet capture.

Now go looking for the knobs everyone tells you to turn — on `beta`:

```bash
sysctl net.ipv4.tcp_fin_timeout      # exists, and has NOTHING to do with TIME_WAIT
sysctl net.ipv4.tcp_tw_reuse         # exists: client-side only, defaults to 2 (loopback only)
sysctl net.ipv4.tcp_tw_recycle       # ERROR - this one was removed from the kernel
sysctl -a 2>/dev/null | grep -i timewait
```

That last one is a trap worth walking into: the only hits are `nf_conntrack_*_timeout_timewait`, which are the **connection tracker's** idea of how long to remember a flow — a completely different subsystem from the TCP socket state, and changing them does nothing to a `TIME_WAIT` socket. There is no sysctl for the TIME_WAIT duration. The 60 seconds is `TCP_TIMEWAIT_LEN`, compiled into the kernel. Read §2.3 of the README for what each of those knobs actually does, then note in your logbook which of them you have seen recommended as a "TIME_WAIT fix".

> Explain in your logbook why `TIME_WAIT` exists at all, and what would go wrong without it — and why the fix for `TIME_WAIT` pressure is keep-alive rather than any of the sysctls above.

### 2.4 Privileged ports

On `beta`, as an unprivileged user:

```bash
python3 -m http.server 80 --bind 0.0.0.0        # read the error
sudo python3 -m http.server 80 --bind 0.0.0.0 & # works
sudo kill %1
```

---

## Part 3 — DNS (Day 3)

```bash
cat /etc/nsswitch.conf | grep hosts
ls -l /etc/resolv.conf                 # is it a symlink? to what?
cat /etc/resolv.conf
resolvectl status
```

```bash
# 3.1 The two different paths
getent hosts beta                      # goes through NSS: reads /etc/hosts
dig beta +short                        # answers! and NOT because DNS knows the name
dig @1.1.1.1 beta +short               # nothing. no DNS server anywhere holds this name
```

> **This is the lesson.** `dig` with no `@server` is not "querying DNS directly" — on Ubuntu 24.04 it queries whatever is in `/etc/resolv.conf`, which is the **systemd-resolved stub listener on 127.0.0.53**. And resolved reads `/etc/hosts` itself (`ReadEtcHosts=yes` is the default), so it happily answers for `beta` out of a file, dressed up as a DNS response. The moment you aim at a real upstream with `@1.1.1.1`, the answer disappears — because there was never a DNS record, only a line in a text file.
>
> Check the resolver you are actually talking to: `dig beta | grep SERVER` says `127.0.0.53#53`, and `resolvectl status` shows what sits behind it.
>
> The operational rule that falls out of this: **`getent hosts <name>` for what the application will see, `dig @<upstream> <name>` for what DNS actually holds.** They disagree far more often than people expect — `/etc/hosts`, `nsswitch.conf` ordering, mDNS, and a stub cache all live in the gap — and when they disagree, the *application* is right about its own behaviour and `dig` is right about DNS. Reaching for only one of them is how you spend an afternoon "fixing DNS" that was never broken.

```bash
# 3.2 Real DNS
dig ubuntu.com
dig ubuntu.com +short
dig ubuntu.com +noall +answer          # just the answer section
dig ubuntu.com MX +short
dig -x 1.1.1.1 +short                  # reverse lookup
dig +trace ubuntu.com | tail -20       # the full delegation chain
```

```bash
# 3.3 TTL and caching - watch the TTL count down
dig ubuntu.com | grep -E '^ubuntu.com'
sleep 10
dig ubuntu.com | grep -E '^ubuntu.com'   # smaller TTL: served from cache
resolvectl flush-caches
dig ubuntu.com | grep -E '^ubuntu.com'   # back to the full TTL
```

```bash
# 3.4 Compare resolvers
dig @1.1.1.1 ubuntu.com +short
dig @8.8.8.8 ubuntu.com +short
time dig @1.1.1.1 ubuntu.com >/dev/null
time dig ubuntu.com >/dev/null           # local cache is much faster
```

### 3.5 Break DNS deliberately

```bash
sudo resolvectl dns "$(ip route show default | awk '{print $5; exit}')" 192.0.2.1
getent hosts ubuntu.com ; echo "exit=$?"
time curl -m 10 -sI https://ubuntu.com | head -1
getent hosts beta                        # STILL WORKS - why?
sudo resolvectl revert "$(ip route show default | awk '{print $5; exit}')"
```

> That contrast — internet names fail, `/etc/hosts` names still work — is a precise fingerprint. Learn to recognise it: **"some names resolve and others don't" almost always means the resolver is broken, not the network.**

---

## Part 4 — Firewall and capture (Day 4)

On `beta`:

```bash
sudo nft list ruleset
sudo ufw status verbose
python3 -m http.server 8080 --bind 0.0.0.0 &
```

```bash
# 4.1 ufw
sudo ufw --force enable
sudo ufw status numbered
# from alpha: curl -m5 http://beta:8080/   → what happens?
sudo ufw allow 8080/tcp
# from alpha: retry
sudo ufw status verbose
sudo nft list ruleset | head -40         # see what ufw actually generated
```

```bash
# 4.2 Source-restricted rules
sudo ufw delete allow 8080/tcp
sudo ufw allow from 10.0.0.0/8 to any port 8080 proto tcp
sudo ufw status numbered
# from alpha: does it work? depends on alpha's subnet - check and explain
```

```bash
# 4.3 DROP vs REJECT - feel the difference
sudo ufw --force reset
sudo nft add table inet lab
sudo nft add chain inet lab input '{ type filter hook input priority 0; policy accept; }'
sudo nft add rule inet lab input tcp dport 8080 drop
# from alpha:  time nc -vz -w5 beta 8080     → slow timeout

sudo nft flush chain inet lab input
sudo nft add rule inet lab input tcp dport 8080 reject
# from alpha:  time nc -vz -w5 beta 8080     → instant refusal

sudo nft delete table inet lab
```

### 4.4 tcpdump

On `beta`:

```bash
sudo tcpdump -i any -n port 8080
```

On `alpha`, in another terminal:

```bash
curl -s http://beta:8080/ >/dev/null
```

Watch the handshake on beta. Identify the SYN, the SYN-ACK, the ACK, the HTTP request, the response, and the FINs.

Now the three diagnostic scenarios — for each, capture on **beta** and observe what does or does not arrive:

```bash
# scenario A: nothing listening
# beta: kill the http.server, then: sudo tcpdump -i any -n port 8080
# alpha: nc -vz -w3 beta 8080
#   → you will see the SYN arrive and an RST go back. Host reachable, no service.

# scenario B: dropped by firewall
# beta: restart http.server; add the drop rule; capture again
# alpha: nc -vz -w5 beta 8080
#   → the SYN ARRIVES and there is NO reply at all. The packet got there and was discarded.

# scenario C: wrong address entirely
# alpha: nc -vz -w5 10.99.99.99 8080
#   → beta's capture shows NOTHING. It never reached this host.
```

> **These three captures are the entire skill.** Write down, in one line each, how you would tell them apart from the client side alone. Then note which one you *cannot* distinguish without access to the server — and what you would do in that case.

```bash
# 4.5 Useful filters to keep
sudo tcpdump -i any -n 'tcp[tcpflags] & (tcp-syn|tcp-rst) != 0'    # handshakes and refusals
sudo tcpdump -i any -n -A -c 20 port 8080                          # payload as text
sudo tcpdump -i any -n -w /tmp/cap.pcap port 8080                  # save for later
sudo tcpdump -r /tmp/cap.pcap -n | head
```

---

## Part 5 — The full diagnostic, practised

Before the drill, run the 10-step sequence from `README.md §4.4` against a *working* connection, so you know what healthy looks like. You cannot recognise abnormal without having looked at normal.

```bash
# alpha -> beta:8080, everything correct
ip -brief address
ip route get <BETA_IP>
getent hosts beta
ping -c3 <BETA_IP>
nc -vz -w3 beta 8080
curl -v -m5 http://beta:8080/
# on beta:
ss -tlnp | grep 8080
sudo nft list ruleset
```

Save the output. That is your baseline.

---

## Part 6 — Drill (Day 5)

```bash
# host
cd infra
make snapshot VM=alpha NAME=pre-w04
make break VM=alpha DRILL=04-network
```

Three layered faults. **Work the sequence, do not guess.** Write every hypothesis and test in your logbook — you will be comparing that trail against the real causes afterwards, and the comparison is the actual exercise.
