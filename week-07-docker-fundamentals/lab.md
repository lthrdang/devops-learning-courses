# Week 07 — Lab

```bash
cd infra && make w07-up && multipass shell dock
docker run --rm hello-world
```

> If that fails with a permission error, your shell session predates the `docker` group membership cloud-init granted you. `newgrp docker` or log out and back in. Remember from Week 2: **group membership is loaded at login.**

Copy `files/app/` into the VM, then `cd /opt/lab/w07/app`.

---

## Part 1 — Prove a container is just a process (Day 1)

```bash
docker run -d --name web -p 8080:80 nginx:alpine
docker ps
curl -s localhost:8080 | head -3
```

Now look at it **from the host**:

```bash
# 1.1 The container's processes, as the HOST sees them
docker top web
ps aux | grep -i nginx | grep -v grep
pstree -p $(pgrep -f 'nginx: master' | head -1)
```

> There it is: an ordinary Linux process, in the host's process table, with a normal host PID. **This is the moment Docker should stop being magic.**

```bash
# 1.2 The same process, as the CONTAINER sees it
docker exec web ps aux
```

Compare the PIDs. Inside, nginx is PID 1; outside, it is PID 47231 or similar. **That is the PID namespace** — the same process, two different views.

```bash
# 1.3 Look at the namespaces directly
PID=$(docker inspect web --format '{{.State.Pid}}')
sudo ls -l /proc/$PID/ns/            # one entry per namespace
sudo ls -l /proc/1/ns/               # the host's, for comparison
```

Any namespace whose inode differs from the host's is one the container has its own of. Write down which ones differ.

```bash
# 1.4 cgroups - the limits
docker run -d --name limited --memory=128m --cpus=0.5 nginx:alpine
PID=$(docker inspect limited --format '{{.State.Pid}}')
cat /proc/$PID/cgroup
sudo cat /sys/fs/cgroup/system.slice/docker-*.scope/memory.max 2>/dev/null | head
docker stats --no-stream
docker rm -f limited
```

```bash
# 1.5 Layers are shared
docker pull python:3.12-slim
docker pull python:3.12-alpine
docker system df                     # note "SHARED SIZE"
docker image inspect nginx:alpine --format '{{json .RootFS.Layers}}' | jq
```

---

## Part 2 — Build an image properly (Day 2)

```bash
cd /opt/lab/w07/app
cat Dockerfile          # read every comment before building
docker build -t lab/app:1.0 .
docker images lab/app
```

### 2.1 Run it, and read what it tells you about itself

```bash
docker run --rm lab/app:1.0                     # no APP_SECRET - watch it refuse
echo "exit=$?"

docker run -d --name app -e APP_SECRET=s3cret -p 8000:8000 lab/app:1.0
curl -s localhost:8000/ | jq
```

The response includes `pid` and `user`. **Both are assertions about your Dockerfile:**

```json
{ "pid": 1, "user": "10001:999" }
```

`pid: 1` proves the exec form of `CMD` worked. `user` not being `0:0` proves `USER appuser` worked. If either is wrong, the Dockerfile is wrong.

### 2.2 The healthcheck

```bash
docker ps                                        # note "(health: starting)"
sleep 12
docker ps                                        # now "(healthy)"
docker inspect app --format '{{json .State.Health}}' | jq
```

### 2.3 The build cache, measured

```bash
time docker build -t lab/app:1.0 .               # cached: near-instant
touch app.py
time docker build -t lab/app:1.0 .               # only the last layers rebuild
echo "# comment" >> requirements.txt
time docker build -t lab/app:1.0 .               # dependencies reinstall too
```

Now break the ordering deliberately — move `COPY app.py .` above `COPY requirements.txt .`, rebuild, touch `app.py`, rebuild again, and time it. **Write both timings in your logbook.** That difference, multiplied by every CI run your team makes, is why instruction order matters.

### 2.4 Find the nine mistakes

```bash
cat Dockerfile.bad
```

Find **nine** distinct problems before reading `solutions.md`. Then:

```bash
docker build -f Dockerfile.bad -t lab/app:bad .
docker images | grep lab/app
```

Measured on a reference build:

