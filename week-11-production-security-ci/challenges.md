# Week 11 — Challenges

---

### C11.1 — The exposure audit

From a machine outside the cluster, enumerate every reachable port on all three nodes. For each, produce a row: port, service, why it is open, who should reach it, and what happens if you close it.

Then close everything unjustified and re-scan to prove it. Include at least one port you **thought** was closed and was not.

---

### C11.2 — Recover from a total loss

Node1 is gone: disk failure, nothing recoverable. You have your backups and your git repository.

Rebuild the entire stack on a fresh VM and get back to serving traffic. **Time it.** Then write the runbook, and re-run it to check the runbook is sufficient without your memory filling gaps.

Report: total time, the step that took longest, and one change that would halve it.

---

### C11.3 — Rotate everything

Rotate, with zero downtime and while a request loop runs:

1. the database password;
2. the TLS certificate;
3. an SSH key for the deploy user;
4. the registry credentials.

For each, record the procedure and any moment where a mistake would have caused an outage. Number 1 has the Week 8 trap in it.

---

### C11.4 — Make the pipeline refuse

Add gates so the pipeline **refuses to deploy** when:

- a test fails;
- a CRITICAL CVE is present;
- the image runs as root;
- the image is larger than 200 MB;
- a secret is detected in the source;
- the smoke test fails after deploy.

Prove each by deliberately breaking it. Then answer: which of these would you make a hard failure and which a warning, in a team that ships ten times a day?

---

### C11.5 — The backward-compatible migration

Take a real schema change — renaming a column — and implement it as a sequence of deploys that is safe at every intermediate state.

Then **prove** it: run a request loop, perform the whole sequence, and show zero errors. Then do it the naive way and show the errors it produces.

---

### C11.6 — Threat-model your own stack

For the Week 8/10 stack, write out: what an attacker would want, the three most likely ways in, what they could reach after each, and one control that would have stopped each.

Then pick the **cheapest** control that reduces the most risk and implement it. State explicitly what you are choosing not to defend against, and why that is acceptable.

---

### C11.7 — The disaster you have not planned for

Choose a failure your current setup does **not** survive. Not a hypothetical one — a real gap you can name.

Write two paragraphs: what it would cost if it happened tomorrow, and what it would cost to be ready for it. Then make a recommendation, including the option of accepting the risk.

An answer that recommends mitigating everything has not understood the exercise.
