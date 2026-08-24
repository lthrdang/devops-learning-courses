# Week 06 — Challenges

---

### C6.1 — `svcctl watch`

Implement the polling/transition-detection subcommand described in `lab.md §2.5`. Requirements:

- prints only state **transitions**, never every poll;
- `--fall N` / `--rise N` hysteresis, so a single blip does not page anyone;
- per-target uptime percentage in the Ctrl-C summary;
- tests written **before** the implementation, including one proving a single blip produces no DOWN report.

---

### C6.2 — Replace the Bash

Rewrite `week-03/files/healthcheck.sh` in Python, then compare honestly:

| | lines | readability | testability | startup time | dependencies |
|---|---|---|---|---|---|

Then answer: which version would you actually deploy, and does the answer change if it runs every 10 seconds from a systemd timer versus once a day from cron?

---

### C6.3 — The log tailer

Write `svcctl tail` that follows a growing log file (like `tail -f`) and:

- emits an alert when the 5xx rate over a **sliding 60-second window** exceeds a threshold;
- survives log rotation — when the file is renamed and recreated, it must follow the new file, not keep reading the old inode;
- never uses more memory as the file grows.

Rotation handling is the hard part, and it is the part that matters. Test it by actually running `logrotate -f` underneath your tailer.

---

### C6.4 — Structured logging

Convert `svcctl` to emit JSON logs when `--log-json` is passed:

```json
{"ts":"2026-03-01T09:15:00Z","level":"error","logger":"svcctl.checks","msg":"check failed","target":"http://x/","attempt":3,"error":"timeout"}
```

Then answer: what becomes possible with these logs that was impossible with the human-readable ones? What becomes *harder*? When would you ship JSON logs and when would you not?

---

### C6.5 — Fail correctly

Introduce each of these into `svcctl` and observe exactly what a user sees:

1. A target URL with a typo in the scheme (`htp://`).
2. A target file that does not exist.
3. A target file that exists but is empty.
4. `--timeout -5`.
5. A target that returns 200 with a 4 GB body.
6. 10,000 targets with `--workers 10000`.

For each, decide the *correct* behaviour, implement it, and write a test. Number 5 and number 6 are the interesting ones, and neither is handled by the code as given.

---

### C6.6 — Know when to stop

Find an existing open-source tool that does what `svcctl check` does, better. Install it, use it, and write a paragraph comparing it with yours.

Then write two paragraphs: one arguing that building `svcctl` was a waste of time, and one arguing it was not. Both should be honest. The ability to hold both views is what makes build-vs-buy decisions well.
