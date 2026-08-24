# Week 00 — Pre-flight: Multipass, cloud-init, SSH

**Duration:** 1 day (do this before Week 1 starts)
**VM profile:** `make w00-up` → one VM named `lab`

---

## Why this day exists

Every hour you spend now on being able to create and destroy machines quickly pays back tenfold over the next twelve weeks. More importantly, the mental model you build today — *machines are cattle, not pets; their configuration is code; anything you did by hand is a bug* — is the single idea that separates a platform engineer from someone who administers servers.

By the end of today you will be able to say: "give me two minutes and I'll have a clean Ubuntu machine configured exactly like the last one."

---

## 00.1 — The virtual machine as a disposable object

You have probably treated computers as precious: you install things, you configure them, you avoid breaking them. Platform engineering inverts this.

| Pet | Cattle |
|---|---|
| Has a name you chose lovingly | Has a name generated from a pattern |
| Configured by hand over months | Configured by a file in git |
| Nursed back to health when sick | Destroyed and replaced when sick |
| Nobody knows how to rebuild it | Rebuilt automatically in 90 seconds |

The pet model fails at scale, and — more subtly — it fails at *correctness*. When a pet server misbehaves you can never be sure why, because its current state is the accumulation of hundreds of undocumented manual changes. That accumulated, un-reproducible state has a name: **configuration drift**, and it is responsible for an enormous share of real outages.

The whole of this course is designed so that destroying your environment is cheap. Take it seriously: **when you get badly stuck, destroy the VM and start over.** That is not giving up, it is the professional reflex.

---

## 00.2 — The Multipass command surface

Six commands cover 95% of your use:

```bash
multipass launch 24.04 --name lab      # create
multipass list                          # what exists, what state, what IP
multipass shell lab                     # interactive shell
multipass exec lab -- <command>          # one command, script-friendly
multipass stop lab                       # power off, keep the disk
multipass delete --purge lab             # destroy irreversibly
```

Two subtleties that catch beginners:

**`shell` vs `exec`.** `multipass shell` gives you an interactive session — good for exploring. `multipass exec` runs one command and returns its exit code — good for scripts. Note the `--`: everything after it belongs to the *guest* command, not to Multipass. Without it, Multipass tries to interpret your flags:

```bash
multipass exec lab -- ls -la /etc     # correct
multipass exec lab ls -la /etc        # -la is eaten by multipass; confusing errors
```

**`stop` vs `delete`.** `stop` is a power-off; `delete` destroys. `delete` without `--purge` leaves the instance recoverable (`multipass recover`) until you run `multipass purge`. In this course we almost always want `--purge`.

---

## 00.3 — cloud-init: your first Infrastructure as Code

When you launch a VM with `--cloud-init base.yaml`, Ubuntu reads that file on first boot and configures itself. This is not a Multipass feature — it is the standard mechanism every major cloud uses to bootstrap Linux machines. Learning it here transfers directly to AWS EC2 user-data, GCP startup scripts, and OpenStack.

Open `infra/cloud-init/base.yaml` and read every line before you continue. Its four important sections:

```yaml
#cloud-config          # ← THIS LINE IS MANDATORY and must be first. Without it,
                       #   the file is treated as an opaque script and silently
                       #   does nothing you expect.

packages:              # what to install
  - jq

write_files:           # files to create, with content, ownership and mode
  - path: /etc/profile.d/99-lab.sh
    permissions: '0644'
    content: |
      export EDITOR=vim

runcmd:                # commands to run, once, at the end of first boot
  - [ systemctl, enable, --now, docker ]
```

### The three rules of cloud-init that everyone learns the hard way

1. **It runs once, on first boot.** Editing the YAML afterwards does nothing to a running VM. To apply a change you launch a *new* VM. This feels wasteful and is in fact the point: it forces your configuration to be complete and reproducible rather than accumulating manual patches.

