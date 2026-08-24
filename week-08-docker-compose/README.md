# Week 08 — Docker Compose

**VM profile:** `make w08-up` → `dock`
**You will be able to:** define a multi-service system in one file, start it reproducibly, and debug the class of failure that only appears when services depend on each other.

> Week 7 was one container. Real systems are six, and the interesting failures live **between** them: startup ordering, name resolution, credentials that must match on both sides, and a dependency that is "up" but not yet *ready*.

---

## Day 1 — The Compose model

### 1.1 What Compose is and is not

Compose is a **declarative description of a set of containers**, plus a CLI that makes reality match the description. It is not an orchestrator: it runs on one host, it does not reschedule after a node failure, and it has no rolling updates. That is Week 10.

It is, however, the right tool for local development, CI environments, and small single-host deployments — and its file format is the direct ancestor of the Swarm stack file, so nothing you learn here is wasted.

### 1.2 The file

```yaml
services:
  api:
    build: ./api                 # build from a Dockerfile...
    image: lab/api:1.0           # ...and tag the result
    environment:
      DB_HOST: db                # ← "db" is a DNS NAME, resolved by Compose's network
    env_file: [.env]
    ports: ["127.0.0.1:8080:8000"]
    depends_on:
      db: { condition: service_healthy }
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8000/health')"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 10s
    deploy:
      resources:
        limits: { memory: 256M, cpus: "0.5" }

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set}
    volumes: ["dbdata:/var/lib/postgresql/data"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      retries: 5

volumes:
  dbdata:
networks:
  default:
    name: labnet
```

> The `version:` key at the top is **obsolete** and Compose v2 warns about it. Delete it if you see it in an old file.

### 1.3 The commands

```bash
docker compose up -d              # create/start everything
docker compose ps                 # status of this project's services
docker compose logs -f api        # follow one service
docker compose exec api sh
docker compose restart api
docker compose down               # stop and remove containers + networks
docker compose down -v            # ...AND VOLUMES. This deletes your data.
docker compose config             # ← the RESOLVED config. Use this constantly.
docker compose build --no-cache api
docker compose pull
```

**`docker compose config` is the most underused command here.** It prints the file after variable substitution, `env_file` merging and override composition — that is, **what the containers will actually receive**, which is frequently not what you think you wrote. When debugging anything configuration-shaped, look at this before you look at the YAML.

### 1.4 Service names are DNS names

Compose creates a user-defined bridge network (Week 7 §3.2), so every service is reachable from every other by its **service name**. `DB_HOST: db` works because Docker's embedded DNS resolves `db` to that container's IP.

Two consequences:
- You never need to know container IPs, and you must never hard-code them.
- **`localhost` inside a container means that container**, not the host and not another service. `DB_HOST: localhost` in the API container means "connect to Postgres inside the API container", which fails with connection refused. This mistake is made by everyone exactly once.

---

## Day 2 — Startup ordering, the real problem

### 2.1 `depends_on` alone does almost nothing

```yaml
depends_on: [db]                 # waits for the CONTAINER to start. That is all.
```

Postgres's container starts in about 200 ms and is ready to accept connections some seconds later. `depends_on` in its plain form returns as soon as the container exists, so your API connects to a database that is not listening yet, gets a connection error, and — depending on how it is written — either crashes or caches a failure forever.

### 2.2 The fix, in two halves

**Half one — declare the readiness condition:**

```yaml
db:
  healthcheck:
    test: ["CMD-SHELL", "pg_isready -U postgres -d appdb"]
    interval: 5s
    timeout: 3s
    retries: 5
    start_period: 10s

api:
  depends_on:
    db:
      condition: service_healthy      # now it genuinely waits for READY
```

**Half two — and this is the half people skip — retry in the application anyway:**

```python
for attempt in range(30):
    try:
        conn = connect(); break
    except OperationalError:
        time.sleep(min(2 ** attempt, 10))
```

Why both? Because `condition: service_healthy` only governs **startup**. In production, the database will restart, fail over, or blip at 3am while your API has been running for a month, and no orchestrator will restart your API to help. **An application that cannot reconnect to its dependencies is broken regardless of how carefully it was started.** Compose's condition makes local development pleasant; the retry loop makes the service correct.

### 2.3 `condition:` values

| Condition | Waits until |
|---|---|
| `service_started` | the container is running (the weak default) |
| `service_healthy` | its healthcheck passes |
| `service_completed_successfully` | it ran and exited 0 — for migrations and seeders |

That third one is how you run database migrations before the API starts:

```yaml
migrate:
  image: lab/api:1.0
  command: ["python", "-m", "app.migrate"]
  depends_on: { db: { condition: service_healthy } }
  restart: "no"

api:
  depends_on:
    migrate: { condition: service_completed_successfully }
```

---

## Day 3 — Configuration and secrets

