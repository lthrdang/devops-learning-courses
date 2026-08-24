# SETUP — Building your lab environment

You need exactly one thing to run this entire course: a machine that can run **Multipass**. This document gets you there and explains the two situations that trip people up most — no hardware virtualisation, and not enough RAM.

Official documentation, which you should bookmark now: <https://documentation.ubuntu.com/multipass/>

---

## 1. What Multipass is, and why this course uses it

Multipass is a Canonical tool that creates **Ubuntu virtual machines** with one command:

```bash
multipass launch --name web 24.04
```

We use VMs instead of running everything directly on your laptop for three reasons that matter pedagogically:

1. **You can destroy them.** An engineer who is afraid of breaking their environment learns slowly. Here, `multipass delete --purge web` costs you 40 seconds and you start clean.
2. **They are real Linux machines with real network interfaces.** You cannot learn routing, firewalls or load balancing on a single host with no peers. From Week 4 onward you run 2–4 VMs at once and make them talk to each other.
3. **They are reproducible.** The `cloud-init` files in `infra/cloud-init/` describe each machine declaratively. That is the same mental model as Dockerfiles, Ansible and Terraform — you meet it in Week 0 rather than Week 11.

---

## 2. Host requirements

| | Minimum | Comfortable |
|---|---|---|
| CPU cores | 2 | 4+ |
| RAM | 8 GB | 16 GB |
| Free disk | 40 GB | 80 GB |
| OS | Linux, macOS 11+, Windows 10/11 Pro | any |

Weeks 10–12 run a **3-node Swarm cluster**. On an 8 GB host that is tight but workable with the low-memory profile in §6.

Your host must have **hardware virtualisation available** (see §4.1). A laptop running its normal OS has this. A cloud VM, a corporate VDI or a machine that is already a guest usually does not.

---

## 3. Install

### Linux (any distro with snap)

```bash
sudo snap install multipass
multipass version
```

### macOS

```bash
brew install --cask multipass
```

Or download the `.pkg` installer from <https://canonical.com/multipass/download/macos>.

### Windows

Download the installer from <https://canonical.com/multipass/download/windows>. The default driver is Hyper-V, which requires **Windows Pro / Enterprise / Education** — Windows Home cannot enable Hyper-V. On Home, install VirtualBox and switch driver:

```powershell
multipass set local.driver=virtualbox
```

### Verify the install

```bash
multipass launch --name hello 24.04
multipass exec hello -- lsb_release -d
multipass delete --purge hello
```

If those three commands succeed, you are ready. If not, read §4.

---

## 4. Troubleshooting the install

### 4.1 Launch fails with a KVM/virtualisation error, or hangs forever (Linux)

Multipass on Linux defaults to the **QEMU driver**, which needs hardware virtualisation (Intel VT-x / AMD-V) exposed to your OS. Diagnose:

```bash
ls -l /dev/kvm                      # should exist
egrep -c '(vmx|svm)' /proc/cpuinfo  # should be greater than 0
systemd-detect-virt                 # "none" = bare metal; anything else = you are already inside a VM
```

**Cause (a) — virtualisation disabled in firmware.** Reboot into BIOS/UEFI, enable `Intel VT-x` or `AMD SVM`, save, reboot.

**Cause (b) — your machine is itself a VM without nested virtualisation.** `systemd-detect-virt` prints `kvm`, `qemu`, `vmware`…, and `/dev/kvm` is missing. Nesting is a host-side setting; you cannot turn it on from inside the guest.

> **Workaround: the LXD driver.** LXD creates *system containers* rather than VMs. They share the host kernel, so they need no hardware virtualisation, boot in about two seconds, and use far less RAM.
>
> ```bash
> sudo snap install lxd
> sudo lxd init --auto
> sudo usermod -aG lxd "$USER"
> newgrp lxd                       # or log out and back in
>
> sudo snap connect multipass:lxd  # allow Multipass to drive LXD
> multipass set local.driver=lxd
>
> multipass launch --name hello 24.04 && multipass exec hello -- uname -a
> ```
>
> **What the LXD driver costs you — read this, it matters:**
>
> - **The kernel belongs to the host.** You cannot load kernel modules, change non-namespaced `sysctl` values, or study the boot process. Week 2 marks the two exercises affected and gives alternatives.
> - **Snapshots work differently** — see §7.
> - `systemd-detect-virt` reports `lxc`. Cosmetic, but do not let it confuse you.
>
> Everything else in this course — Docker, Swarm overlay networks, nftables, tcpdump, systemd units, journald — behaves normally. On a host without KVM this is the recommended path, not a compromise.

### 4.2 `launch failed: Remote "" is unknown`

The image index is stale, or this is a first run with no network:

