# Postmortem: <short descriptive title>

**Status:** draft | in review | final
**Authors:** <names>
**Date of incident:** YYYY-MM-DD
**Severity:** SEV-1 (total outage) | SEV-2 (major degradation) | SEV-3 (minor)

> **This document is blameless.** Describe what the system allowed to happen,
> not who did it. This is not politeness: people who expect blame withhold
> information, and an incident review without information is theatre. Write
> "the deploy pipeline permitted an unverified image to reach production", not
> "Minh deployed a bad image".

---

## 1. Summary

*Three sentences, readable by someone non-technical. What broke, who was
affected, how long, and what fixed it.*

Example:
> Between 14:05 and 15:20, roughly 30% of checkout requests failed or timed out.
> The cause was a combination of a filled root filesystem on node1 and a
> previously drained node that had never been reactivated, which together left
> the service with one third of its intended capacity. Service was restored by
> freeing disk space and reactivating the node.

---

## 2. Impact

- **Users affected:** *a number or a percentage, not "some"*
- **Duration:** *detection to resolution, and separately, START to resolution —
  the gap between them is your detection time, and it is usually the most
  actionable number in the whole document*
- **Requests failed:** *count or rate*
- **Data lost:** *yes/no. If yes, exactly what, and is it recoverable?*
- **Revenue / SLO impact:** *error budget consumed*

---

## 3. Timeline

*Real timestamps. Include the wrong turns — they are the most instructive part
and the reason this document is worth writing.*

| Time | Event |
|---|---|
| 14:05 | First failed request (established later from logs — nobody noticed) |
| 14:32 | Alert `HighErrorRate` fired |
| 14:34 | On-call acknowledged; posted first status update |
| 14:36 | Hypothesis 1: bad deploy. Checked image timestamps — **disproved**, last deploy was 3 days ago |
| 14:41 | Hypothesis 2: database down. `/health` reported db:true — **disproved** |
| 14:52 | Hypothesis 3: capacity. `docker service ls` showed 4/6 replicas — **confirmed** |
| 14:55 | `docker node ls` — node2 AVAILABILITY=Drain. Reactivated |
| 15:02 | Replicas recovered to 5/6. Errors reduced but did not stop |
| 15:04 | *(spent 12 minutes assuming the remaining failure was the same cause)* |
| 15:16 | `df -h` on node1 — root filesystem 100% full |
| 15:18 | Cleared rotated logs; the sixth replica started |
| 15:20 | Error rate returned to baseline |
| 15:35 | Monitored, declared resolved |

---

## 4. Root cause

*Plural is normal. Most real incidents have several contributing causes, and
writing "the root cause" often means you stopped looking.*

**Contributing cause 1:** …
**Contributing cause 2:** …
**Why the combination was worse than either alone:** …

---

## 5. Detection

- **How was it detected?** *(alert / customer report / by chance)*
- **Time from start to detection:** *(14:05 → 14:32 = 27 minutes)*
- **Should it have been detected sooner?** What signal existed and was not alerted on?

> Detection time is where most improvement is available. A 27-minute detection
> gap on a 75-minute incident means a third of the impact was avoidable with a
> better alert — usually a cheaper fix than preventing the cause.

---

## 6. What went well

*Genuinely. If the runbook worked, say so; if the rollback was instant, say so.
A postmortem that lists only failures teaches people that incidents are
punishments, and then you stop hearing about the small ones.*

---

## 7. What went badly

- …
- *Include process problems, not just technical ones: unclear ownership, a
  missing runbook, an alert that fired to a channel nobody watches.*

---

## 8. Where we got lucky

*The near-misses. "The backup was 40 minutes old rather than 24 hours because
someone had run one manually that morning." These are future incidents
announcing themselves, and this section is the one that most often prevents
the next outage.*

---

## 9. Action items

| # | Action | Type | Owner | Due |
|---|---|---|---|---|
| 1 | Alert on `node.Availability != active` for > 30 min | detect | | |
| 2 | Alert on `predict_linear` disk-full within 4h | detect | | |
| 3 | Log rotation limits on all nodes via cloud-init | prevent | | |
| 4 | Runbook: "replicas below desired" | mitigate | | |
| 5 | Game-day rehearsal of this scenario next month | practice | | |

> **Every action item needs an owner and a date, or it is a wish.**
> Prefer *detect* and *mitigate* items over *prevent* ones: you cannot prevent
> every cause, but you can always shorten detection and recovery — and those
> improvements pay out on incidents you have not imagined yet.

---

## 10. Lessons

*What would you tell an engineer joining this team tomorrow?*
