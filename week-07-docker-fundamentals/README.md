# Week 07 — Docker Fundamentals

**VM profile:** `make w07-up` → `dock` (Docker Engine installed)
**You will be able to:** explain what a container actually is at the kernel level, build small secure images, and debug a container that will not start.

> A container is **not a small virtual machine**. It is one or more ordinary Linux processes, running on the host's kernel, with a restricted view of the system. Everything confusing about Docker becomes obvious once you believe that sentence — and this week is designed to make you believe it by showing you the processes from outside.

---

## Day 1 — What a container really is

### 1.1 Three kernel features, no magic

| Feature | Provides | Answers |
|---|---|---|
| **namespaces** | isolation of *what you can see* | "why does `ps` inside show only my process?" |
| **cgroups** | limits on *what you can use* | "how do I stop it eating all the RAM?" |
| **union filesystem** | layered, copy-on-write images | "why is the image 200 MB but 10 containers cost almost nothing?" |

**Namespaces** (there are several kinds — pid, net, mnt, uts, ipc, user, cgroup) each give a process a private view of one kind of global resource. A PID namespace means your process sees itself as PID 1 and cannot see the host's processes. A network namespace means it has its own interfaces, routing table and firewall rules.

**cgroups** (control groups) meter and cap CPU, memory, I/O and process count. When a container is "OOM killed", a cgroup memory limit was exceeded and the kernel's OOM killer chose a victim inside it.

**Union filesystems** (overlayfs) stack read-only image layers with one thin writable layer per container. Ten containers from one image share every read-only layer; only their writes cost anything.

**The proof, and you will run it in the lab:** start a container, then find its process **on the host** with `ps aux`. It is right there, an ordinary process. That is the moment Docker stops being magic.

### 1.2 Images, layers, containers

An **image** is an ordered stack of read-only layers plus metadata (entrypoint, env, exposed ports). A **container** is an image plus a writable layer plus a set of namespaces and cgroups. A **registry** stores and distributes images.

Every instruction in a Dockerfile that changes the filesystem creates a layer. Layers are content-addressed and shared: if two images share a base, the base is stored and pulled once.

> **Layers are additive only. Deleting a file in a later layer does not remove it from the image** — it just hides it. A secret `COPY`d in layer 3 and `rm`d in layer 4 is still fully extractable from the image. This is the single most common way credentials leak from container images, and `docker history` reveals it.

### 1.3 The command surface

```bash
docker run -d --name web -p 8080:80 nginx:alpine
docker ps                       # running
docker ps -a                    # ALL, including exited - THE one to use when debugging
docker logs -f web
docker exec -it web sh
docker inspect web
docker stop web ; docker rm web

docker images
docker pull python:3.12-slim
docker rmi <image>
docker system df                # what is consuming disk
docker system prune -a          # reclaim it (destructive - read before running)
```

**`docker ps` is not evidence.** A container in a crash loop shows as "Up 2 seconds" forever, because it keeps being restarted. `docker ps -a` shows the exit code and restart count. Drill 07 is built on exactly this.

---

## Day 2 — Writing a Dockerfile

### 2.1 The instructions that matter

```dockerfile
FROM python:3.12-slim AS base    # the base image, and a build-stage name

WORKDIR /app                     # sets cwd; creates it if needed

COPY requirements.txt .          # host → image
RUN pip install --no-cache-dir -r requirements.txt   # runs at BUILD time

COPY src/ ./src/

ENV PORT=8000                    # environment at RUN time
EXPOSE 8000                      # DOCUMENTATION ONLY - publishes nothing

USER appuser                     # drop privileges

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8000/health')"

ENTRYPOINT ["python", "-m", "myapp"]   # the executable
CMD ["--port", "8000"]                 # default ARGUMENTS, overridable
```

**`EXPOSE` publishes nothing.** It is metadata. Only `-p` on `docker run` (or `ports:` in Compose) actually publishes a port. People lose an hour to this exactly once.

