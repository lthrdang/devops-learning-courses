# Week 07 — Solutions & discussion

---

## C7.2 — The nine mistakes in `Dockerfile.bad`

```dockerfile
FROM python:latest                                    # 1
RUN apt-get update                                    # 2, 3
RUN apt-get install -y curl vim git build-essential   # 2, 3, 4
WORKDIR /app
COPY . .                                              # 5
RUN pip install -r requirements.txt                   # 6
ENV APP_SECRET=supersecret123                         # 7
EXPOSE 8000
CMD python app.py                                     # 8, 9
```

| # | Mistake | Consequence | Catch it with |
|---|---|---|---|
| 1 | `python:latest` — unpinned | the image changes under you; a build that worked yesterday breaks today and you cannot reproduce last week's artefact | `hadolint` DL3006; a CI policy requiring digests or explicit tags |
| 2 | `apt-get update` in a **separate** `RUN` from `install` | the update layer is cached while the install layer is not, so you install from a stale index — the classic Docker caching bug | `hadolint` DL3009 |
| 3 | no `rm -rf /var/lib/apt/lists/*` | ~40 MB of package index shipped in the image forever | `hadolint` DL3009 |
| 4 | `vim`, `git`, `build-essential` in the runtime image | ~1.5 GB and an enormous attack surface: a compiler and a shell for anyone who gets code execution | `trivy`; an image-size budget in CI |
| 5 | `COPY . .` with no `.dockerignore` | ships `.git`, `.venv`, `.env`. **Secrets leak here constantly** | require `.dockerignore`; scan images for credentials |
| 6 | `pip install` **after** `COPY . .`, and no `--no-cache-dir` | every source change reinstalls all dependencies; pip's cache adds tens of MB | `hadolint` DL3042 |
| 7 | `ENV APP_SECRET=...` | **the secret is permanently in the image metadata.** Anyone who can pull the image can read it with `docker inspect` — no running container required | `trivy`, `gitleaks`, image-scanning in CI |
| 8 | shell form `CMD` | `/bin/sh` becomes PID 1, does not forward `SIGTERM`, so the app is `SIGKILL`ed after the grace period; in-flight requests die | `hadolint` DL3025 |
| 9 | no `USER` | runs as **root**; combined with a volume mount that is host root | `hadolint` DL3002; a runtime admission policy |

**Measured results:**

```
lab/app:1.0   203MB     runs as uid 10001, no secret in metadata, graceful stop
lab/app:bad   1.74GB    runs as root, secret readable via docker inspect, SIGKILLed
```

And the leak, demonstrated without running anything:

```bash
$ docker inspect lab/app:bad --format '{{json .Config.Env}}' | jq
[ "APP_SECRET=supersecret123", ... ]
```

**The CI gate that catches most of this in one line:**

```bash
docker run --rm -i hadolint/hadolint < Dockerfile && \
trivy image --exit-code 1 --severity HIGH,CRITICAL myimage:tag
```

---

## C7.1 — Shrink it

| Step | Size | What it bought |
|---|---|---|
| `python:3.12-slim` baseline | 203 MB | — |
| Multi-stage, copy only site-packages | ~180 MB | drops pip/setuptools/wheel |
| `python:3.12-alpine` | ~65 MB | musl + a much smaller base |
| Distroless Python | ~55 MB | no shell, no package manager |

```dockerfile
FROM python:3.12-alpine AS build
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --target=/deps -r requirements.txt

FROM python:3.12-alpine
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PYTHONPATH=/deps
WORKDIR /app
COPY --from=build /deps /deps
COPY app.py .
RUN adduser -S -u 10001 appuser && mkdir -p /data && chown appuser /data
USER appuser
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request,sys;sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=2).status==200 else 1)"
CMD ["python", "app.py"]
```

**The honest Alpine result with a compiled dependency:**

```bash
# slim:   pip downloads a manylinux wheel        -> ~15 seconds
# alpine: no musl wheel exists, so it COMPILES   -> 4-9 minutes,
#         needs gcc/musl-dev/libffi-dev/openssl-dev added,
#         and the final image is often LARGER than slim
```

**The lesson, which is the actual point of the challenge:** "Alpine is smaller" is true for the base layer and frequently false for the finished image. Alpine is excellent for Go and Rust static binaries. For Python with compiled extensions, `slim` is usually both smaller and vastly faster to build. **Measure, do not assume** — and note that a 4-minute CI build, run 40 times a day, costs your team more than 130 MB of registry storage ever will.

---

## C7.3 — The forensics kit

