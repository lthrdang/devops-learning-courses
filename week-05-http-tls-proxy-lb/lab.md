# Week 05 — Lab

```bash
cd infra && make w05-up && ./scripts/lab-up.sh hosts alpha beta
multipass shell alpha
sudo apt-get install -y nginx haproxy openssl
```

Copy `files/` into the VM (via `multipass mount` or `multipass transfer`).

---

## Part 1 — HTTP, observed (Day 1)

```bash
# 1.1 See the whole exchange
curl -v http://example.com 2>&1 | head -40
curl -sI https://example.com
```

```bash
# 1.2 The Host header is what selects the site
curl -v -H 'Host: example.com' http://93.184.215.14/ 2>&1 | head -20
curl -v -H 'Host: totally-wrong.invalid' http://example.com/ 2>&1 | grep -E '^< HTTP'
```

```bash
# 1.3 The timing breakdown - learn to read this
curl -sS -o /dev/null -w '
  dns:      %{time_namelookup}s
  connect:  %{time_connect}s
  tls:      %{time_appconnect}s
  ttfb:     %{time_starttransfer}s
  total:    %{time_total}s
  code:     %{http_code}
' https://example.com ; echo
```

Run it against three targets — a nearby site, a distant site, and `localhost`. Write the three profiles into your logbook and note which number changed most.

```bash
# 1.4 Raw HTTP, by hand. Do this once; it demystifies everything.
printf 'GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n' | nc example.com 80 | head -20
```

> Note the `\r\n`. HTTP uses CRLF line endings, and a bare `\n` gets you a confusing failure. This is why hand-written HTTP in scripts so often "mysteriously" does not work.

```bash
# 1.5 Keep-alive, measured
curl -sS -o /dev/null -w 'total=%{time_total}\n' https://example.com https://example.com https://example.com
# vs a fresh connection each time:
for i in 1 2 3; do curl -sS -o /dev/null -H 'Connection: close' -w 'total=%{time_total}\n' https://example.com; done
```

---

## Part 2 — Backends and a reverse proxy (Day 1–3)

### 2.1 Start three backends

```bash
sudo mkdir -p /opt/lab/w05 && sudo chown ubuntu:ubuntu /opt/lab/w05
cd /opt/lab/w05
cp ~/course/week-05-http-tls-proxy-lb/files/backend.py .

python3 backend.py --port 9001 --name app1 2>/tmp/app1.log &
python3 backend.py --port 9002 --name app2 2>/tmp/app2.log &
python3 backend.py --port 9003 --name app3 2>/tmp/app3.log &

curl -s localhost:9001/ | jq
curl -s localhost:9002/health | jq
```

### 2.2 Put Nginx in front

```bash
sudo cp ~/course/week-05-http-tls-proxy-lb/files/nginx-lab.conf /etc/nginx/sites-available/lab.conf
sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/lab.conf /etc/nginx/sites-enabled/lab.conf
```

The config references TLS certificates that do not exist yet, so `nginx -t` will fail. **Read the error — it is precise about which file is missing.** Comment out the whole `listen 443` server block for now, validate, and reload:

```bash
sudo nginx -t
sudo systemctl reload nginx
echo "127.0.0.1 app.lab.local" | sudo tee -a /etc/hosts
curl -s http://app.lab.local/ | jq
```

Open the config and find the block marked **PART 2 ONLY** in the port-80 server. That block is what just answered you. Read it before you go on — with no certificate there is no HTTPS listener, so the production-shaped `return 301 https://...` (sitting commented out right below it) would bounce every request in this part of the lab into a closed port. You proxy in plaintext for Part 2, and you put the redirect back the moment TLS exists. **A permanent redirect you cannot serve the destination for is worse than no redirect at all** — browsers cache 301s aggressively, so a real one deployed in this state keeps sending users to a dead port long after you fix it.

### 2.3 Watch the load balancing happen

```bash
for i in $(seq 1 12); do curl -s http://app.lab.local/ | jq -r .backend; done | sort | uniq -c
```

> The `backup` server should receive **nothing**. Confirm that, and explain why.

### 2.4 Prove the forwarding headers matter

```bash
curl -s http://app.lab.local/ | jq '{host_header, x_forwarded_for, x_forwarded_proto}'
```

