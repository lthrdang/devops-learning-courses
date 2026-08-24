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

The config references TLS certificates that do not exist yet, so `nginx -t` will fail. **Read the error — it is precise about which file is missing.** Comment out the `listen 443` server block for now, validate, and reload:

```bash
sudo nginx -t
sudo systemctl reload nginx
echo "127.0.0.1 app.lab.local" | sudo tee -a /etc/hosts
curl -s http://app.lab.local/ | jq
```

### 2.3 Watch the load balancing happen

```bash
for i in $(seq 1 12); do curl -s http://app.lab.local/ | jq -r .backend; done | sort | uniq -c
```

> The `backup` server should receive **nothing**. Confirm that, and explain why.

### 2.4 Prove the forwarding headers matter

```bash
curl -s http://app.lab.local/ | jq '{host_header, x_forwarded_for, x_forwarded_proto}'
```

Now comment out the four `proxy_set_header` lines, reload, and repeat:

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

# 502 - the upstream is not reachable
kill %1 %2                                        # stop app1 and app2
curl -si http://app.lab.local/ | head -1
sudo tail -3 /var/log/nginx/app-error.log        # "connect() failed (111: Connection refused)"
```

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

Inspect what you made:

```bash
openssl x509 -in tls/app.lab.local.crt -noout -text | head -30
openssl x509 -in tls/app.lab.local.crt -noout -subject -issuer -dates
openssl x509 -in tls/app.lab.local.crt -noout -ext subjectAltName
openssl verify -CAfile tls/ca.crt tls/app.lab.local.crt
```

### 3.2 Install it in Nginx

```bash
sudo mkdir -p /etc/nginx/tls
sudo cp tls/app.lab.local.fullchain.crt tls/app.lab.local.key /etc/nginx/tls/
sudo chmod 600 /etc/nginx/tls/app.lab.local.key
# uncomment the 443 server block
sudo nginx -t && sudo systemctl reload nginx
```

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
# (a) wrong hostname
curl -v --cacert tls/ca.crt https://127.0.0.1/ 2>&1 | grep -i 'subject\|match'

# (b) expired certificate
DAYS=1 OUT=./tls-exp ./make-ca.sh short.lab.local
faketime 2030-01-01 curl ... # (or just note the notAfter date and reason about it)
openssl x509 -in tls-exp/short.lab.local.crt -noout -dates

# (c) clock skew - the OTHER half of "certificate expired"
sudo timedatectl set-ntp false && sudo date -s '+3 years'
curl -sI https://ubuntu.com | head -1        # read the error
sudo timedatectl set-ntp true

# (d) missing intermediate: serve ONLY the leaf
sudo cp tls/app.lab.local.crt /etc/nginx/tls/app.lab.local.fullchain.crt
sudo systemctl reload nginx
curl -v https://app.lab.local/ 2>&1 | grep -i 'issuer\|unable'
# restore:
sudo cp tls/app.lab.local.fullchain.crt /etc/nginx/tls/ && sudo systemctl reload nginx
```

> Experiment (c) is worth dwelling on: the error says "certificate is not yet valid", and the certificate is perfect. **Any TLS error should prompt you to check the clock on both ends before you touch the certificate.**

---

## Part 4 — HAProxy and health checks (Day 4)

```bash
sudo cp ~/course/week-05-http-tls-proxy-lb/files/haproxy-lab.cfg /etc/haproxy/haproxy.cfg
sudo haproxy -c -f /etc/haproxy/haproxy.cfg      # validate FIRST, always
sudo systemctl restart haproxy
```

Nginx is on 80/443, so point HAProxy at 8080 for the lab (edit `bind *:80` → `bind *:8080`).

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