```bash
#!/usr/bin/env bash
set -uo pipefail       # not -e: gather everything even when a step fails
C=${1:?usage: dbg.sh CONTAINER}

hr() { printf '\n== %s ==\n' "$1"; }

hr "STATE"
docker inspect "$C" --format '
status:       {{.State.Status}}
exit code:    {{.State.ExitCode}}
error:        {{.State.Error}}
OOM killed:   {{.State.OOMKilled}}
restarts:     {{.RestartCount}}
started:      {{.State.StartedAt}}
finished:     {{.State.FinishedAt}}'

hr "WHY IT EXITED"
code=$(docker inspect "$C" --format '{{.State.ExitCode}}')
case "$code" in
  0)   echo "clean exit - for a server this usually means it found no work to do" ;;
  1)   echo "application error - READ THE LOGS BELOW" ;;
  126) echo "command found but not executable - check the +x bit on your entrypoint" ;;
  127) echo "COMMAND NOT FOUND - wrong path, or the shell does not exist in this image" ;;
  137) echo "SIGKILL (128+9) - check OOMKilled above; if false, something sent kill -9" ;;
  139) echo "SIGSEGV (128+11) - a segfault in the application" ;;
  143) echo "SIGTERM (128+15) - a normal docker stop" ;;
  *)   echo "exit ${code}" ;;
esac

hr "LOGS (last 100)"
docker logs --tail 100 --timestamps "$C" 2>&1

hr "EFFECTIVE CONFIG"
docker inspect "$C" --format '
image:        {{.Config.Image}}
entrypoint:   {{json .Config.Entrypoint}}
cmd:          {{json .Config.Cmd}}
user:         {{if .Config.User}}{{.Config.User}}{{else}}root (NOT SET){{end}}
workdir:      {{.Config.WorkingDir}}'

hr "ENVIRONMENT (redacted)"
# Never dump raw env in a bug report - it is where the credentials are.
docker inspect "$C" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sed -E 's/(SECRET|TOKEN|PASSWORD|KEY|CREDENTIAL)[^=]*=.*/\1***REDACTED***/I'

hr "MOUNTS"
docker inspect "$C" --format '{{range .Mounts}}{{.Type}} {{.Source}} -> {{.Destination}} rw={{.RW}}{{println}}{{end}}'

hr "HEALTH"
docker inspect "$C" --format '{{if .State.Health}}{{.State.Health.Status}} failing={{.State.Health.FailingStreak}}{{else}}no healthcheck defined{{end}}'
docker inspect "$C" --format '{{if .State.Health}}{{range .State.Health.Log}}--- exit={{.ExitCode}}
{{.Output}}{{end}}{{end}}' 2>/dev/null | tail -20

hr "LIMITS vs USAGE"
docker inspect "$C" --format 'memory limit: {{.HostConfig.Memory}} bytes ({{if eq .HostConfig.Memory 0}}UNLIMITED - one leak takes the host down{{else}}set{{end}})
cpu quota:    {{.HostConfig.CpuQuota}}
pids limit:   {{.HostConfig.PidsLimit}}'
docker stats --no-stream "$C" 2>/dev/null || echo "(not running)"

hr "IMAGE LAYERS"
docker history "$(docker inspect "$C" --format '{{.Config.Image}}')" | head -15

hr "DAEMON EVENTS"
docker events --since 30m --until 0s --filter "container=$C" 2>/dev/null | tail -20
```

**The two details that make it a *good* tool rather than a dump:** it **redacts secrets** (a debug bundle pasted into a ticket is a credential leak), and it **interprets the exit code** rather than printing it. A tool that tells you "137, check OOMKilled" instead of "137" has done the thinking once so nobody has to do it again at 3am.

---

## C7.6 — Layer archaeology

```dockerfile
FROM alpine
COPY secret.txt /tmp/secret.txt
RUN rm /tmp/secret.txt          # this does NOT remove it from the image
CMD ["sh"]
```

```bash
echo "hunter2-the-real-password" > secret.txt
docker build -t leaky .
docker run --rm leaky cat /tmp/secret.txt      # "No such file" - it looks gone

docker save leaky -o leaky.tar
mkdir -p x && tar -xf leaky.tar -C x
# each layer is its own tar; find the one containing the file
for l in x/blobs/sha256/*; do
  tar -tf "$l" 2>/dev/null | grep -q 'secret.txt' && echo "FOUND in $l"
done
tar -xOf x/blobs/sha256/<that-one> tmp/secret.txt      # the secret, in plaintext
```

**Why:** layers are **additive only**. `rm` in a later layer writes a *whiteout* marker that hides the file at runtime; the bytes remain in the earlier layer and travel with the image to every registry and every machine that pulls it. `docker history` even shows you which instruction to look at.

**The two-sentence team rule:**

