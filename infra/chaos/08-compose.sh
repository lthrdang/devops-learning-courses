#!/usr/bin/env bash
# DRILL 08 - "the API starts but every request returns 500".  Week 08.
# Assumes the week-08 stack is deployed at /opt/lab/stack.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
STACK=${STACK:-/opt/lab/stack}
[[ -d "$STACK" ]] || { echo "deploy the week-08 stack into $STACK first"; exit 1; }
cd "$STACK"

# --- the damage ---
# Fault 1: the API's DB password no longer matches Postgres'. Note we change it
# in the API's env only, so `docker compose config` looks internally consistent.
if [[ -f .env ]]; then
  cp .env .env.drill-backup
  python3 - <<'PY'
import re, pathlib
p = pathlib.Path(".env"); s = p.read_text()
s = re.sub(r'^POSTGRES_PASSWORD=.*$', 'POSTGRES_PASSWORD=labpass', s, flags=re.M)
s = re.sub(r'^API_DB_PASSWORD=.*$',  'API_DB_PASSWORD=labpassword', s, flags=re.M)
p.write_text(s)
PY
fi

# Fault 2: depends_on without a condition. The API starts before Postgres is
# accepting connections; on a slow boot it connects, caches a failure and never
# retries. Remove the healthcheck condition if the learner wrote one.
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
CAUSE 1 (the 500s): POSTGRES_PASSWORD and API_DB_PASSWORD in .env no longer
match, so every query fails authentication. The API process itself is healthy,
which is why the container is "Up" and only the REQUESTS fail.
  Detect: docker compose logs api | tail -30
            -> "password authentication failed for user ..."
          docker compose logs db | grep -i fatal
          docker compose config      # renders the fully resolved config - use
                                     # this, not the raw yaml, to see what the
                                     # containers actually received
  Fix: make the two values equal, then `docker compose up -d --force-recreate`.
       NOTE: changing POSTGRES_PASSWORD alone does NOT change the password of an
       already-initialised database - that variable is only read on FIRST init
       of an empty data volume. You must either use the old password, or
       ALTER USER inside psql, or delete the volume. This trips up nearly
       everyone the first time.
CAUSE 2 (why it is flaky on restart): depends_on uses `condition: service_started`
instead of `service_healthy`, so the API can start before Postgres is ready to
accept connections. depends_on alone waits for the CONTAINER, never for the
APPLICATION inside it.
  Fix: give db a healthcheck (pg_isready) and depend on service_healthy - and
       ALSO add retry-with-backoff in the app, because orchestrators restart
       things at arbitrary times and a healthy start is not a guarantee forever.
RESTORE: cp .env.drill-backup .env
LESSON: "container Up" != "application working". Read the app's own logs, and
        remember that a database's init variables apply only to an empty volume.
NOTE
chmod 0600 /root/.drill-08-compose

cat <<'MSG'

  SYMPTOM REPORTED BY THE USER
  ----------------------------
  "All containers show Up in `docker compose ps`, and the API answers on :8080,
   but every single request returns HTTP 500. It worked before the weekend."

  Reproduce it:   docker compose ps
                  curl -i http://localhost:8080/items

MSG
