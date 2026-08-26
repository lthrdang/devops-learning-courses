# Week 08 — Solutions & discussion

---

## The drill (08-compose) — worked through

**Before running anything**, resolve the contradiction in the report — because it is not a contradiction. Everything is `healthy`, `/items` returns 200, *and* logins are failing. All three are true at once.

The reason is in `api/app.py`. Its readiness check is `tcp_probe()`: it opens a TCP socket to `db:5432` and returns. It never authenticates and it never runs a query. So the container `HEALTHCHECK`, `/health` and `/ready` establish exactly one fact — **the port is open** — and `/items` returns a hard-coded list that never touches Postgres at all. **A healthcheck can only fail on the code path it exercises.** This one does not exercise credentials, so no credential problem will ever turn it red.

That single observation tells you where to look before you type a command: at the one component that *does* log in. In this stack that is the `seed` job — which is precisely the thing that broke.

```bash
docker compose ps                            # everything healthy — as reported
curl -s localhost:8080/items                 # 200 — as reported
docker compose --profile tools run --rm seed # → password authentication failed for user "postgres"
docker compose logs db | grep -i 'password authentication failed'
ls -l secrets/db_password.txt                # mtime: it changed on Friday
docker compose config | grep -i password     # a PATH — so the value lives in the file
```

**Cause 1: the secret was rotated, and the database was not.** Both `api` and `db` mount the same `secrets/db_password.txt`, so everything that *reads* the file now sends the new password. Postgres still has the old one, because `POSTGRES_PASSWORD` / `POSTGRES_PASSWORD_FILE` is consumed **only on the first init of an empty data directory**. The `dbdata` volume already existed, so rewriting the file changed every client and nothing at all in the server. This is the trap from §4.4, arriving as a half-finished rotation.

```bash
# The correct fix, with no data loss — this IS the rotation procedure:
docker compose exec db psql -U postgres \
  -c "ALTER USER postgres PASSWORD '$(cat secrets/db_password.txt)';"
docker compose restart api

# Or put the old value back, if you still have it:
sudo cp /root/.drill-08-secret.bak secrets/db_password.txt
sudo chmod 0644 secrets/db_password.txt        # 0644, not 0600 — see the Makefile
```

Do **not** reach for `docker compose down -v`. It "works" by destroying the database.

**Cause 2, entirely independent of the first: `condition: service_started` instead of `service_healthy`** on `depends_on`. Note that this fault produced *no symptom at all* — `connect_with_retry()` in the app absorbed it. That is the case for retry logic in one line: it turns a startup-order bug into a non-event. You find this one with `docker compose config`, not by reading the file you think you already know.

**The generalisable lesson:** *"healthy" means "the checks I wrote passed", and nothing more.* A probe that does not exercise a dependency cannot detect a broken one — so when a healthcheck and a user disagree, the healthcheck is usually the one that is wrong. And a database's init variables only ever apply to an empty volume.

---

## C8.6 — Secret handling audit

| # | Question | Answer for this stack | Fix if "yes" |
|---|---|---|---|
| 1 | readable via `docker inspect`? | **No** — only `DB_PASSWORD_FILE=/run/secrets/db_password`, a path | use file-based secrets, as here |
| 2 | in the image? | **No** — never `COPY`d or `ENV`d | never `ENV SECRET=`; use BuildKit `--mount=type=secret` if needed at build time |
| 3 | in `docker compose config`? | **No** — it prints the file *path* | avoid `environment:` for secrets |
| 4 | in shell history? | **No** — `make init` generates it with `openssl rand` and redirects to a file | never type a secret as a command argument; `read -s`, a file, or a generator |
| 5 | in the container's environment? | **No** — the app reads the file at startup | the `_FILE` convention |
| 6 | who can read the file on the host? | **every local user** — the file is `chmod 644`, and it has to be | tighten the **directory** to `chmod 700 secrets/`, and gitignore it |

```bash
docker inspect stack-api-1 --format '{{json .Config.Env}}' | jq          # no password
docker compose config | grep -i password                                  # a path, not a value
docker history lab/stack-api:1.0 | grep -i -c secret                      # 0
ls -ld secrets                                                            # drwx------
ls -l secrets/db_password.txt                                             # -rw-r--r--
docker compose exec api cat /run/secrets/db_password                      # present INSIDE only
```

**Risks that remain, and whether to accept them on one host:**

