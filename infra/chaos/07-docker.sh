#!/usr/bin/env bash
# DRILL 07 - "the container keeps restarting".  Week 07.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
command -v docker >/dev/null || { echo "this drill needs a docker node"; exit 1; }

install -d -m 0755 /opt/lab/drill07
cd /opt/lab/drill07

# Fault 3 lives in app.py: it refuses to start without APP_SECRET and writes the
# reason to STDERR before exiting 1 - which is exactly where `docker logs` looks.
# The explanation stays out here, because app.py is COPYed into the image and
# left in /opt/lab/drill07: a comment inside the heredoc ships to the learner.
cat > app.py <<'INNER'
import os, sys, http.server, socketserver
secret = os.environ.get("APP_SECRET")
if not secret:
    print("FATAL: APP_SECRET is not set", file=sys.stderr)
    sys.exit(1)
port = int(os.environ.get("PORT", "8000"))
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok\n")
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("0.0.0.0", port), H) as s: s.serve_forever()
INNER

# Fault 2: the HEALTHCHECK below probes port 8080 while the app serves 8000.
# Same rule - the Dockerfile lands on the box, so it carries no annotation.
cat > Dockerfile <<'INNER'
FROM python:3.12-alpine
WORKDIR /app
COPY app.py .
HEALTHCHECK --interval=5s --timeout=2s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/ || exit 1
CMD ["python", "app.py"]
INNER

docker build -q -t lab/drill07:latest . >/dev/null

docker rm -f drill07 >/dev/null 2>&1 || true
# Fault 1: restart:always hides the crash loop from anyone who only runs
# `docker ps` - the container looks like it exists and is "Up 2 seconds",
# forever. And APP_SECRET is deliberately not passed.
docker run -d --name drill07 --restart always -p 8000:8000 lab/drill07:latest >/dev/null
sleep 6

base64 -w0 > /root/.drill-07-docker <<'NOTE'
THREE FAULTS, in the order you should find them:
1. THE CRASH: the container exits 1 immediately because APP_SECRET is unset.
   `docker ps` shows it "Up 3 seconds" over and over because --restart always
   keeps resurrecting it. The tells:
     docker ps -a           -> RESTARTS column climbing
     docker logs drill07    -> "FATAL: APP_SECRET is not set"
     docker inspect drill07 --format '{{.State.ExitCode}} {{.RestartCount}}'
   FIX: docker run -e APP_SECRET=... (in week 8, a Compose env_file or a secret)
2. THE HEALTHCHECK LIES: the Dockerfile HEALTHCHECK probes :8080 while the app
   serves :8000, so even once it starts the container reports "unhealthy".
   `docker inspect --format '{{json .State.Health}}' drill07 | jq` shows the
   failing probe output. A healthcheck that tests the wrong thing is worse than
   none, because it destroys trust in every other healthcheck you write.
3. NOTHING RESTARTS IT WHEN "UNHEALTHY": plain `docker run` does not act on
   health status - only Swarm (week 10) reschedules unhealthy tasks. Knowing
   which layer reacts to what is the point.
LESSON: `docker ps` is not evidence. `docker ps -a`, the RestartCount, and
        `docker logs` are. An app that exits on a missing variable is CORRECT -
        fail fast and loudly beats starting half-configured.
NOTE
chmod 0600 /root/.drill-07-docker

cat <<'MSG'

  SYMPTOM REPORTED BY THE USER
  ----------------------------
  "I deployed the drill07 container. `docker ps` shows it running, but
   curl http://localhost:8000/ gives 'Connection reset by peer' or refuses.
   Every time I look at docker ps the uptime has reset to a few seconds."

  Reproduce it:   docker ps
                  curl -m3 -i http://localhost:8000/ ; echo "exit=$?"

MSG
