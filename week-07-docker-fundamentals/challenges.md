# Week 07 — Challenges

---

### C7.1 — Shrink it

Take `lab/app:1.0` (203 MB) and get it under **80 MB** without losing the healthcheck, the non-root user, or graceful shutdown. Measure at each step and record what each change bought you.

Then attempt the same for a Python app with a compiled dependency (`pip install cryptography`) using Alpine, and record what happens. Report the build time and the final size honestly.

---

### C7.2 — Nine mistakes

List all nine problems in `Dockerfile.bad`, and for each: the concrete consequence, and how you would catch it automatically in CI. Then fix them one at a time, measuring the image size after each fix.

---

### C7.3 — The forensics kit

A container is crash-looping and you cannot exec into it because it never stays up. Write a script `dbg.sh CONTAINER` that gathers, in one shot:

- the exit code, restart count and OOM flag;
- the last 100 log lines with timestamps;
- the effective command, user, env (with secrets redacted) and mounts;
- health check history including the failing probe output;
- resource limits versus actual usage;
- the image's layer history.

Then use it on the drill-07 container and see how much of the diagnosis it hands you for free.

---

### C7.4 — Make the image immutable

Run `lab/app` with `--read-only`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`, a non-root user, memory and pid limits, and **no writable path except one volume**. Prove every restriction is active from inside the container.

Then break each restriction one at a time and record which application behaviour fails. The point is knowing which restriction to relax when something legitimately needs it.

---

### C7.5 — Signals, properly

Extend `app.py` so that graceful shutdown actually drains: stop accepting new connections, finish in-flight requests, then exit — with a configurable grace period. Prove it by holding a slow request open while running `docker stop`, and show the request completing rather than being cut off.

Then research **`--init` / tini**: what problem does it solve, and why does a Python app that spawns subprocesses need it?

---

### C7.6 — Layer archaeology

Build an image that `COPY`s a secret file in one layer and `rm`s it in the next. Then **extract the secret from the finished image** without running it.

```bash
docker save myimage:leaky -o leaky.tar
# ... your work here ...
```

Write the two-sentence rule you would put in your team's Dockerfile guidelines as a result.

---

### C7.7 — Explain it

Write answers a competent junior should be able to give on the spot:

1. What is the difference between an image and a container?
2. Why is `docker ps` showing "Up 3 seconds" repeatedly a red flag?
3. Why does `EXPOSE 8080` not make the port reachable?
4. What does exit code 137 mean, and what do you check first?
5. Why should a container not run as root, given that it is "isolated anyway"?
6. Why does `-v /empty:/app` make your application code disappear?
7. Your firewall denies port 5432, but the Postgres container is reachable from the network. Why?