- **Anyone in the `docker` group can read the secret**, by exec-ing into the container or mounting the file. Unavoidable — `docker` group membership is root (Week 7). *Accept, and control who is in the group.*
- **The secret file is world-readable, and you cannot simply `chmod 600` it.** This is the honest answer to question 6 and the one people get wrong. A Compose `file:` secret is a **bind mount**: the container sees the host file's uid, gid and mode unchanged. `api/Dockerfile` runs as `USER appuser` (uid 10001), so a 0600 file owned by you is unreadable inside the container — `open()` raises `PermissionError` at import, the healthcheck never passes, and `docker compose up` aborts with *"dependency failed to start: container stack-api-1 is unhealthy"*. The `uid:`/`gid:`/`mode:` sub-options that would fix it are **Swarm-only**; Compose accepts them in the YAML and ignores them for file-based secrets. Your real options on one host are: run the container as the uid that owns the file, or leave the file 0644 and protect the *directory* with `chmod 700 secrets/`. *Accept on a single host; on a fleet, use Swarm secrets (Week 10) — mounted from a tmpfs with the uid/gid/mode you ask for, so a 0400 root-owned secret is still readable by uid 10001, and encrypted at rest in Raft.*
- **Rotation is manual** and, as §4.4 proved, changing the file does not change the database. *This is the real weakness.* Write the rotation runbook **before** you need it — that is the actual deliverable of this challenge.

---

## C8.5 — Make the 502 impossible

```bash
docker compose up -d
docker compose up -d --force-recreate api
curl -i localhost:8080/items          # 502 for a while, until nginx is reloaded
docker compose logs proxy | tail -3   # "connect() failed ... no live upstreams"
```

| Approach | How | Cost |
|---|---|---|
| **1. `resolver` + variable** | `resolver 127.0.0.11 valid=10s; set $u api; proxy_pass http://$u:8000;` | **Loses the `upstream` block**, so no keepalive to the backend and no `least_conn` — Docker's DNS round-robins instead. Also up to `valid=` seconds of staleness |
| **2. HAProxy instead** | `server api1 api:8000 check resolvers docker` with a `resolvers` section | Proper health checks, real balancing algorithms, a stats page. One more component to run and learn |
| **3. Reload nginx on change** | a sidecar watching `docker events` that runs `nginx -s reload` | Keeps `upstream` and keepalive; adds a moving part that can itself fail, and needs the Docker socket — which is root on the host |

**What I would use, and why:** for a dev stack, **(1)** — it is three lines, has no extra components, and the keepalive loss is irrelevant at dev traffic. For anything real, **(2)**: you want health checks that remove a *sick but running* backend, and DNS round-robin cannot do that. **(3)** is clever and I would avoid it: mounting the Docker socket to solve a load-balancing problem trades a small problem for a root-equivalent attack surface.

**The honest answer, though, is that all three are workarounds for using the wrong tool.** Service discovery that survives rescheduling is exactly what an orchestrator provides. Week 10's Swarm routing mesh makes this failure mode structurally impossible, and that is a better reason to adopt Swarm than any feature list.

---

## C8.4 — Backup and restore

```bash
#!/usr/bin/env bash
# backup.sh - logical backup of the stack database
set -euo pipefail
DEST=${1:-./backups}
mkdir -p "$DEST"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$DEST/appdb-$STAMP.sql.gz"

# pg_dump, NOT a copy of the volume directory. Copying a live data directory
# gives you a torn, unrecoverable snapshot - the database is mid-write.
docker compose exec -T db pg_dump -U postgres -d appdb --clean --if-exists \
  | gzip > "$OUT"

# VERIFY. An unverified backup is a hope. (Week 3's lesson, again.)
gzip -t "$OUT"
[[ $(gzip -dc "$OUT" | wc -l) -gt 5 ]] || { echo "backup looks empty" >&2; exit 1; }
sha256sum "$OUT" > "$OUT.sha256"
echo "$OUT"
```

```bash
#!/usr/bin/env bash
# restore.sh
set -euo pipefail
SRC=${1:?usage: restore.sh <backup.sql.gz>}
sha256sum -c "$SRC.sha256"                  # verify BEFORE touching the database
gzip -dc "$SRC" | docker compose exec -T db psql -U postgres -d appdb
```

**The drill — and the drill is the deliverable, not the scripts:**