```
lab/app:1.0   203MB
lab/app:bad   1.74GB      ← 8.6x larger
```

```bash
# the secret is in the image metadata, permanently, for anyone who pulls it
docker inspect lab/app:bad --format '{{json .Config.Env}}' | jq
docker history --no-trunc lab/app:bad | grep -i secret

# and it runs as root
docker run --rm --entrypoint sh lab/app:bad -c id
docker run --rm --entrypoint sh lab/app:1.0 -c id
```

### 2.5 Lint and scan

```bash
docker run --rm -i hadolint/hadolint < Dockerfile
docker run --rm -i hadolint/hadolint < Dockerfile.bad      # compare

docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy image --severity HIGH,CRITICAL lab/app:1.0
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy image --severity HIGH,CRITICAL lab/app:bad
```

> Note what mounting `/var/run/docker.sock` into a container means. Week 11 makes you argue about it; for now, register that you just gave that container root on the host.

---

## Part 3 — The signal experiment (Day 2)

This is the most important twenty minutes of the week.

```bash
# 3.1 EXEC form - the correct one
docker run -d --name good -e APP_SECRET=x lab/app:1.0
sleep 3
docker top good -o pid,args
time docker stop good
docker logs good | tail -3
docker inspect good --format 'ExitCode={{.State.ExitCode}}'
```

Reference result:

```
docker stop took 5s
{"level":"info","msg":"SIGTERM received, draining","grace_s":5}
{"level":"info","msg":"shutdown complete"}
ExitCode=0
```

```bash
# 3.2 SHELL form - the bug
printf 'FROM lab/app:1.0\nCMD python app.py\n' > Dockerfile.shellform
docker build -q -f Dockerfile.shellform -t lab/app:shellform .
docker run -d --name bad -e APP_SECRET=x lab/app:shellform
sleep 3
docker top bad -o pid,args
time docker stop bad
docker logs bad | tail -3
docker inspect bad --format 'ExitCode={{.State.ExitCode}}'
```

Reference result:

```
PID      COMMAND
279760   /bin/sh -c python app.py        ← sh is PID 1
279779   python app.py                   ← your app is a CHILD

docker stop took 10s                     ← the full grace period expired
ExitCode=137                             ← 128+9 = SIGKILL
(no shutdown log at all)
```

> **Write this comparison into your logbook and keep it.** The shell form means every deploy kills in-flight requests and every stateful application risks corruption. It is one JSON array away from being correct, and an enormous number of production Dockerfiles get it wrong.

```bash
docker rm -f good bad
```

---

## Part 4 — Storage and networking (Day 3)

### 4.1 Ephemerality, demonstrated

```bash
docker run -d --name eph -e APP_SECRET=x -p 8000:8000 lab/app:1.0
curl -s localhost:8000/write ; echo
curl -s localhost:8000/write ; echo
docker rm -f eph

docker run -d --name eph -e APP_SECRET=x -p 8000:8000 lab/app:1.0
sleep 2 ; curl -s localhost:8000/write ; echo     # back to 1 - the data is gone
docker rm -f eph
```

### 4.2 Named volumes

```bash
docker volume create labdata
docker run -d --name persist -v labdata:/data -e APP_SECRET=x -p 8000:8000 lab/app:1.0
sleep 2
curl -s localhost:8000/write ; curl -s localhost:8000/write ; echo
docker rm -f persist

docker run -d --name persist2 -v labdata:/data -e APP_SECRET=x -p 8000:8000 lab/app:1.0
sleep 2 ; curl -s localhost:8000/write ; echo     # continues from 3
docker rm -f persist2

docker volume inspect labdata
sudo ls -la $(docker volume inspect labdata --format '{{.Mountpoint}}')
```

### 4.3 Bind mounts, and the disappearing-code trap

```bash
mkdir -p /tmp/empty
docker run --rm -v /tmp/empty:/app lab/app:1.0 ls -la /app
```

> `/app` appears empty. **A bind mount hides whatever was underneath.** Your code is still in the image; it is just covered up. This is "my code disappeared" in one command.

### 4.4 Networks and DNS

