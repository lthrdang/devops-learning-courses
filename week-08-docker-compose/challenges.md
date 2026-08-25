# Week 08 — Challenges

---

### C8.1 — Add a worker with a queue

Add a background worker that consumes jobs from Redis and a way to enqueue them via the API. Requirements:

- the worker scales with `--scale worker=4` and jobs are not processed twice;
- stopping a worker mid-job does not lose the job;
- `docker compose logs worker` clearly shows which replica took which job;
- the stack still starts cleanly from `docker compose down -v`.

---

### C8.2 — Migrations that run exactly once

Add a `migrate` service that creates the schema, using `condition: service_completed_successfully` so the API never starts against an unmigrated database.

Then answer: what happens when you scale the API to 3? Does the migration run three times? What would happen in Swarm (Week 10), where there is no such condition?

---

### C8.3 — The dev/prod split

Produce a genuine three-file split and prove each property:

| Property | dev | prod |
|---|---|---|
| source bind-mounted | yes | **no** |
| ports published | api + db, on loopback | proxy only |
| resource limits | none | set |
| restart policy | `no` | `always` |
| log level | debug | info |

Prove each with `docker compose config` and by inspecting the running containers — not by reading the YAML.

---

### C8.4 — Backup and restore, for real

Write `backup.sh` and `restore.sh` for the Postgres volume. Then perform a genuine drill:

1. Insert known data.
2. Back up.
3. `docker compose down -v` — destroy everything.
4. Restore.
5. Prove the data is byte-identical.

Record the elapsed time for step 4. That number is your RTO, and it is the only honest answer to "how long to recover?".

---

### C8.5 — Make the 502 impossible

Using what you found in `lab.md §5.3`, produce the "nginx caches the old IP" failure deliberately: bring the stack up, then `docker compose up -d --force-recreate api` and hit the proxy immediately.

Then fix it **three different ways** and compare:

1. the `resolver` + variable approach;
2. putting HAProxy in front instead (Week 5);
3. having nginx reload when the backend changes.

Which would you use, and what does each cost?

---

### C8.6 — Secret handling audit

Audit the stack and answer with evidence (commands and their output):

1. Can the database password be read from `docker inspect`?
2. Is it in the image?
3. Is it in `docker compose config` output?
4. Is it in the shell history of whoever ran `make init`?
5. Is it in the container's environment?
6. Who on the host can read `secrets/db_password.txt`? Check the mode of both the file **and** the directory — then try to "harden" the file with `chmod 600 secrets/db_password.txt && docker compose up -d --force-recreate`, and explain the failure you get. What does that tell you about how a Compose `file:` secret reaches the container, and which YAML sub-options would have fixed it if this were Swarm?

For each "yes", state the fix. Then decide which of the remaining risks you would accept for a single-host deployment, and why.

---

### C8.7 — Compose's limits

Write the memo you would send your team arguing that this stack has outgrown Compose. It must name **specific failure scenarios Compose cannot handle**, not generalities — and it must be honest about the migration cost.
