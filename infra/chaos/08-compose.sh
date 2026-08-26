#!/usr/bin/env bash
# DRILL 08 - "everything is healthy, but the migration job fails to log in".
# Week 08.  Assumes the week-08 stack is deployed at /opt/lab/w08/stack.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
# Default matches where lab.md 1.1 tells you to put the stack. Override with
# STACK=/somewhere/else if you deployed it elsewhere.
STACK=${STACK:-/opt/lab/w08/stack}
[[ -d "$STACK" ]] || { echo "deploy the week-08 stack into $STACK first"; exit 1; }
cd "$STACK"

SECRET=secrets/db_password.txt
[[ -f $SECRET ]] || { echo "no $SECRET - run 'make init' in $STACK first"; exit 1; }

# --- the damage ---
# Fault 1: ROTATE THE SECRET FILE WITHOUT ROTATING THE DATABASE.
#
# Both services mount the SAME secret, so after this the API and every client
# read the NEW password - but POSTGRES_PASSWORD_FILE is consumed only on the
# FIRST init of an empty data directory. The database already exists in the
# dbdata volume, so it keeps the OLD password forever. That asymmetry is the
# entire lesson, and it is exactly what a half-finished credential rotation
# looks like in production.
#
# Keep the pristine copy under /root, not beside the stack: a file called
# db_password.txt.drill-backup sitting in secrets/ tells the learner which file
# was tampered with before they have looked at a single log line.
cp "$SECRET" /root/.drill-08-secret.bak
chmod 0600 /root/.drill-08-secret.bak
openssl rand -base64 24 | tr -d '\n' > "$SECRET"
# 0644 deliberately - see the Makefile's init target. A compose `file:` secret
# is a bind mount, so the container sees this mode verbatim and the API runs as
# uid 10001. Writing 0600 here would give the learner a PermissionError crash
# loop instead of the credential drift this drill is actually about.
chmod 0644 "$SECRET"

# Fault 2: depends_on without a condition. The API starts before Postgres is
# accepting connections. This one is about STARTUP ORDER, not credentials -
# it is here so the learner has to separate two independent faults.
python3 - <<'PY'
import pathlib, re
for name in ("docker-compose.yml", "compose.yaml", "docker-compose.yaml"):
    p = pathlib.Path(name)
    if p.exists():
        s = p.read_text()
        s = re.sub(r'condition:\s*service_healthy', 'condition: service_started', s)
        p.write_text(s)
        break
PY

docker compose up -d --force-recreate >/dev/null 2>&1 || true
sleep 5

base64 -w0 > /root/.drill-08-compose <<'NOTE'
FIRST, THE THING THAT MAKES THIS DRILL HARD: the stack is genuinely healthy.
`docker compose ps` shows healthy, `curl localhost:8080/items` returns 200, and
NOTHING in the API logs is wrong. That is not a red herring - it is a true fact
about this system, and you have to understand WHY it is true before the real
fault is findable.
  This API's readiness probe (app.py:tcp_probe) opens a TCP socket to db:5432
  and stops there. It never authenticates and it never runs a query. So
  /health, /ready and the container's HEALTHCHECK all prove exactly one thing:
  the port is open. A healthcheck can only tell you about the code path it
  actually exercises. This one does not exercise credentials, so it cannot
  fail on credentials.
  The only component in the stack that really logs in is the `seed` job, which
  is why the nightly migration is the thing that broke.

CAUSE 1 (the auth failures): secrets/db_password.txt was rotated, but the
DATABASE was not. Both services mount that same file, so the API and psql now
send the new password while Postgres still has the old one stored in its
dbdata volume. POSTGRES_PASSWORD / POSTGRES_PASSWORD_FILE is read ONLY on the
first init of an EMPTY data directory - rewriting it later changes nothing
about an existing database. This trips up nearly everyone the first time.
  Detect: docker compose --profile tools run --rm seed
            -> 'psql: error: ... password authentication failed for user "postgres"'
          docker compose logs db | grep -i 'password authentication failed'
          docker compose config      # renders the fully resolved config - use
                                     # this, not the raw yaml, to see what the
                                     # containers actually received
          ls -l secrets/db_password.txt     # mtime: changed on Friday
  Fix, three ways, and the cost of each:
    (a) put the OLD value back                     -> zero data loss, instant
          sudo cp /root/.drill-08-secret.bak secrets/db_password.txt
          sudo chmod 0644 secrets/db_password.txt
          docker compose up -d --force-recreate
    (b) change the password INSIDE the database    -> zero data loss, correct
          docker compose exec db psql -U postgres \
            -c "ALTER USER postgres PASSWORD '$(cat secrets/db_password.txt)';"
          docker compose restart api
    (c) delete the volume and re-init              -> THE DATABASE IS GONE
  (b) is the real rotation procedure. Write it down BEFORE you need it.

CAUSE 2 (an independent second fault): depends_on uses `condition:
service_started` instead of `service_healthy`, so the API can start before
Postgres is ready to accept connections. depends_on alone waits for the
CONTAINER, never for the APPLICATION inside it. Here the app's
connect_with_retry() masks it - which is the point: retry logic is what turns
a startup-order bug into a non-event.
  Fix: give db a healthcheck (pg_isready) and depend on service_healthy - and
       ALSO keep retry-with-backoff in the app, because orchestrators restart
       things at arbitrary times and a healthy start is not a guarantee forever.

RESTORE: sudo cp /root/.drill-08-secret.bak /opt/lab/w08/stack/secrets/db_password.txt
         sudo chmod 0644 /opt/lab/w08/stack/secrets/db_password.txt
         (adjust the path if you deployed the stack somewhere other than
         $STACK's default, and revert service_started -> service_healthy)

LESSON: "healthy" only means "the checks I wrote passed". A healthcheck that
        does not exercise a dependency cannot detect a broken one, and a
        database's init variables apply only to an empty volume.
NOTE
chmod 0600 /root/.drill-08-compose

cat <<'MSG'

  SYMPTOM REPORTED BY THE USER
  ----------------------------
  "Everything looks fine - all containers Up and healthy, and the site works,
   curl on :8080 returns 200. But our nightly migration job has failed every
   night since the weekend with 'password authentication failed for user
   postgres', and I can't psql into the database with the password in
   secrets/db_password.txt any more either."

  Reproduce it:   docker compose ps
                  curl -i http://localhost:8080/items
                  docker compose --profile tools run --rm seed

MSG
