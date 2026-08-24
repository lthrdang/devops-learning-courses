# Week 02 — Challenges

---

### C2.1 — Harden the service

Take `labapp.service` and make it as restricted as you can while keeping it working. Then measure your result:

```bash
systemd-analyze security labapp
```

Get the exposure score below **4.0**. For each directive you add, write one line explaining what attack it blunts. Note which directives you *cannot* apply and why — that reasoning is worth more than the score.

---

### C2.2 — Socket activation

Convert `labapp` so that systemd holds the listening socket and starts the service only on the first connection. You will need a `labapp.socket` unit and to change `ExecStart` handling.

Then answer: what is the observable difference in `ss -tlnp` before the first request, and what problem does socket activation solve that `Restart=always` does not?

---

### C2.3 — The reboot test

Configure the machine so that after `sudo reboot`, all of the following are true without any manual intervention:

- `labapp` is running and serving;
- an extra filesystem is mounted at `/mnt/extra`;
- a timer has already produced at least one report;
- the journal contains the previous boot's logs.

Then actually reboot and verify all four. **If you did not reboot, you did not test it** — this is the single most common gap between "I configured it" and "it works".

---

### C2.4 — Log triage under time pressure

Someone reports "the app was broken for a few minutes around 14:30, but it's fine now."

Write down the **exact commands, in order**, that you would run to reconstruct what happened — from journald, from file logs, and from system state. Assume you have shell access and nothing else: no dashboard, no metrics. Aim for under 10 commands.

Then create the situation yourself (stop the service for 3 minutes, generate traffic against it) and prove your command list actually reconstructs it.

---

### C2.5 — Rotation that works

Make `labapp` write to `/var/log/labapp/app.log` in addition to the journal. Write a `logrotate` config that:

- rotates daily **and** when the file exceeds 10 MB;
- keeps 7 compressed generations;
- does not lose lines during rotation;
- creates the new file with the right owner and mode.

Prove it works with `logrotate -f`, then prove the "does not lose lines" property specifically — describe how you tested it, not just that it passed.

---

### C2.6 — Find the timer

Given only a running machine, list **every** scheduled job on it — systemd timers, all six cron locations, `at` jobs, and anything else. There are more places than you think. Write the list of locations in your logbook; it is a genuinely useful checklist to own.

---

### C2.7 — Explain to a developer

A developer says: *"My app works when I run it in my terminal, but as a systemd service it can't find its config file and can't write to its log directory."*

Write the reply. List the four most likely causes in the order you would check them, and the one command that confirms or refutes each.