Now comment out the four `proxy_set_header` lines **in the PART 2 block** (the 443 block is still commented out, so its copy is not in play), reload, and repeat:

```bash
sudo nginx -t && sudo systemctl reload nginx
curl -s http://app.lab.local/ | jq '{host_header, x_forwarded_for, x_forwarded_proto}'
```

> Write down exactly what the backend now believes about the client. Then reason about what an application doing rate-limiting-per-IP would do with this. Restore the headers afterwards.

### 2.5 Produce each error class deliberately

```bash
# 500 - the APPLICATION failed. nginx is fine.
curl -si http://app.lab.local/error | head -1
sudo tail -2 /var/log/nginx/app-error.log        # probably nothing here!

# 504 - the upstream is alive but too slow
curl -si "http://app.lab.local/slow?s=40" | head -1
sudo tail -2 /var/log/nginx/app-error.log        # "upstream timed out"

# 502 - the upstream is not reachable. Two steps, and the first one is the point.
kill %1 %2                                        # stop app1 and app2
curl -si http://app.lab.local/ | head -1          # 200! Predict this before you run it.
curl -s http://app.lab.local/ | jq -r .backend    # app3 - the backup took over
sudo tail -3 /var/log/nginx/app-error.log        # "connect() failed (111: Connection refused)"

kill %3                                           # now stop the backup too
curl -si http://app.lab.local/ | head -1          # 502 at last
sudo tail -3 /var/log/nginx/app-error.log        # the same errors, now with nowhere to fail over to
```

> **Two thirds of your fleet was down and the client saw a clean 200.** That is `backup` doing exactly its job — and it is also why "users aren't complaining" is not evidence that nothing is broken. The error log recorded every failed `connect()` in the first step, while the status code recorded none of them. **The log knew before the user did.** Only when the last member is gone does nginx run out of places to retry and return 502.

> **This is the core exercise of the week.** Three failures, three completely different causes, and the client only sees a number. Record which log told you the truth in each case.

Restart the backends afterwards.

---

## Part 3 — TLS (Day 2)

### 3.1 Be your own CA

```bash
cd /opt/lab/w05
cp ~/course/week-05-http-tls-proxy-lb/files/make-ca.sh .
./make-ca.sh app.lab.local "$(hostname -I | awk '{print $1}')"
ls -l tls/
```

The script builds a **three-level chain** — root CA → intermediate CA → your leaf — because that is the shape of every certificate on the public internet, and because a two-level chain cannot reproduce any of the chain bugs you will actually be paged about.

Inspect what you made:

```bash
openssl x509 -in tls/app.lab.local.crt -noout -text | head -30
openssl x509 -in tls/app.lab.local.crt -noout -subject -issuer -dates
openssl x509 -in tls/app.lab.local.crt -noout -ext subjectAltName

# Who signed whom? Read the issuer of each and chain them up by hand.
openssl x509 -in tls/ca.crt  -noout -subject -issuer -ext basicConstraints,keyUsage
openssl x509 -in tls/int.crt -noout -subject -issuer -ext basicConstraints,keyUsage
```

> Note the intermediate's `CA:TRUE, pathlen:0` — it may sign leaves but may **not** sign another CA. Note also that both CAs assert `keyCertSign` in a *critical* `keyUsage`. A CA certificate missing that is the classic "works in openssl, fails in Go and Java" cert.

Now verify, and watch the first command fail:

```bash
openssl verify -CAfile tls/ca.crt tls/app.lab.local.crt                   # FAILS
openssl verify -CAfile tls/ca.crt -untrusted tls/int.crt tls/app.lab.local.crt   # OK
```

> The first fails with `unable to get local issuer certificate`, and **the certificate is perfectly fine**. Trusting the root is not enough: something has to supply the intermediate that links the leaf to it. `-untrusted` is how you hand it to openssl on the command line. On a real server, the equivalent is the chain file — which is exactly what 3.5(d) makes you break.

### 3.2 Install it in Nginx

```bash
sudo mkdir -p /etc/nginx/tls
sudo cp tls/app.lab.local.fullchain.crt tls/app.lab.local.key /etc/nginx/tls/
sudo chmod 600 /etc/nginx/tls/app.lab.local.key
```

