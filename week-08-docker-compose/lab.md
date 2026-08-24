# Week 08 — Lab

```bash
cd infra && make w08-up && multipass shell dock
# copy files/stack into the VM, then:
cd /opt/lab/w08/stack
```

---

## Part 1 — Read before you run (Day 1)

```bash
cat docker-compose.yml            # every comment is load-bearing
cat docker-compose.override.yml
cat docker-compose.prod.yml
```

Answer these **before** starting anything:

1. Which services publish a host port, and on which interface? Why not `0.0.0.0`?
2. Which service has no `ports:` at all, and why is that deliberate?
3. What does `condition: service_healthy` on `db` change versus the default?
4. Where does the API get its database password from, and why not from `environment:`?
5. Which file will `docker compose up` use, without any `-f` flags?

```bash
make init            # creates .env and generates secrets/db_password.txt
cat .env
ls -l secrets/
```

```bash
# 1.1 THE most useful command in this week
docker compose config | head -60
```

Compare that output with the raw YAML. Find:
- where `${APP_VERSION}` was substituted;
- where the override file changed a value;
- the fully resolved `depends_on` conditions.

---

## Part 2 — Start it and watch the ordering (Day 2)

```bash
docker compose up -d --build
```

Read the output carefully. You should see this shape:

```
Container stack-db-1     Started
Container stack-db-1     Waiting        ← waiting for the HEALTHCHECK
Container stack-db-1     Healthy
Container stack-api-1    Started        ← only now
Container stack-api-1    Waiting
Container stack-api-1    Healthy
Container stack-proxy-1  Started        ← and only now
```

> **That is `condition: service_healthy` doing its job.** Copy this output into your logbook; you will compare it against the broken version in §2.2.

```bash
docker compose ps
curl -s localhost:8080/ | jq
curl -s localhost:8080/items | jq
curl -s localhost:8080/health | jq
```

### 2.1 Prove service DNS works

```bash
docker compose exec api sh -c 'getent hosts db cache'
docker compose exec api sh -c 'python3 -c "import socket;print(socket.gethostbyname(\"db\"))"'
docker compose exec api env | grep -E 'DB_|REDIS_'
```

> Note `DB_HOST=db`, not an IP. Now run `docker compose restart db`, check the IP again, and confirm the API still works. **That is why you never hard-code container IPs.**

### 2.2 Break the ordering deliberately

Change `condition: service_healthy` to `condition: service_started` under `api.depends_on.db`, then:

```bash
docker compose down
docker compose up -d
docker compose logs api | head -20
```

Look for the retry messages:

```json
{"level":"warn","msg":"database not reachable, retrying","attempt":1,"delay":0.5}
{"level":"warn","msg":"database not reachable, retrying","attempt":2,"delay":1.0}
{"level":"info","msg":"database reachable","attempt":4}
```

> **Two lessons in one.** First, `service_started` really does start the API before Postgres is ready. Second — and more importantly — **the stack still came up**, because the application retries. Now delete `connect_with_retry` from `app.py`, rebuild, and watch it crash-loop instead. That comparison is the point: the orchestrator's condition makes startup *pleasant*; the retry loop makes the service *correct*.

Restore `service_healthy` afterwards.

---

## Part 3 — Failure and degradation (Day 2)

### 3.1 The cache is optional

```bash
docker compose stop cache
sleep 3
curl -s localhost:8080/health | jq
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/items
docker compose ps | grep api
```

Measured result:

```
{"status":"degraded","db":true,"cache":false}     ← HTTP 200
items: 200
api    Up (healthy)                                ← stays in rotation
```

> The API reports **degraded but healthy**. A load balancer keeps sending it traffic, which is correct — it can still serve. Compare with Week 5 §4.3: a health check that failed here would have removed every replica at once and turned a cache outage into a total outage.

```bash
docker compose start cache
```

### 3.2 The database is not optional

```bash
docker compose stop db
sleep 3
curl -s localhost:8080/health | jq
curl -s localhost:8080/items | jq
```

Measured result:

```
health: 503  {"status":"unhealthy","reason":"database unreachable"}
items:  503  {"error":"database unavailable","hint":"check `docker compose logs db`"}
```

> **503, not 500.** That distinction is deliberate and it matters operationally: `500` says *"I have a bug, page a developer"*; `503` says *"my dependency is down, fix that"*. Week 5's status-code triage, now on the emitting side.

```bash
docker compose start db
sleep 8
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/items      # 200
```

> **The API recovered without being restarted.** Nothing restarted it — it simply re-probed and found the database again. That is the property `connect_with_retry` plus live probing buys you, and it is what will save you at 3am when a database fails over and no orchestrator restarts your app.

---

## Part 4 — Configuration and the Postgres password trap (Day 3)

```bash
# 4.1 Where did each variable come from?
docker compose config | grep -A15 'api:' | head -25
docker compose exec api env | sort | grep -E 'DB_|APP_'
```

```bash
# 4.2 The secret is a FILE, not an env var
docker compose exec api cat /run/secrets/db_password
docker inspect stack-api-1 --format '{{json .Config.Env}}' | jq
```

> The password is **not** in the env list. Compare with a stack that uses `environment: DB_PASSWORD: hunter2` — there, anyone who can run `docker inspect` has the credential.