2. **When it fails, it usually fails quietly.** The VM boots fine; your package just isn't there. Always verify:
   ```bash
   multipass exec lab -- cloud-init status --long
   multipass exec lab -- sudo cat /var/log/cloud-init-output.log
   ```
   That second file is the transcript of everything cloud-init did, including the output of every `runcmd`. It is the first place to look, always.

3. **`runcmd` list-form vs string-form differ.** `- [ systemctl, enable, docker ]` executes directly with no shell — so no pipes, no `&&`, no globs, no `$VAR`. `- systemctl enable docker && echo done` runs through a shell, so all of that works. Use list-form by default (it is immune to quoting bugs) and string-form only when you genuinely need shell features.

---

## 00.4 — SSH: the actual tool of the trade

`multipass shell` is a convenience wrapper. In every real job you will use **SSH**, and you must understand its model.

SSH authenticates with a **keypair**: a private key that never leaves your machine, and a public key you copy to every server you want to reach. The server encrypts a challenge with your public key; only your private key can answer it. No password crosses the network, and a stolen server database contains only public keys, which are useless to an attacker.

```bash
ssh-keygen -t ed25519 -C "you@laptop"    # generates ~/.ssh/id_ed25519{,.pub}
```

- Use **ed25519**, not RSA: shorter, faster, and no key-size footguns.
- **`-N ''` (empty passphrase) is acceptable in this lab and unacceptable in production.** A passphrase-less private key is a plaintext credential; if your laptop is stolen, so is every server. In real work, set a passphrase and use `ssh-agent`.
- The private key **must** be mode `0600`. SSH refuses to use a key that others can read, and the error message ("UNPROTECTED PRIVATE KEY FILE") confuses everybody once.

`~/.ssh/config` turns a long command into a short one:

```
Host lab
    HostName 10.223.1.42
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519
```

Now `ssh lab` works — and so does `scp file lab:/tmp/`, and so do editor remote plugins, and so does `rsync`. All of them read this file.

---

## 00.5 — How to be stuck productively

You will be stuck for a large fraction of the next twelve weeks. That is the job, not a failure of it. What distinguishes engineers is the *quality* of their stuckness.

**The loop:**

1. **State the symptom precisely.** Not "it doesn't work" but "`curl http://lab:8080` returns exit code 7 after 2 seconds, while `curl http://lab:22` connects."
2. **Form exactly one hypothesis.** "Nothing is listening on 8080."
3. **Design the cheapest test that could disprove it.** `ss -tlnp | grep 8080`.
4. **Run it. Write down the result.** Especially when it disproves you.
5. **Repeat.**

**Anti-patterns to catch yourself doing:**

- **Shotgun debugging** — changing four things then re-testing. If it works, you have learned nothing and you now have three unexplained changes in your system.
- **Rebooting hopefully.** Reboot when you have a *reason* to think state is stale, not as a prayer.
- **Reading past the error.** The error message is almost always both accurate and specific. Read it word by word. `Permission denied` and `No such file or directory` are completely different problems, and people routinely conflate them.
- **Trusting the summary.** `docker ps` says "Up". `systemctl status` says "active". Neither means the application works. Always find a way to test the actual thing a user does.

---

## Day plan

| Block | Do this |
|---|---|
| Morning | Read this file. Read `SETUP.md`. Install Multipass, complete its §9 checklist. |
| Midday | `lab.md` parts 1–3 — launch, explore, destroy, relaunch from cloud-init. |
| Afternoon | `lab.md` parts 4–5 — SSH keys, `~/.ssh/config`, snapshots. |
| Late | `challenges.md`. Start your logbook. |

## Recommended reading

- Multipass docs — <https://documentation.ubuntu.com/multipass/>
- cloud-init examples — <https://cloudinit.readthedocs.io/en/latest/reference/examples.html>
- *SSH Mastery* (Michael W. Lucas) — the free-to-read parts, or `man ssh_config`
