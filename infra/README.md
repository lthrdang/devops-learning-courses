# Lab infrastructure

Everything needed to create, break and destroy the machines this course runs on.

```
infra/
├── Makefile          the lifecycle commands - start here
├── cloud-init/       declarative VM provisioning (your first Infrastructure as Code)
├── scripts/          lifecycle helpers used by the Makefile
└── chaos/            the break/fix drills. Run them; do not read them.
```

---

## The commands you will actually use

```bash
cd infra
make help                              # every target, with descriptions
make w01-up                            # create the VM(s) for a given week
make shell VM=lab                      # get a shell
make ip                                # every instance's address

make snapshot VM=lab NAME=pre-drill    # ALWAYS before a drill
make break VM=lab DRILL=01-permissions # apply a fault
make restore VM=lab NAME=pre-drill     # undo it

make down                              # stop everything (frees RAM)
make clean                             # destroy everything (irreversible)
```

Each week's `lab.md` opens with the right `make wNN-up` for that week.

---

## Machine profiles

| Profile | Weeks | Machines |
|---|---|---|
| `single` | 01–03, 06 | `lab` |
| `pair` | 04–05 | `alpha`, `beta` |
| `docker` | 07–08 | `dock` |
| `obs` | 09 | `obs` (Docker + node_exporter on the host OS) |
| `cluster` | 10–12 | `node1`, `node2`, `node3` |

On a host with 8 GB of RAM or less, add `LOWMEM=1`:

```bash
make cluster-up LOWMEM=1
```

Sizing details are in [SETUP.md](../SETUP.md#6-vm-sizing-profiles).

---

## cloud-init

Three profiles, and you should read all of them before Week 1 — they are the
first Infrastructure as Code you will meet, and the mental model transfers
directly to EC2 user-data, GCP startup scripts and OpenStack.

| File | Builds |
|---|---|
| `base.yaml` | inspection, networking and scripting tooling. Weeks 1–6 |
| `docker-node.yaml` | Docker Engine from Docker's official repository. Weeks 7–12 |
| `observability.yaml` | Docker plus `node_exporter` running on the **host OS**, not in a container. Week 9 |

Remember the three rules from Week 00: cloud-init runs **once**, it usually
fails **quietly**, and list-form `runcmd` has no shell. Always verify:

```bash
multipass exec lab -- cloud-init status --long
multipass exec lab -- sudo cat /var/log/cloud-init-output.log
```

---

## Scripts

| Script | Does |
|---|---|
| `lab-up.sh post <vm>…` | waits for cloud-init, prints a readiness table |
| `lab-up.sh hosts <vm>…` | writes peer entries into every VM's `/etc/hosts`, idempotently |
| `lab-up.sh ssh <vm>…` | generates a key, installs it, and writes an `~/.ssh/config` entry |
| `snapshot.sh {save\|restore\|list\|drop}` | snapshots that work on **either** Multipass driver — `multipass snapshot` is unsupported on LXD, so this detects the driver and uses `lxc snapshot` there |
| `lab-down.sh {stop\|nuke}` | stop, or destroy |

These are also worth reading as examples: every construct in them is taught in
Week 3, and they all pass `shellcheck` cleanly.

---

## Chaos drills

See [chaos/README.md](chaos/README.md) for the rules and the full list.

The short version: **snapshot first, do not read the script, timebox at 45
minutes, and write down every hypothesis with its test.** The scripts print
only the symptom a user would report; the real cause is recorded in a
root-only file you reveal afterwards.

Several drills deliberately damage something **one layer below** where the
symptom appears. That gap — between where it hurts and where it broke — is the
thing you are training for.