> A secret that enters any layer of an image is permanently in that image, regardless of whether a later layer deletes it — anyone who can pull the image can extract it without ever running it. Secrets reach containers at **run** time (environment from a secret store, a mounted file, or BuildKit's `--mount=type=secret`), never at build time.

BuildKit's build-time secrets do this correctly, because the mount exists only during that `RUN` and is never committed to a layer:

```dockerfile
# syntax=docker/dockerfile:1
RUN --mount=type=secret,id=npmtoken \
    NPM_TOKEN=$(cat /run/secrets/npmtoken) npm install
```

---

## C7.5 — Signals, properly

```python
import threading, socketserver

class GracefulServer(ThreadingHTTPServer):
    daemon_threads = False          # WAIT for request threads on shutdown

def on_term(signum, frame):
    global SHUTTING_DOWN
    SHUTTING_DOWN = True
    log("info", "SIGTERM: draining")

    # 1. Report unhealthy FIRST, so the load balancer stops sending new work.
    #    This is week 5's "drain before you stop", now inside the app.
    grace = float(os.environ.get("DRAIN_SECONDS", "5"))
    time.sleep(grace)

    # 2. Stop accepting, then let in-flight threads finish.
    #    shutdown() must run on another thread - it blocks until serve_forever
    #    returns, and we are currently INSIDE the signal handler.
    threading.Thread(target=server.shutdown, daemon=True).start()
```

```bash
# Proof: hold a slow request open across a docker stop.
docker run -d --name g -e APP_SECRET=x -e DRAIN_SECONDS=5 -p 8000:8000 lab/app:1.0
curl -m 30 "http://localhost:8000/slow?s=10" &     # a 10-second request
sleep 2
docker stop --time 30 g                             # give it room to drain
wait                                                 # the curl COMPLETES
```

Note `docker stop --time 30`. The default grace period is **10 seconds**; if your drain plus your longest request exceeds that, Docker `SIGKILL`s you mid-drain and all the careful handling is wasted. In Compose that is `stop_grace_period`, and in Swarm `--stop-grace-period`.

**`--init` / tini.** PID 1 has a special duty in Linux: **reaping orphaned child processes.** A normal init does this; your application almost certainly does not. If your app spawns subprocesses (a shell, a converter, a `subprocess.run`), and they are orphaned, they become **zombies** that accumulate until the PID limit is hit and the container can no longer fork.

PID 1 also has no default signal handlers — a signal it does not explicitly handle is *ignored*, which is why a container whose PID 1 lacks a `SIGTERM` handler cannot be `docker stop`ped at all and always takes the full grace period.

`docker run --init` inserts `tini` as PID 1: it reaps zombies and forwards signals to your process. **Use it whenever your container spawns subprocesses.**

---

## C7.7 — Explain it

**1. Image vs container.** An image is a read-only stack of layers plus metadata — a template, at rest, in a registry. A container is a running (or stopped) instance of one: the same layers, plus a thin writable layer, plus its own namespaces and cgroups. Class and object; recipe and meal.

**2. "Up 3 seconds", repeatedly.** The container is in a **crash loop**. It starts, dies, and the restart policy revives it, so `docker ps` always catches it within a few seconds of a fresh start and looks healthy. `docker ps -a` shows the exit code, and `docker inspect --format '{{.RestartCount}}'` shows the number climbing. **`docker ps` is not evidence.**

**3. `EXPOSE` does nothing.** It is metadata declaring intent, readable by tooling and by humans. Publishing a port is a **runtime** decision — `-p`, or `ports:` in Compose — because the same image may need different host ports on different machines. Baking it into the image would be wrong.

**4. Exit 137.** `128 + 9` — the process received `SIGKILL`. **Check `docker inspect --format '{{.State.OOMKilled}}'` first**; if true, the container hit its cgroup memory limit. If false, someone or something sent `kill -9` — commonly `docker stop` escalating after the grace period expired, which itself usually means PID 1 was not handling `SIGTERM`.

**5. Non-root, despite isolation.** Container isolation is a set of kernel features, not a security boundary in the way a VM is. Root in a container is (without user namespaces) **the host's UID 0**, so a container escape — a kernel bug, a careless `--privileged`, a writable host bind mount — lands an attacker as root on the host. Running as UID 10001 means the same escape lands them as an unprivileged nobody. It is one line and it changes the worst case entirely.

**6. `-v /empty:/app` hides your code.** A mount **covers** the mount point, exactly as mounting a USB stick over `/mnt` hides anything already in `/mnt`. The image's `/app` is intact underneath; the container's view of it is replaced by the host directory. Unmount it and the code is right there.

**7. Firewall denies 5432, Postgres is reachable.** Docker writes its own iptables/nftables rules into the `DOCKER` chain, which is evaluated **before** ufw's rules. `-p 5432:5432` therefore publishes on all interfaces regardless of what ufw says. Fixes: publish to a specific interface (`-p 127.0.0.1:5432:5432`), put the port on an internal Docker network with no publishing at all, or set `iptables: false` in `daemon.json` and manage the rules yourself (which breaks container networking unless you know exactly what you are doing). **The practical habit: never publish a database port. Put it on a user-defined network and let only the application container reach it by name.**