**`ENTRYPOINT` vs `CMD`:** `ENTRYPOINT` is the command; `CMD` supplies default arguments that `docker run image <args>` replaces. If you only set `CMD`, the whole thing is replaced. Use `ENTRYPOINT` for the binary and `CMD` for flags.

**Exec form vs shell form.** `CMD ["python", "app.py"]` (exec form) runs your program as **PID 1 directly**, so it receives `SIGTERM` from `docker stop`. `CMD python app.py` (shell form) runs `/bin/sh -c "python app.py"`, so **sh** is PID 1, and `sh` does not forward signals — your app never learns it should shut down and gets `SIGKILL`ed 10 seconds later. **Always use the exec form (JSON array).** This is a real, common, data-corrupting bug.

### 2.2 Build cache — the difference between a 2-second and a 4-minute build

Docker caches each layer. A layer is rebuilt when its instruction *or any layer before it* changes. Therefore: **order instructions from least- to most-frequently-changing.**

```dockerfile
# BAD - any source change reinstalls every dependency
COPY . .
RUN pip install -r requirements.txt

# GOOD - dependencies are only reinstalled when requirements.txt changes
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY src/ ./src/
```

Add a `.dockerignore` (same syntax as `.gitignore`). Without it, `COPY . .` ships your `.git` directory, your `.venv`, your `node_modules` and your `.env` file into the image — bloating it and often leaking secrets.

### 2.3 Multi-stage builds

Build tooling does not belong in the image you ship.

```dockerfile
FROM golang:1.22 AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -o /out/app ./cmd/app

FROM gcr.io/distroless/static-debian12
COPY --from=build /out/app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
```

The final image contains one binary — around 10 MB instead of 900 MB. **Less software means fewer vulnerabilities**: the compiler, the package manager and the shell that are not in your image cannot be exploited in your image.

### 2.4 Base image choice

| Base | Size | Trade-off |
|---|---|---|
| `ubuntu:24.04` | ~78 MB | familiar, apt available, largest attack surface |
| `python:3.12-slim` | ~50 MB | Debian-based, good default for Python |
| `alpine` | ~8 MB | tiny, but **musl libc** — breaks some Python wheels and can cause subtle DNS and timing differences |
| `distroless` | ~2–20 MB | no shell, no package manager. Most secure, hardest to debug |

**The Alpine caveat is worth knowing:** Alpine uses musl instead of glibc. Python packages with compiled extensions often have no musl wheel, so `pip install` compiles from source — turning a 10-second build into a 10-minute one and producing a *larger* image than `slim`. Alpine is excellent for Go and static binaries, and frequently a trap for Python.

---

## Day 3 — Storage and networking

### 3.1 The container filesystem is ephemeral

When a container is removed, its writable layer is deleted. Anything not in a volume is gone.

| Mount type | Syntax | Use for |
|---|---|---|
| **named volume** | `-v mydata:/var/lib/db` | persistent app data. Docker manages the location |
| **bind mount** | `-v /host/path:/in/container` | source code in development; host config |
| **tmpfs** | `--tmpfs /tmp` | secrets and scratch you want to vanish, never touching disk |

Prefer named volumes for data (portable, backed up as a unit) and bind mounts for development (edit on the host, see it live).

> **A bind mount hides whatever was at the mount point.** Mounting an empty host directory over `/app` in a container makes `/app` appear empty, and "my code disappeared" is the usual first reaction.

### 3.2 Networks

| Driver | Behaviour |
|---|---|
| `bridge` (default) | private network per host, NAT to the outside. Containers reach each other by IP |
| **user-defined bridge** | same, **plus automatic DNS between containers by name** |
| `host` | no network namespace — the container uses the host's stack directly. Fast, and no isolation |
| `none` | no networking at all |
| `overlay` | multi-host — Week 10 |

**Always create a user-defined network rather than using the default bridge**, because only user-defined networks give you container-name DNS:

```bash
docker network create appnet
docker run -d --name db --network appnet postgres:16
docker run -d --name api --network appnet myapi     # can now reach "db" by name
```

`-p 8080:80` means **host port 8080 → container port 80**. Host port first. Getting it backwards produces a confusing "connection refused".

