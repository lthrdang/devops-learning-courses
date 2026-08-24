# Week 01 — Challenges

No instructions. Work out the how. Timebox 45 minutes each.

---

### C1.1 — The log interrogation

Using `/opt/lab/w01/access.log` and only shell tools, answer each of these with **a single pipeline**:

1. The top 5 client IPs by request count.
2. The top 5 URL paths by request count.
3. The complete status-code distribution, ranked.
4. The percentage of requests that were 5xx, to one decimal place.
5. Every IP that generated **more than 40** 5xx responses.
6. The total bytes transferred, in megabytes.
7. The busiest single **hour** of the day.
8. The top 3 paths *among 5xx responses only* — i.e. which endpoint is actually broken?
9. Any client whose requests are **more than 20% errors** — a possible scanner or a broken integration.

Question 9 is the interesting one: it needs two aggregations of the same data compared against each other. Solve it in `awk` if you can.

---

### C1.2 — Build a permission puzzle

Create a directory structure and set of permissions such that user `deployer`:

- can **read** `/srv/app/config.yaml`
- can **not** modify it
- can **create new files** in `/srv/app/uploads/`
- can **not** delete files created there by other users
- can **not** list the contents of `/srv/app/secrets/`, but **can** read `/srv/app/secrets/token` if told the exact path

Verify every single one of those five properties with `sudo -u deployer ...`. Write down which permission bit enforces each.

---

### C1.3 — Find the space

Someone has hidden a 200 MB file somewhere under `/var`. Find it with one command. Then find:

- the 10 largest files anywhere on the system;
- the directory with the most *files* in it (not the most bytes);
- any file modified in the last 10 minutes under `/etc`.

---

### C1.4 — Process forensics

Start `sleep 3600` in the background, then, using **only** files under `/proc/<pid>/`, determine without using `ps`:

- its command line;
- its parent's PID;
- its current working directory;
- the executable it is running;
- how much resident memory it uses;
- which user started it.

Then explain what `/proc/<pid>/fd/` contains and why `lsof` is essentially a friendly interface to it.

---

### C1.5 — Reproduce `top` with a pipeline

Write a one-liner that prints the 5 processes using the most memory, in the form `RSS_MB  USER  COMMAND`, sorted descending, with the RSS in megabytes rather than kilobytes.

---

### C1.6 — The signal experiment

Write a small script that:
- traps `SIGTERM` and `SIGHUP` differently — `TERM` exits cleanly, `HUP` re-reads a config file and keeps running;
- logs each event with a timestamp;
- writes its own PID to `/tmp/myapp.pid` on start and removes it on clean exit.

Demonstrate all three paths: reload, graceful stop, and `kill -9`. Explain what is left behind in the `-9` case and why that is a problem for the *next* start.

---

### C1.7 — Explain the difference

In one paragraph each, explain to an imaginary colleague:

1. Why `cmd 2>&1 > file` does not do what it looks like.
2. Why `free -h` showing 200 MB "free" on a 4 GB machine is not a problem.
3. Why `load average: 4.0` might be fine on one machine and an emergency on another.
4. Why `kill -9` should not be your first move.
5. Why `chmod 777` almost never fixes the real problem.