```bash
docker compose exec -T db psql -U postgres -d appdb -c \
  "CREATE TABLE canary(id int primary key, v text); INSERT INTO canary VALUES (1,'before');"
./backup.sh
docker compose down -v                       # everything is gone
docker compose up -d && sleep 15
time ./restore.sh backups/appdb-*.sql.gz
docker compose exec -T db psql -U postgres -d appdb -c "SELECT * FROM canary;"
```

**Two things people get wrong here.** First, backing up the *volume directory* instead of using `pg_dump` — a file-level copy of a running database is torn and often unrestorable; you need `pg_dump`, or a filesystem snapshot combined with `pg_start_backup`. Second, never actually restoring. **Your RTO is not the number in the plan; it is the number you measured.** Measure it, write it down, and re-measure after any change to the stack.

---

## C8.2 — Migrations that run exactly once

```yaml
migrate:
  image: lab/stack-api:${APP_VERSION:-1.0}
  command: ["python", "-m", "app.migrate"]
  depends_on:
    db: { condition: service_healthy }
  restart: "no"

api:
  depends_on:
    migrate: { condition: service_completed_successfully }
```

**Does it run three times with `--scale api=3`?** No. `migrate` is its own service with one container; all three API replicas wait on the same completion. Compose runs it once.

**What happens in Swarm?** There is no `service_completed_successfully` — Swarm has no dependency conditions at all. Services start in parallel and are restarted independently. So this pattern **does not port**, and that surprises people migrating from Compose.

The Swarm-era answers, in order of robustness:

1. **Make migrations idempotent and run them from CI**, as a deploy step before the service update. This is what most teams do.
2. **Run them in the application's startup path, guarded by an advisory lock** — `SELECT pg_advisory_lock(...)` — so whichever replica wins runs them and the others wait. This survives replicas starting simultaneously, which they will.
3. Use a one-shot `docker service create --restart-condition none` job, and check it completed before updating the app.

**The deeper lesson: "run this exactly once, before everything else" is a genuinely hard problem in a distributed system**, and Compose's clean solution exists only because Compose is single-host and single-threaded. Recognising which of your conveniences depend on that assumption is the main intellectual work of moving to Week 10.

---

## C8.7 — The memo

> **Subject: the stack has outgrown Compose**
>
> Compose has served us well and I am not proposing we abandon it for local development — it should stay exactly as it is for that. But for the production instance, we are now relying on it for things it does not do, and I want to name the specific scenarios rather than argue in generalities.
>
> **1. The host is a single point of failure.** If `prod-01` reboots, we are down for the length of that reboot. Compose has no concept of another machine. Our last kernel patch was nine minutes of full outage.
>
> **2. Deployments are an outage.** `docker compose up -d` stops the old container and starts the new one. There is a gap, it is measured in seconds, and every in-flight request dies in it. We currently deploy at 06:00 to hide this, which is a workaround, not a solution.
>
> **3. A crashed container is restarted; a crashed *host* is not.** `restart: always` covers the process. Nothing covers the machine.
>
> **4. We cannot scale a service that publishes a port.** We hit this last month: `--scale api=3` fails with "port is already allocated", so our only scaling axis is a bigger box.
>
> **5. Load balancing is DNS round-robin and does not health-check.** A replica that is running but sick keeps receiving traffic until someone notices. We have already had one incident from this.
>
> **6. Secrets are plaintext files on one host**, readable by anyone in the `docker` group, with a manual rotation process that — as we found — does not actually rotate an initialised database.
>
> **What I propose:** Docker Swarm on three small nodes. It reads a superset of the file format we already have, so the migration is mostly `deploy:` blocks and a `docker stack deploy` instead of `docker compose up`. It gives us rolling updates with automatic rollback, rescheduling when a node dies, encrypted secrets, and a routing mesh with real health checking.
>
> **The honest cost:** roughly a week of work, a new failure mode to learn (overlay networking), the loss of `depends_on` conditions — which means our migration step has to move into CI or behind an advisory lock — and three machines to patch instead of one. Kubernetes would give us more and cost several months; I do not think we are near needing it.
>
> **What I am NOT claiming:** that this makes us highly available. Our database is still one instance on one node, and that is the next conversation.

**Why this memo works:** every claim is a *scenario with a consequence we have already experienced*, the cost is stated honestly including a real loss of functionality, and it explicitly names what the change does **not** buy. A migration proposal that only lists benefits gets ignored by anyone experienced — and the last paragraph is the one that earns you credibility.
