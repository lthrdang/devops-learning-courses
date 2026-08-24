# Week 00 — Challenges

No step-by-step instructions. Work out the *how* yourself; that is the exercise.
Record your approach and your dead ends in your logbook.

---

### C0.1 — One command, one machine

Write a shell script `newlab.sh` on your host that takes a name and creates a fully provisioned VM with the course base image, waits until it is genuinely ready, installs your SSH key, adds an `~/.ssh/config` entry, and prints the address. Running it twice with the same name must not corrupt anything.

*Success:* `./newlab.sh testbox && ssh testbox uptime` works from cold, in one go.
*Stretch:* make it idempotent — if `testbox` already exists, it updates the config entry rather than failing.

---

### C0.2 — Prove cloud-init ran

Without using the `/opt/lab/.provisioned` marker file, find three independent pieces of evidence inside a VM that cloud-init completed successfully, and one way to tell that it ran but *partially failed*.

*Hint: think about logs, systemd units, and cached state under `/var/lib/`.*

---

### C0.3 — The silent failure

Deliberately introduce an error into a copy of `base.yaml` — for example, a package name that does not exist — and launch a VM with it.

- Does `multipass launch` report an error?
- Does the VM boot?
- What does `cloud-init status` say?
- Where exactly, in which file and at which line, is the truth?

Write two or three sentences on why a system that boots successfully despite failed provisioning is dangerous, and what you would do about it in a real environment.

---

### C0.4 — Measure the cost of cattle

Time these three operations precisely and record them:

1. Launch a VM from scratch with cloud-init.
2. Restore a snapshot.
3. Stop and start an existing VM.

Then answer: given these numbers, when would you snapshot-and-restore rather than rebuild? Under what circumstances is rebuilding *safer* even though it is slower?

---

### C0.5 — Read someone else's infrastructure

Find a real cloud-init file in an open-source project on GitHub (search for `#cloud-config` in `.yaml` files). Read it. Write a short summary: what machine does it build, what would break if `runcmd` ran in a different order, and what would you criticise in review?

---

### C0.6 — The forbidden question

You are asked in an interview: *"We have a server that's been running for four years. Nobody knows exactly how it was configured. It works. Why should we change anything?"*

Write your answer in five sentences or fewer. It should not use the word "best practice".