### 3.1 The layers, and their precedence

Highest wins:

1. `docker compose run -e VAR=...` on the command line
2. `environment:` in the compose file
3. `env_file:`
4. the shell environment Compose itself was launched with
5. a `.env` file in the project directory
6. `ENV` baked into the image

**A `.env` file next to `docker-compose.yml` is special**: Compose reads it for **variable substitution in the YAML itself** (`${POSTGRES_PASSWORD}`), which is different from `env_file:`, which passes variables **into a container**. Confusing the two is common. `docker compose config` shows you which happened.

### 3.2 Required variables

```yaml
environment:
  POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set}
  LOG_LEVEL: ${LOG_LEVEL:-info}
```

`:?` makes Compose refuse to start with a clear message. `:-` supplies a default. Use `:?` for anything without a safe default — **failing at `compose up` is enormously better than starting a service with an empty password.**

### 3.3 The Postgres password trap

This one catches nearly everyone, and it is fault #1 in this week's drill:

> **`POSTGRES_PASSWORD` is read only when the data directory is EMPTY** — that is, on the very first start. Changing it later has no effect whatsoever: the database already has its password stored inside the volume.

So you change the password in `.env`, run `docker compose up -d --force-recreate`, and get authentication failures — because the *application* now sends the new password while the *database* still expects the old one. The fixes are: use the old password, `ALTER USER` inside psql, or `docker compose down -v` to delete the volume (**and all your data**).

The same pattern applies to MySQL, MongoDB and most stateful images. **Initialisation variables apply to initialisation only.**

### 3.4 Secrets

`environment:` is visible in `docker inspect`, in `ps` output on the host, and often in logs. For real secrets, Compose supports file-based secrets:

```yaml
services:
  api:
    secrets: [db_password]
    environment:
      DB_PASSWORD_FILE: /run/secrets/db_password    # the app reads the FILE

secrets:
  db_password:
    file: ./secrets/db_password.txt                 # gitignored
```

The `_FILE` convention — pass a path, not a value — is supported by Postgres, MySQL and many official images, and it is what Swarm secrets (Week 10) use natively.

---

## Day 4 — Overrides, profiles, and operating the stack

### 4.1 Override files

`docker compose up` automatically merges `docker-compose.yml` with `docker-compose.override.yml`. That is the standard dev/prod split:

```yaml
# docker-compose.yml           — the shared truth
# docker-compose.override.yml  — dev: bind-mount source, expose ports, debug logging
# docker-compose.prod.yml      — prod: no mounts, resource limits, restart policies
```

```bash
docker compose up -d                                        # base + override (dev)
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d   # explicit
```

> Merge semantics are worth knowing: **scalars are replaced, lists are replaced (not appended), maps are merged.** So an override with one `ports:` entry replaces the whole list. `docker compose config` resolves the argument.

### 4.2 Profiles

```yaml
services:
  api: {}
  seed:
    profiles: ["tools"]        # only runs when asked for
```

```bash
docker compose up -d                        # api only
docker compose --profile tools up -d        # api + seed
```

### 4.3 Scaling on one host

```bash
docker compose up -d --scale worker=4
```

Works for stateless workers. It does **not** work for anything with a fixed published port — three containers cannot all bind host port 8080. That is exactly the problem Swarm's routing mesh solves in Week 10.

### 4.4 Debugging a stack

```bash
docker compose ps                          # what is up, and health status
docker compose logs --tail=100 -f          # ALL services, interleaved, timestamped
docker compose logs api | grep -i error
docker compose config                      # the resolved truth
docker compose exec api sh
docker compose exec api ping db            # is service DNS working?
docker compose exec api env | grep DB_     # what did this container ACTUALLY get?
docker compose top
docker compose events
```

**The diagnostic order for "the API returns 500":**

1. `docker compose ps` — is everything up **and healthy**? (Up ≠ working.)
2. `docker compose logs api` — what does the *application* say? A 500 means the app threw.
3. `docker compose logs db` — did the dependency reject it?
4. `docker compose exec api env` — does it have the configuration you think?
5. `docker compose exec api ping db` — can it even resolve the dependency?
6. `docker compose config` — is the file saying what you think it says?

Step 4 catches more bugs than any other, and almost nobody runs it.

---

## Day 5 — Drill

```bash
cd infra
make snapshot VM=dock NAME=pre-w08
make break VM=dock DRILL=08-compose
```

Symptom: *"Every container shows Up, the API answers on :8080, and every request returns 500. It worked before the weekend."*

## Recommended reading

- Compose specification — <https://github.com/compose-spec/compose-spec/blob/master/spec.md>
- Docker Compose docs — <https://docs.docker.com/compose/>
- Awesome Compose (real examples) — <https://github.com/docker/awesome-compose>
- *Twelve-Factor App* — <https://12factor.net/> — especially III (Config) and IX (Disposability)
