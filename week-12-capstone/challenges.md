# Week 12 — Stretch challenges

Only after the core capstone is complete and reviewed.

---

### C12.1 — Run the game day for someone else

Design and run a game day for another learner: choose the faults, write the symptom, observe without helping, then debrief.

Designing a good scenario teaches you more than solving one. Write down what you learned about *your own* debugging by watching somebody else's.

---

### C12.2 — Chaos on a schedule

Make failure routine rather than exceptional: a systemd timer that, during working hours only, randomly kills one container, drains one node, or adds packet loss for two minutes.

Then run it for a week. Report what broke that you did not expect, and what you fixed as a result.

---

### C12.3 — Ten times the load

Your capacity number from Day 3 — make the system handle 10× it. Measure at each step, and stop when you find the bottleneck you cannot remove without a redesign.

Write up: what you changed, what each change bought, and where the wall is.

---

### C12.4 — The 3am test

Have someone trigger a fault while you are genuinely tired, and use **only your own runbooks**. No improvisation, no reading source code.

Every place the runbook failed you is the deliverable. This is the single most honest test of documentation that exists.

---

### C12.5 — Migrate it to Kubernetes

Take the finished stack to `k3s` or `kind`. Map each Swarm concept to its Kubernetes equivalent, and record what has no equivalent in either direction.

Then write one page: what was harder, what was easier, and what you now understand about Swarm that you did not before.

---

### C12.6 — Explain it to a developer

Write the document a backend developer reads on their first day: how to run it locally, how to add an endpoint, what the health check must return and why, what will make their pull request rejected, and how to debug it in production without your help.

If they still have to ask you things, the document is not finished.
