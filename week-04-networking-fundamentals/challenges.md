# Week 04 — Challenges

---

### C4.1 — The diagnostic script

Write `netdiag.sh HOST PORT` that runs the full layer-by-layer sequence automatically and prints a verdict:

```
LAYER 3 (route)      OK    via ens3, src 10.223.1.42
LAYER 3 (icmp)       OK    3/3 packets, avg 0.4ms
NAME RESOLUTION      OK    beta -> 10.223.1.43  (source: /etc/hosts)
LAYER 4 (tcp/8080)   FAIL  timed out after 3s
                           → a firewall is dropping, or the host is filtering.
                           → next: check nft on the SERVER, and tcpdump there.
LAYER 7 (http)       SKIP  (transport failed)

VERDICT: reachable at layer 3, blocked at layer 4.
```

It must distinguish **refused** from **timed out** and say what each implies. Exit code: 0 if fully working, non-zero at the first failing layer.

---

### C4.2 — Two subnets and a router

Give `alpha` a second address on `192.168.50.1/24` and `beta` one on `192.168.60.1/24`. They are now on different subnets and cannot reach each other on those addresses.

Make them able to, using a third VM as a router: enable `ip_forward`, add routes on both ends, and prove packets traverse the router with `tcpdump` on it.

Then answer: what happens if you add the route on `alpha` but forget it on `beta`? Predict the symptom precisely before testing. (Hint: think about which direction fails, and what that looks like from each side.)

---

### C4.3 — DNS forensics

For `github.com`, determine using `dig` alone:

1. Every A record, and their TTLs.
2. The authoritative nameservers.
3. Whether it uses a CNAME anywhere in the chain.
4. The full delegation path from the root.
5. Whether the reverse lookup of its IP matches the forward name.
6. How long a change to its A record could take to reach every user worldwide.

Question 6 has a subtler answer than "the TTL". Explain why.

---

### C4.4 — The capture challenge

Capture and identify, from a `tcpdump` file alone, without being told which is which:

1. A successful HTTP request.
2. A connection refused.
3. A connection dropped by a firewall.
4. A DNS query and its response.
5. A TCP connection that was reset mid-transfer.

Produce each of the five deliberately, save one combined `.pcap`, and write the `tcpdump -r` filter that isolates each.

---

### C4.5 — Bind on purpose

Configure one service so that it is reachable:

- from the machine itself, and
- from `alpha`, and
- **not** from any other host,

using **three different mechanisms**: (a) bind address, (b) firewall rule, (c) something at the application layer.

For each, state its advantages and the specific failure mode it has that the other two do not. Then answer: in a real system, which would you use, and would you use more than one?

---

### C4.6 — Explain the symptom

For each symptom, list the possible causes in the order you would check them, and the single command that discriminates fastest:

1. `curl` to a hostname times out, but to its IP address works.
2. `curl` works from the server itself but not from another host.
3. `ping` works but `curl` times out.
4. `ping` fails but `curl` works.
5. Everything worked yesterday; today intermittently ~30% of requests time out.
6. The connection succeeds but hangs before any data arrives.
7. `nc -vz` says the port is open but the application returns nothing.

Number 4 and number 5 are the interesting ones.
