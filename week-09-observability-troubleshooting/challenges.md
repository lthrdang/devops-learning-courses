# Week 09 — Challenges

---

### C9.1 — The SLO

Define an SLO for the `/items` endpoint: a target, a measurement window, and an error budget. Then:

- write the PromQL that measures compliance;
- write the alert that fires when you are **burning budget too fast** (not when you have breached — that is too late);
- work out how much downtime 99.9% over 30 days actually permits;
- state what you would *stop doing* when the budget is exhausted.

That last point is what makes an SLO real rather than decorative.

---

### C9.2 — The dashboard that answers a question

Most dashboards are a wall of graphs nobody reads. Build one that answers exactly one question — *"is the service healthy right now, and if not, which layer is at fault?"* — in **under ten seconds**, with no scrolling.

Constraints: at most 6 panels; every panel must change what you would do next; a colleague who has never seen it must reach the right conclusion unaided. Test that last constraint on an actual colleague.

---

### C9.3 — Find the cardinality bomb

Write a script that queries Prometheus and reports:

- the top 10 metrics by series count;
- the top 10 label *names* by distinct value count;
- any metric whose series count grew more than 50% in 24 hours.

Then run it against your own stack. Anything surprising is a future outage.

*Hint: `/api/v1/status/tsdb` and `count by (__name__)({__name__=~".+"})`.*

---

### C9.4 — Log volume triage

Your Loki instance is ingesting 50 GB/day and the bill is a problem. Without losing the ability to debug incidents, reduce it by 80%.

Report what you dropped, what you kept, and — the important part — **what you would no longer be able to investigate**. An honest list of what you gave up is the deliverable.

---

### C9.5 — The blind investigation

Have a colleague apply `infra/chaos/09-latency.sh` with one or two of its three faults commented out, without telling you which.

Investigate. Produce a written timeline: each hypothesis, the test, the result, and the elapsed time. Then compare against the actual faults.

Score yourself on: time to correct hypothesis, number of wrong turns, and whether any test you ran could not have distinguished anything.

---

### C9.6 — Instrument something real

Add Prometheus metrics to the Week 8 stack API. Requirements:

- RED metrics for HTTP, with **bounded** route labels;
- a gauge for database connection state;
- a counter for cache hits and misses;
- a histogram for database query duration;
- `/metrics` must not itself be slow, and must not appear in its own latency stats in a way that skews them.

Then answer: which of these would you actually alert on, and which are only for dashboards?

---

### C9.7 — Write the runbook

Pick one alert from `alerts.yml` and write its runbook. It must contain: what the alert means, what users are experiencing, the first three commands to run, the three most likely causes with how to distinguish them, how to mitigate, and how to verify the mitigation worked.

Then test it: give the runbook to someone who has not seen the system, trigger the alert, and watch them use it. Every place they get stuck is a defect in the runbook.
