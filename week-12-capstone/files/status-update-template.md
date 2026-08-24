# Incident status updates

Post one within **10 minutes** of acknowledging, then every 30 minutes until
resolved. Write them even when nobody appears to be reading — the discipline is
what keeps an incident coordinated when a second person joins.

## The format

```
[HH:MM] SEV-2 — Checkout failures
IMPACT:   ~30% of checkout requests failing since ~14:05.
STATUS:   Investigating. Confirmed not a deploy; capacity is reduced (4/6 replicas).
NEXT:     Checking node availability and resource limits. Next update 15:05.
```

Four lines, always the same four:

| Line | Purpose |
|---|---|
| **IMPACT** | what users experience, in numbers. Not "some issues" |
| **STATUS** | what you know **and what you have ruled out** |
| **NEXT** | what you are doing now, and when the next update comes |
| *(implicit)* | the timestamp, so anyone joining can orient instantly |

## Rules

- **Impact first.** Everyone reading wants to know how bad it is; the cause is your problem, not theirs.
- **State what you ruled out.** It stops three people re-checking the same thing and is the most useful thing you can hand the next responder.
- **Always commit to a next-update time**, and post it even if there is no news — "no change, still investigating" is information. Silence is read as "it is worse than they are saying".
- **Do not speculate about cause in a status update.** A wrong guess broadcast widely takes on a life of its own, and you will spend the rest of the incident correcting it.
- **Say when it is over**, explicitly, with a final line about whether a postmortem is coming.