Two edits to `/etc/nginx/sites-available/lab.conf`, and they go together:

1. Uncomment the whole `listen 443` server block — the certificate it wants now exists.
2. **Delete the block marked `PART 2 ONLY`** from the port-80 server, and uncomment the `return 301 https://...` line below it.

```bash
sudo nginx -t && sudo systemctl reload nginx
curl -sI http://app.lab.local/ | head -1     # 301 now, not 200
```

> That 301 is the config in its real shape: port 80 exists only to send people to port 443 (and to answer ACME challenges). Everything from here on is HTTPS.

```bash
# 3.3 It fails - and the failure is the lesson
curl -v https://app.lab.local/ 2>&1 | grep -E 'SSL|certificate|verify'
```

Three ways to proceed, in increasing order of correctness:

```bash
curl -k https://app.lab.local/                              # (a) ignore verification. NEVER in production.
curl --cacert tls/ca.crt https://app.lab.local/             # (b) trust this CA, for this command
sudo cp tls/ca.crt /usr/local/share/ca-certificates/lab-ca.crt   # (c) trust it system-wide
sudo update-ca-certificates
curl https://app.lab.local/                                  # now it just works
```

> `-k` is the flag that hides real problems. Note in your logbook what `-k` would have hidden if the certificate had been for the *wrong hostname* or *issued by an attacker*.

### 3.4 Inspect a live handshake

```bash
openssl s_client -connect app.lab.local:443 -servername app.lab.local </dev/null 2>/dev/null | head -30
openssl s_client -connect app.lab.local:443 -servername app.lab.local </dev/null 2>&1 | grep -E 'Protocol|Cipher|Verify'
```

Compare with and without `-servername`, and against a real site:

```bash
openssl s_client -connect example.com:443 -servername example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

### 3.5 Break TLS on purpose — four experiments

```bash
# (a) wrong hostname. --resolve sends the SNI name wrong.lab.local to the same
#     socket, so the server answers with the same certificate as always.
curl -v --cacert tls/ca.crt --resolve wrong.lab.local:443:127.0.0.1 \
  https://wrong.lab.local/ 2>&1 | grep -i 'subject\|match\|SSL'

# (b) expired certificate
DAYS=1 OUT=./tls-exp ./make-ca.sh short.lab.local
faketime 2030-01-01 curl ... # (or just note the notAfter date and reason about it)
openssl x509 -in tls-exp/short.lab.local.crt -noout -dates

# (c) clock skew - the OTHER half of "certificate expired"
sudo timedatectl set-ntp false && sudo date -s '-3 years'
curl -sI https://ubuntu.com | head -1        # read the error
sudo timedatectl set-ntp true                # then confirm: timedatectl

# (d) missing intermediate: serve ONLY the leaf
sudo cp tls/app.lab.local.crt /etc/nginx/tls/app.lab.local.fullchain.crt
sudo systemctl reload nginx
curl -v https://app.lab.local/ 2>&1 | grep -i 'issuer\|unable'
# restore:
sudo cp tls/app.lab.local.fullchain.crt /etc/nginx/tls/ && sudo systemctl reload nginx
```

> Why `wrong.lab.local` in (a), and not `https://127.0.0.1/`? Look at the SAN list you printed in 3.1: `make-ca.sh` puts `127.0.0.1` and `localhost` in *every* certificate it issues, precisely so the lab is convenient. Testing either of those would have **succeeded**, and you would have "proved" that hostname verification works by demonstrating nothing at all. **When you build a negative test, check first that the thing you are testing is actually absent** — a passing negative test that cannot fail is worse than no test.

> Experiment (c) goes **backwards** on purpose. Forward gives you `certificate has expired`, which you already produced in (b); backwards gives you `certificate is not yet valid` — the error people never expect, because the certificate is perfect and it is the *clock* that is wrong. **Any TLS error should prompt you to check the clock on both ends before you touch the certificate.**
>
> ⚠️ A three-year jump backwards is disruptive while it lasts: `apt` rejects repository metadata as being from the future, systemd timers with a `Persistent=` schedule can fire immediately, and file mtimes written during the window confuse `make` afterwards. Do it on the lab VM only, keep the window to seconds, and confirm with `timedatectl` that `System clock synchronized: yes` before you move on.