### 3.3 The Docker/firewall interaction that surprises everyone

**Docker inserts its own rules ahead of ufw's.** A container published with `-p 8080:80` is reachable from the network **even if `ufw deny 8080` is set**, because Docker's `DOCKER` chain is consulted before ufw's rules. Teams have exposed databases to the internet this way while believing their firewall was closed.

The fix is to publish to a specific interface: `-p 127.0.0.1:8080:80` binds only to loopback. Get in the habit — publish to `127.0.0.1` unless you deliberately want the world.

---

## Day 4 — Running containers safely

### 4.1 Resource limits

```bash
docker run -d \
  --memory=512m --memory-swap=512m \
  --cpus=1.5 \
  --pids-limit=200 \
  myapp
```

**Without a memory limit, one container can consume all the host's RAM** and the kernel OOM killer will choose a victim — possibly a different, innocent container, or `sshd`. Setting limits converts "the whole host falls over" into "one container restarts". Always set them.

`--memory-swap` equal to `--memory` disables swap for the container, which is usually what you want: swapping makes a container slow in a way that is very hard to diagnose, and failing fast is more useful.

### 4.2 Security basics

```dockerfile
RUN useradd --system --uid 10001 --no-create-home appuser
USER appuser
```

```bash
docker run \
  --read-only --tmpfs /tmp \
  --cap-drop=ALL --cap-add=NET_BIND_SERVICE \
  --security-opt=no-new-privileges \
  myapp
```

- **Containers run as root by default**, and that root — absent user namespaces — is the *host's* root if it escapes. Always set `USER`.
- `--cap-drop=ALL` removes Linux capabilities and adds back only what is needed.
- `--read-only` makes the container filesystem immutable; combine with `--tmpfs` for the paths that genuinely need writes.

**And the one people miss:** membership of the `docker` group is equivalent to root on the host, because `docker run -v /:/host` gives you the entire filesystem. Granting `docker` group access is granting root. Say this out loud in reviews.

### 4.3 Debugging a container that will not start

```bash
docker ps -a                                    # exit code and restart count
docker logs <name>                              # what the app said
docker logs --tail 100 --timestamps <name>
docker inspect <name> --format '{{.State.ExitCode}} {{.State.Error}} {{.RestartCount}}'
docker inspect <name> --format '{{json .State.Health}}' | jq
docker events --since 10m                       # the daemon's view of what happened
```

Exit codes worth recognising:

| Code | Means |
|---|---|
| 0 | exited cleanly — for a server, that usually means it did not find work to do |
| 1 | application error — **read the logs** |
| 125 | the Docker daemon itself failed (bad flag) |
| 126 | the command exists but is not executable |
| 127 | **command not found** — usually a wrong path, or a shell that does not exist in the image |
| 137 | `128 + 9` = SIGKILL — **usually OOM.** Check `docker inspect --format '{{.State.OOMKilled}}'` |
| 139 | `128 + 11` = segfault |
| 143 | `128 + 15` = SIGTERM — a normal `docker stop` |

**When the container will not stay up long enough to exec into it**, override the entrypoint:

```bash
docker run -it --rm --entrypoint sh myimage
```

That gives you a shell inside the image with none of the startup logic running — the fastest way to check "is the file even there?".

---

## Day 5 — Drill

```bash
cd infra
make snapshot VM=dock NAME=pre-w07
make break VM=dock DRILL=07-docker
```

Symptom: *"`docker ps` shows it running, but curl gives connection reset. The uptime keeps resetting to a few seconds."*

Three faults. Find all three.

## Recommended reading

- Docker docs — <https://docs.docker.com/> — especially the Dockerfile best-practices page
- *Container Security*, Liz Rice — and her free conference talks on building a container from scratch in ~100 lines of Go
- <https://github.com/hadolint/hadolint> — a Dockerfile linter. Run it on everything
- <https://github.com/aquasecurity/trivy> — free, open-source image vulnerability scanner
- <https://github.com/wagoodman/dive> — explore image layers interactively and find the waste