```bash
# default bridge: NO name resolution between containers
docker run -d --name c1 alpine sleep 3600
docker run -d --name c2 alpine sleep 3600
docker exec c1 ping -c1 -W2 c2 ; echo "exit=$?"

# user-defined bridge: names work
docker network create appnet
docker run -d --name c3 --network appnet alpine sleep 3600
docker run -d --name c4 --network appnet alpine sleep 3600
docker exec c3 ping -c1 c4 ; echo "exit=$?"
docker exec c3 nslookup c4

docker rm -f c1 c2 c3 c4
```

> **Always use a user-defined network.** That is the entire reason: automatic DNS by container name, which is what makes Compose (Week 8) work.

### 4.5 The firewall bypass — do this, then be careful forever

```bash
sudo ufw --force enable
sudo ufw deny 9999/tcp
sudo ufw status | grep 9999

docker run -d --name exposed -p 9999:8000 -e APP_SECRET=x lab/app:1.0
sleep 2
# from ANOTHER machine (your host, or the alpha VM):
curl -m5 http://<DOCK_IP>:9999/ ; echo "exit=$?"
```

> It works. **Your firewall said deny and Docker published it anyway**, because Docker's iptables/nftables rules are evaluated before ufw's. Teams have exposed databases to the internet exactly like this.

The fix:

```bash
docker rm -f exposed
docker run -d --name safe -p 127.0.0.1:9999:8000 -e APP_SECRET=x lab/app:1.0
curl -s -m3 localhost:9999/ >/dev/null && echo "local: OK"
# from another machine: now refused
docker rm -f safe
sudo ufw --force reset
```

**Habit to form: publish to `127.0.0.1` unless you have decided otherwise.**

---

## Part 5 — Limits and security (Day 4)

```bash
# 5.1 Memory limits and exit 137
docker run -d --name burn --memory=64m --memory-swap=64m -e APP_SECRET=x -p 8000:8000 lab/app:1.0
sleep 3
curl -s -m20 localhost:8000/burn
sleep 2
docker inspect burn --format 'OOMKilled={{.State.OOMKilled}} ExitCode={{.State.ExitCode}}'
docker rm -f burn
```

Reference result: `OOMKilled=true ExitCode=137`.

> **137 = 128 + 9 = SIGKILL.** Whenever you see 137, check `OOMKilled` first — it is the answer far more often than not. Then ask whether the limit is too low or the application is leaking.

```bash
# 5.2 Read-only root filesystem
docker run -d --name ro --read-only --tmpfs /tmp -e APP_SECRET=x -p 8000:8000 lab/app:1.0
sleep 2
curl -s localhost:8000/write ; echo
# -> {"error": "[Errno 30] Read-only file system: '/data/counter'"}
docker rm -f ro

docker run -d --name ro2 --read-only --tmpfs /tmp -v labdata:/data -e APP_SECRET=x -p 8000:8000 lab/app:1.0
sleep 2
curl -s localhost:8000/write ; echo         # works: the volume IS writable
docker rm -f ro2
```

> That combination — immutable image, writable only where you explicitly said — is the shape of a hardened container.

```bash
# 5.3 Capabilities
docker run --rm alpine sh -c 'apk add -q libcap; capsh --print 2>/dev/null | head -3' 2>/dev/null || \
docker run --rm alpine sh -c 'cat /proc/self/status | grep CapEff'
docker run --rm --cap-drop=ALL alpine sh -c 'cat /proc/self/status | grep CapEff'
```

```bash
# 5.4 The docker-group escalation. Understand it; do not be casual about it.
docker run --rm -v /:/host alpine cat /host/etc/shadow | head -2
```

> You just read the host's password hashes from inside a container, as an unprivileged user, because you are in the `docker` group. **Membership of the `docker` group is equivalent to root.** Be able to say this in a review.

---

## Part 6 — Drill (Day 5)

```bash
# host
cd infra
make snapshot VM=dock NAME=pre-w07
make break VM=dock DRILL=07-docker
```

Symptom: *"`docker ps` shows it running, but curl gives connection reset. Every time I look, the uptime has reset to a few seconds."*

Three faults. `docker ps` will lie to you; find the command that does not.
