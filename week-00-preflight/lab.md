# Week 00 — Lab

> **Reminder:** type the commands. Do not paste. Before each one, say what you expect.

---

## Part 1 — Birth and death of a machine

```bash
# 1.1 Create your first VM. Time it.
time multipass launch 24.04 --name scratch

# 1.2 What did you get?
multipass list
multipass info scratch
```

**Answer in your logbook before continuing:**
- How much RAM and disk did it get? Where did those defaults come from?
- What IP address does it have? Which subnet is that in?
- What does `State` say?

```bash
# 1.3 Go inside and look around.
multipass shell scratch
```

Inside the VM:

```bash
whoami                 # who are you?
hostname               # what is this machine called?
uname -a               # what kernel?
nproc ; free -h ; df -h
ip -brief address      # network interfaces, compact form
exit
```

```bash
# 1.4 The same information without opening a shell:
multipass exec scratch -- nproc
multipass exec scratch -- free -h

# 1.5 Now destroy it.
multipass delete scratch
multipass list                 # note the state
multipass purge
multipass list                 # gone
```

> **Checkpoint:** you should be able to explain the difference between the states after `delete` and after `purge`.

---

## Part 2 — Provisioning declaratively

```bash
# 2.1 Read the file first. All of it.
less infra/cloud-init/base.yaml

# 2.2 Launch with it.
cd infra
make w00-up
```

`make w00-up` runs `multipass launch` with the cloud-init file and then waits for provisioning. Watch what it waits for:

```bash
# 2.3 Provisioning status
multipass exec lab -- cloud-init status --long

# 2.4 The full transcript - READ THIS, do not skim it.
multipass exec lab -- sudo less /var/log/cloud-init-output.log
```

Find in that log:
- the `apt-get install` line and the packages it installed;
- any warnings;
- the `final_message` at the very end.

```bash
# 2.5 Prove the configuration took effect.
multipass exec lab -- which jq tree htop shellcheck
multipass exec lab -- cat /opt/lab/.provisioned
multipass exec lab -- bash -lc 'echo $EDITOR'
```

> **Why `bash -lc`?** `-l` makes it a *login* shell, which is what sources `/etc/profile.d/*.sh`. Without `-l`, `$EDITOR` is empty and you would wrongly conclude cloud-init failed. This distinction — login vs non-login, interactive vs non-interactive shells — causes a genuinely large number of "works when I type it, fails from cron" bugs. Week 3 returns to it.

### 2.6 Make a change the right way

Add `ncdu` and a second environment variable to `base.yaml`... then answer: **how do you apply it to the running `lab` VM?**

The answer is that you do not. You destroy and relaunch:

```bash
multipass delete --purge lab
make w00-up
multipass exec lab -- which ncdu
```

Feel how cheap that was. That feeling is the deliverable of this week.

---

## Part 3 — Two machines, and the network between them

```bash
multipass launch 24.04 --name alpha --cpus 1 --memory 1G --disk 8G
multipass list
```

```bash
# 3.1 Can lab reach alpha? Find alpha's IP from the list output, then:
multipass exec lab -- ping -c3 <ALPHA_IP>

# 3.2 Can it reach it by NAME?
multipass exec lab -- ping -c3 alpha
```

That second command probably fails. **Do not fix it yet — explain it.** Where would `lab` have to look to turn the word `alpha` into an IP address? (Week 4 answers this properly; today, just form the question.)

```bash
# 3.3 The blunt fix, applied for you:
./scripts/lab-up.sh hosts lab alpha
multipass exec lab -- ping -c2 alpha
multipass exec lab -- getent hosts alpha
```

```bash
# 3.4 Now restart alpha and see what breaks.
multipass stop alpha && multipass start alpha
multipass list                              # did the IP change?
multipass exec lab -- ping -c2 alpha        # still works?
```

> **Logbook:** write down what you just learned about hard-coding IP addresses. This is a preview of why DNS and service discovery exist.

---

## Part 4 — SSH properly

```bash
# 4.1 Generate a key (on your HOST, not in the VM)
ssh-keygen -t ed25519 -C "lab@$(hostname)" -f ~/.ssh/lab_ed25519 -N ''

# 4.2 Look at both halves
ls -l ~/.ssh/lab_ed25519*
cat ~/.ssh/lab_ed25519.pub          # safe to share - this goes on servers
# Do NOT cat the private key into a chat, a ticket, or a screen share. Ever.
```

```bash
# 4.3 Install the public key into the VM
cat ~/.ssh/lab_ed25519.pub | multipass exec lab -- bash -c \
  'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'

# 4.4 Connect for real
LAB_IP=$(multipass info lab --format csv | awk -F, 'NR>1{print $3}')
ssh -i ~/.ssh/lab_ed25519 ubuntu@"$LAB_IP"
```

The first connection asks you to verify a host key fingerprint. **Read the prompt.** Type `yes` and understand that you have just accepted, on trust, the identity of a machine — in production this is exactly where a man-in-the-middle attack would live, and why organisations distribute known host keys in advance.

```bash
# 4.5 Make it short
cat >> ~/.ssh/config <<EOF

Host lab
    HostName ${LAB_IP}
    User ubuntu
    IdentityFile ~/.ssh/lab_ed25519
EOF
chmod 600 ~/.ssh/config

ssh lab                        # should just work
ssh lab 'uptime'               # run one command remotely
scp /etc/hostname lab:/tmp/    # copy a file
```

### 4.6 Break it deliberately

```bash
ssh lab 'chmod 644 ~/.ssh/authorized_keys'      # loosen permissions
ssh lab 'echo still in?'                        # does it still work?
ssh lab 'chmod 700 ~/.ssh'
```

Then, on the host:

```bash
chmod 644 ~/.ssh/lab_ed25519
ssh lab                                          # read the error carefully
chmod 600 ~/.ssh/lab_ed25519
```

Record both error messages verbatim in your logbook. You will meet them again.

---

## Part 5 — Snapshots: making failure cheap

```bash
cd infra
./scripts/snapshot.sh save lab clean-base
./scripts/snapshot.sh list lab
```

Now vandalise the machine:

```bash
multipass exec lab -- sudo rm -rf /etc/apt
multipass exec lab -- sudo apt-get update      # observe the failure
```

Recover:

```bash
./scripts/snapshot.sh restore lab clean-base
multipass exec lab -- sudo apt-get update      # healthy again
```

> **Checkpoint:** from now on, you snapshot before every drill. If you skip this and lose an hour rebuilding, that is the lesson.

---

## Part 6 — Clean up

```bash
multipass delete --purge alpha
multipass stop lab
```

Leave `lab` stopped, not deleted — Week 1 uses it.