> (d) works now for a concrete reason: `make-ca.sh` builds root → intermediate → leaf, and `app.lab.local.fullchain.crt` is leaf **+ intermediate**. Overwriting it with the bare leaf strips the intermediate, and the client — which trusts the root and has never seen the intermediate — cannot bridge the gap. This is the same failure as the `openssl verify` without `-untrusted` in 3.1, arriving over the network instead. Confirm the server's side of it with `openssl s_client -connect app.lab.local:443 -servername app.lab.local </dev/null 2>/dev/null | grep -E 's:|i:'` — count the certificates before and after.

---

## Part 4 — HAProxy and health checks (Day 4)

```bash
sudo cp ~/course/week-05-http-tls-proxy-lb/files/haproxy-lab.cfg /etc/haproxy/haproxy.cfg
```

**Before you validate or start anything:** nginx already holds 80/443, and the shipped config binds `*:80`. Edit `bind *:80` → `bind *:8080` now.

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg      # validate FIRST, always
sudo systemctl restart haproxy
sudo systemctl status haproxy --no-pager | head -5
```

> Note what `haproxy -c` did **not** catch. It parses the config; it never opens a socket, so a port that is already taken is invisible to it. Had you validated before the edit you would have got a clean green tick and then a failed `restart` with `bind(): Address already in use` — buried in `journalctl -u haproxy`, not in the terminal. **"The config is valid" and "the service can start" are two different claims**, and only `systemctl status` answers the second one.

```bash
curl -s localhost:8080/ | jq -r .backend
for i in $(seq 1 20); do curl -s localhost:8080/ | jq -r .backend; done | sort | uniq -c
```

Open the stats page from your host browser: `http://<ALPHA_IP>:8404/`

### 4.1 Watch a health check remove a backend

Keep the stats page open, and in another terminal:

```bash
curl -s localhost:9001/toggle | jq        # app1 now returns 503 on /health
watch -n1 'curl -s localhost:8080/ | jq -r .backend'
```

Time how long until app1 stops receiving traffic. Compare with `inter 2s fall 3` — does it match your prediction?

```bash
curl -s localhost:9001/toggle | jq        # bring it back
```

Now watch it return, and compare with `rise 2`.

### 4.2 Watch failover to the backup

```bash
curl -s localhost:9001/toggle >/dev/null
curl -s localhost:9002/toggle >/dev/null
curl -s localhost:8080/ | jq -r .backend      # app3 - the backup
```

> **Note what the user experienced during the transition.** Run a request loop while you toggle, and count how many requests failed. That number is what "high availability" actually costs you when the health check interval is 2s and `fall` is 3.

### 4.3 L4 vs L7

Add a TCP-mode listener and observe the difference:

```
listen tcp_demo
    bind *:8090
    mode tcp
    balance roundrobin
    server app1 127.0.0.1:9001 check
    server app2 127.0.0.1:9002 check
```

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg && sudo systemctl reload haproxy
curl -s localhost:8090/ | jq -r .backend
curl -s localhost:8090/api/anything | jq -r .backend
```

> In `mode tcp`, path-based routing is impossible and the `X-Forwarded-For` header is never added. Confirm both, and explain to yourself why.

---

## Part 5 — The full stack

Build the whole chain and prove it end to end:

```
client → nginx (TLS termination, :443) → haproxy (:8080, L7 routing + health checks) → 3 backends
```

```bash
# point nginx's upstream at haproxy instead of the backends directly
sudo sed -i 's|server 127.0.0.1:900[123].*|server 127.0.0.1:8080;|' /etc/nginx/sites-available/lab.conf
# (clean up the duplicate lines it leaves, then:)
sudo nginx -t && sudo systemctl reload nginx

curl -s https://app.lab.local/ | jq
```

Then kill one backend and confirm that a user of the HTTPS endpoint sees **no error at all**. That is the deliverable of this week.

---

## Part 6 — Drill (Day 5)

```bash
# host
cd infra
make snapshot VM=alpha NAME=pre-w05
make break VM=alpha DRILL=05-proxy
```

Symptom: *"The website returns 502. Nginx is running. I restarted it twice."*

**Target: cause identified in under 5 minutes.** Start a timer. Write down the first three commands you ran, before you ran them.