```bash
multipass find                 # refreshes the available image list
sudo snap restart multipass
```

### 4.3 The VM launches but `multipass exec` hangs

Usually `cloud-init` has not finished provisioning. Watch it:

```bash
multipass exec NAME -- cloud-init status --wait
```

If it reports `error`, read `/var/log/cloud-init-output.log` **inside the VM**. That file explains 95% of provisioning failures, and reading it is your first real log-reading exercise of the course.

### 4.4 Disk filling up with old images and instances

```bash
multipass list
multipass delete --purge NAME
multipass purge                # permanently remove everything already deleted
```

---

## 5. The networking model — understand this before Week 4

Multipass places every instance on a **NAT'd bridge** (`mpqemubr0` with QEMU, `lxdbr0` with LXD). The consequences you must internalise:

- **VMs can reach the internet**, outbound, via NAT.
- **VMs can reach each other** by IP address.
- **Your host can reach the VMs** at their `10.x` / `192.168.x` addresses.
- **The outside world cannot reach your VMs.** There is no inbound port forwarding by default. When Week 5 says "test the load balancer", you test it from the host or from another VM — not from your phone.

Find addresses at any time:

```bash
multipass list
multipass info --all
```

**An instance's IP can change when it is restarted.** Do not hard-code addresses in scripts. This is a lesson rather than an annoyance, and Week 4 turns it into an exercise on `/etc/hosts` and DNS.

---

## 6. VM sizing profiles

`infra/Makefile` applies the right profile per week; these are the numbers behind it.

| Profile | Used in | Spec | Total RAM |
|---|---|---|---|
| `single` | Weeks 1–3, 6 | 1 VM × 2 CPU / 2 GB / 10 GB | 2 GB |
| `pair` | Weeks 4–5 | 2 VMs × 1 CPU / 1 GB / 8 GB | 2 GB |
| `docker` | Weeks 7–9 | 1 VM × 2 CPU / 3 GB / 20 GB | 3 GB |
| `cluster` | Weeks 10–12 | 3 VMs × 1 CPU / 1.5 GB / 12 GB | 4.5 GB |

Launching with an explicit profile looks like this:

```bash
multipass launch 24.04 --name node1 --cpus 1 --memory 1.5G --disk 12G \
  --cloud-init infra/cloud-init/docker-node.yaml
```

### On an 8 GB host

```bash
cd infra && make cluster-up LOWMEM=1     # 3 nodes × 1 GB, observability stack scaled down
```

And stop what you are not using — an idle running VM still holds its RAM under the QEMU driver:

```bash
multipass stop --all
```

---

## 7. Snapshots — your undo button

Take a snapshot before every break/fix drill. This one habit is what makes the course safe to fail in.

```bash
multipass stop web
multipass snapshot web --name clean-w04 --comment "before firewall drill"
multipass start web

# ... you break everything ...

multipass stop web
multipass restore web.clean-w04 --destructive
multipass start web
```

Inspect and clean up:

```bash
multipass list --snapshots
multipass delete web.clean-w04 --purge
```

> **Driver caveat:** snapshots are supported on the QEMU and Hyper-V drivers, **not on LXD**. `infra/scripts/snapshot.sh` detects your driver and uses the native LXD equivalent when needed, so use it rather than calling `multipass snapshot` directly:
>
> ```bash
> ./infra/scripts/snapshot.sh save    web clean-w04
> ./infra/scripts/snapshot.sh restore web clean-w04
> ./infra/scripts/snapshot.sh list    web
> ```

---

## 8. Working comfortably

### Getting a shell

```bash
multipass shell web          # simplest
multipass exec web -- <cmd>  # run one command; use this in scripts
```

### Real SSH (configured in Week 0, used from Week 2 onward)

`multipass shell` is convenient, but it is not SSH — and SSH is a skill you must own. Week 0's lab sets up key-based authentication and an `~/.ssh/config` entry so that `ssh web` works from your host terminal, your editor's remote plugin, and your scripts.

### Sharing a folder from host into a VM

```bash
multipass mount ~/code/devops-learning-courses web:/home/ubuntu/course
multipass umount web:/home/ubuntu/course
```

Handy for editing lab files in your host editor while running them inside the VM.

---

## 9. Pre-flight checklist

Do not start Week 1 until every one of these prints what it should:

```bash
multipass version                                   # a version number
multipass launch --name preflight 24.04             # succeeds
multipass exec preflight -- nproc                   # a number
multipass exec preflight -- free -m                 # a memory table
multipass exec preflight -- ping -c1 1.1.1.1        # 1 packet received
multipass exec preflight -- sudo apt-get update     # completes without error
multipass delete --purge preflight                  # cleans up
```

All seven passing means your lab works. Open `week-00-preflight/README.md`.
