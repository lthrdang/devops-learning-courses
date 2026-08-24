# Chaos drills — break/fix practice

Every script here **deliberately damages a lab VM**. You run it, you are told only the *symptom*, and you find the cause.

## Rules

1. **Snapshot first.**
   ```bash
   cd infra && make snapshot VM=lab NAME=pre-drill
   ```
2. **Do not read the script before the drill.** Reading it is reading the answer. The scripts print the symptom and nothing else, on purpose.
3. **Timebox at 45 minutes.** Under 45, keep digging. Over 45, reveal (below), then **restore the snapshot and diagnose it again from scratch** — the second pass is where the pattern sticks.
4. **Write down your reasoning as you go**, in your logbook: hypothesis → test → result. Comparing that trail against the real cause is the actual training. A lucky fix teaches nothing.

## Running a drill

```bash
cd infra
make break VM=lab DRILL=01-permissions
```

Or by hand:

```bash
multipass transfer chaos/01-permissions.sh lab:/tmp/d.sh
multipass exec lab -- sudo bash /tmp/d.sh
```

## Revealing what a drill did

Each script records what it changed in a root-only file. Only run this after your timebox:

```bash
multipass exec lab -- sudo cat /root/.drill-01-permissions | base64 -d
```

## Restoring

```bash
cd infra && make restore VM=lab NAME=pre-drill
```

## The drills

| Drill | Week | Symptom you will be given |
|---|---|---|
| `01-permissions` | 01 | "The report script prints nothing and exits 1." |
| `02-service` | 02 | "The app doesn't come back after a reboot." |
| `02-disk` | 02 | "Everything fails with 'No space left on device' but `du` says the disk is half empty." |
| `03-script` | 03 | "The backup script says it succeeded, but there is no backup." |
| `04-network` | 04 | "This machine can't reach the other one. Ping works though." |
| `05-proxy` | 05 | "The website returns 502 Bad Gateway." |
| `07-docker` | 07 | "The container keeps restarting." |
| `08-compose` | 08 | "The API starts but every request returns 500." |
| `09-latency` | 09 | "The site is slow. Not down. Just slow." |
| `10-swarm` | 10 | "I scaled to 6 replicas and only 4 are running." |
| `12-gameday` | 12 | Multiple simultaneous faults. No hints at all. |

## A note on realism

Real incidents are rarely a single clean fault, and the symptom rarely points at the cause. These drills reproduce that on purpose: several of them damage something **one layer below** where the symptom appears. That gap — between where it hurts and where it broke — is the thing you are training for.