```bash
# 4.3 Required variables
unset POSTGRES_USER
sed -i 's/POSTGRES_USER:-postgres/POSTGRES_USER:?POSTGRES_USER must be set/' docker-compose.yml
mv .env .env.bak
docker compose config          # read the error message
mv .env.bak .env
```

### 4.4 The trap — do this one carefully

```bash
docker compose up -d
docker compose exec db psql -U postgres -d appdb -c 'SELECT 1;'   # works

# now "change the password"
openssl rand -base64 24 | tr -d '\n' > secrets/db_password.txt
docker compose up -d --force-recreate
sleep 8
docker compose logs api | tail -5
curl -s localhost:8080/health | jq
```

> The API cannot authenticate. **`POSTGRES_PASSWORD` is read only when the data directory is empty** — the database still has the *old* password stored inside its volume, while the API now sends the new one. Changing the variable did nothing to the database.

Three ways out — try each and note the cost:

```bash
# (a) revert the secret file to the old value      → zero data loss
# (b) change it inside the database itself         → zero data loss, correct
docker compose exec db psql -U postgres -c "ALTER USER postgres PASSWORD '$(cat secrets/db_password.txt)';"
docker compose restart api
# (c) delete the volume                            → THE DATABASE IS GONE
docker compose down -v
```

> Write in your logbook: which of these would you do in production, and what would you have done *beforehand* to avoid needing to choose?

---

## Part 5 — Overrides, profiles, scaling (Day 4)

```bash
# 5.1 See the merge
docker compose config | grep -A6 'api:' | grep -E 'image|volumes|APP_VERSION'
docker compose -f docker-compose.yml config | grep -E 'APP_VERSION'         # base only
docker compose -f docker-compose.yml -f docker-compose.prod.yml config | grep -A4 volumes
```

> Note that the prod overlay sets `volumes: []` and **replaces** the list rather than removing one entry. Lists are replaced wholesale; maps are merged. Confirm this yourself with `docker compose config`.

```bash
# 5.2 Profiles
docker compose ps                          # no seed container
docker compose --profile tools run --rm seed
docker compose exec db psql -U postgres -d appdb -c 'SELECT * FROM items;'
```

### 5.3 Scaling — and the two traps it exposes

```bash
docker compose up -d --scale api=3
```

**Trap one.** With the dev override active you get:

```
Error response from daemon: ... Bind for 127.0.0.1:8000 failed: port is already allocated
```

Three containers cannot all bind host port 8000. **A service with a fixed published port cannot be scaled.** Drop the override:

```bash
docker compose -f docker-compose.yml up -d --scale api=3
docker compose -f docker-compose.yml ps
```

**Trap two — the one nobody expects.** Now send some traffic:

```bash
for i in $(seq 1 9); do curl -s localhost:8080/items | jq -r .served_by; done | sort | uniq -c
```

Measured result on a first attempt:

```
      9 ee2853f784ed        ← ALL NINE went to ONE replica
```

All three replicas were healthy. Diagnose it before reading on.

<details>
<summary>The cause</summary>

Open-source nginx resolves an upstream hostname **once, at configuration load time**, and caches the result forever. It resolved `api` when only one replica existed and never looked again.

Prove it:

```bash
docker compose -f docker-compose.yml restart proxy
for i in $(seq 1 9); do curl -s localhost:8080/items | jq -r .served_by; done | sort | uniq -c
#       4 9eba3200bb59
#       2 d3fbab8e1325
#       3 ee2853f784ed        ← now it spreads
```

The fix, which is already in `nginx/default.conf`, needs **both** parts:

```nginx
resolver 127.0.0.11 valid=10s ipv6=off;   # Docker's embedded DNS
set $upstream_api api;                     # a VARIABLE - this is load-bearing
proxy_pass http://$upstream_api:8000;
```

nginx only re-resolves names that appear in a *variable*. With this in place, scaling from 3 to 5 is picked up automatically with no reload:

```bash
docker compose -f docker-compose.yml up -d --scale api=5
sleep 25
for i in $(seq 1 15); do curl -s localhost:8080/items | jq -r .served_by; done | sort -u | wc -l
# 5
```
</details>

> **This is a real production bug, not a lab curiosity.** It also appears as "we redeployed the backend and nginx returned 502 until we restarted it" — same cause, container recreated with a new IP. Week 10 shows how Swarm's routing mesh removes the problem entirely.

---

## Part 6 — Debugging practice

```bash
docker compose ps                       # up AND healthy?
docker compose logs --tail=50 api
docker compose logs --tail=30 db
docker compose exec api env | grep DB_  # ← the step almost nobody runs
docker compose exec api getent hosts db
docker compose config                   # the resolved truth
docker compose top
docker compose events --since 10m
```

Practise the order until it is automatic. Then:

---

## Part 7 — Drill (Day 5)

```bash
# host
cd infra
make snapshot VM=dock NAME=pre-w08
make break VM=dock DRILL=08-compose STACK=/opt/lab/w08/stack
```

Symptom: *"Every container shows Up, the API answers on :8080, and every request returns 500. It worked before the weekend."*

Note the symptom says **500**, not 503. Given what you learned in Part 3, what does that tell you before you run a single command?
