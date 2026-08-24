# Week 01 — Linux Foundations

**VM profile:** `make w01-up` → one VM named `lab`
**Prerequisite:** Week 00 complete; you can `ssh lab`.

> You already know how to program. This week is about the machine your programs run on — and about the fact that in Linux, *almost everything is a file*, and *almost everything is a process*. Those two sentences are not slogans; they are literally how the system is built, and once you believe them the design stops feeling arbitrary.

---

## Day 1 — The shell, the filesystem, and where things live

### 1.1 What the shell actually is

`bash` is a program that reads a line, splits it into words, expands the special ones, finds an executable matching the first word, forks a child process, and runs it. That is the entire model. Every confusing thing the shell does is one of those steps behaving exactly as specified.

The order matters enormously, and it is the source of most beginner bugs:

```
1. Split the line into words on whitespace
2. Brace expansion            {a,b}    → a b
3. Tilde expansion            ~        → /home/ubuntu
4. Parameter expansion        $HOME    → /home/ubuntu
5. Command substitution       $(date)  → Mon Aug 24 ...
6. Arithmetic expansion       $((1+1)) → 2
7. Word splitting             ← re-splits the RESULT of steps 4-6 on whitespace
8. Filename expansion (glob)  *.txt    → a.txt b.txt
9. Quote removal
10. Redirection, then execute
```

**Step 7 is the one that ruins people's day.** After `$FILE` is replaced by `my report.txt`, the shell splits it *again* into two words, and your command receives two arguments instead of one. Quoting — `"$FILE"` — suppresses step 7. This is why the rule is:

> **Quote every variable expansion, every time, unless you have a specific reason not to.**

### 1.2 Finding out what a command even is

```bash
type ls        # alias, function, builtin, or file?
type cd        # a shell builtin - there is no /bin/cd
which python3  # path of the executable that would run
command -v jq  # the portable version of `which`
```

`cd` being a builtin is not trivia: a child process cannot change its parent's working directory, so `cd` *must* be implemented inside the shell itself. Understanding that tells you why a script that `cd`s does not affect the shell you ran it from.

### 1.3 The filesystem is a single tree

There are no drive letters. There is one tree, rooted at `/`, and storage devices are *grafted onto* it at mount points.

| Path | Contains | You will care because |
|---|---|---|
| `/etc` | System-wide configuration, all text | This is where you fix things |
| `/var/log` | Logs | This is where you find out what happened |
| `/var/lib` | Persistent application state (databases, docker images) | Deleting it loses data |
| `/usr/bin`, `/usr/sbin` | Installed programs | `sbin` = historically admin tools |
| `/usr/local` | Software you installed outside the package manager | Package managers never touch it |
| `/opt` | Self-contained third-party software | Our labs live in `/opt/lab` |
| `/tmp` | Scratch, wiped on reboot | Never store anything you need |
| `/home/<user>` | User data | |
| `/proc` | **Not a real filesystem** — a live view of kernel & process state | `/proc/<pid>/` is how you inspect a running process |
| `/sys` | Live view of devices and kernel tunables | cgroups (Week 7) live here |
| `/dev` | Device files | `/dev/null`, `/dev/urandom` |

`/proc` deserves emphasis. `cat /proc/1/cmdline` shows the command line of PID 1. `cat /proc/meminfo` is where `free` gets its numbers. It is a filesystem interface to the kernel, and it is the reason "everything is a file" is a real design principle rather than a slogan.

### 1.4 Absolute vs relative, and `.` and `..`

`/etc/hosts` is absolute — unambiguous from anywhere. `etc/hosts` is relative to wherever you currently are. In scripts, **always use absolute paths or explicitly set your working directory**, because you cannot know what directory the script will be invoked from — and cron will invoke it from somewhere you did not expect.

---

## Day 2 — Permissions, ownership, and why your script can't write that file

### 2.1 Reading `ls -l`

```
-rw-r--r--  1 ubuntu ubuntu  1024 Aug 24 10:00 notes.txt
│└┬┘└┬┘└┬┘     │      │
│ │  │  └── other:  r--  read
│ │  └───── group:  r--  read
│ └──────── owner:  rw-  read, write
└────────── type:   -=file  d=directory  l=symlink
```

### 2.2 The bit that everyone gets wrong

For a **file**: `r` read contents, `w` modify contents, `x` execute it.

For a **directory**, the same letters mean something entirely different:

| Bit | On a directory means |
|---|---|
| `r` | You may **list** the names inside it |
| `w` | You may **create, rename and delete** entries inside it |
| `x` | You may **traverse** it — i.e. access things by path *through* it |

Consequences that seem paradoxical until you internalise this:

- **You can delete a file you have no write permission on**, if you can write to its directory. Deletion modifies the *directory*, not the file.
- **You can have `r` on a directory but not `x`**: you can see the names but cannot read any of them.
- **You can have `x` but not `r`**: you cannot list the directory, but if you already know a filename you can open it. This is how `/home/user` is often secured.

Drill 01 in `infra/chaos/` is built entirely on this misunderstanding.

### 2.3 Numeric modes

```
r=4  w=2  x=1
0644 = rw- r-- r--     typical file
0755 = rwx r-x r-x     typical program or directory
0600 = rw- --- ---      secrets (SSH private keys REQUIRE this)
0700 = rwx --- ---      private directory
```

### 2.4 Users, groups and root

```bash
id                          # your uid, gid, and every group you belong to
sudo -l                     # what are you allowed to run as root?
getent passwd ubuntu        # the authoritative lookup (not just /etc/passwd)
```

**`sudo` is not "become root".** It is "run *this command* as another user, subject to the policy in `/etc/sudoers`, and log it". The difference matters: `sudo` leaves an audit trail in `/var/log/auth.json` or the journal, and its policy can be narrow. A team where everyone runs `sudo su -` has thrown away both properties.

**Group membership is loaded at login.** After `usermod -aG docker ubuntu`, your *current* shell still lacks the group. `id` proves it. You need a new login session (or `newgrp docker`). Every single person hits this with Docker in Week 7.

### 2.5 Special bits worth recognising

- **setuid** (`-rwsr-xr-x`) — the program runs as its *owner*, not as you. This is how `passwd` lets you edit `/etc/shadow`. It is also a large share of local privilege-escalation vulnerabilities; `find / -perm -4000` is a standard audit step.
- **sticky bit** on a directory (`drwxrwxrwt`, as on `/tmp`) — anyone may create files, but you may only delete *your own*. Without it, world-writable shared directories are unusable.

---

## Day 3 — Text is the universal interface

Unix's core bet is that if every program reads text on stdin and writes text on stdout, then programs compose. The pipe `|` connects one program's stdout to the next one's stdin, and the whole toolbox becomes a language.

### 3.1 The three streams

| FD | Name | Default |
|---|---|---|
| 0 | stdin | keyboard |
| 1 | stdout | terminal |
| 2 | stderr | terminal |

```bash
cmd > out.txt           # stdout to file (truncates)
cmd >> out.txt          # stdout appended
cmd 2> err.txt          # stderr to file
cmd > all.txt 2>&1      # stderr to WHEREVER STDOUT NOW GOES  ← order matters
cmd 2>&1 > all.txt      # WRONG: stderr goes to the terminal; stdout to the file
cmd &> all.txt          # bash shorthand for both
cmd 2>/dev/null         # discard errors  ← usually a mistake; you just deleted the evidence
```

`2>&1 > file` vs `> file 2>&1` is a genuinely common bug. Redirections are applied **left to right**; `2>&1` copies stdout's *current* destination.

**Why separate streams exist:** so that `myscript > report.txt` writes clean data to the file while errors still reach your eyes. A program that writes errors to stdout corrupts every pipeline that consumes it.

### 3.2 The toolbox

| Tool | Job | Canonical use |
|---|---|---|
| `grep` | select lines | `grep -i error app.log` |
| `rg` | fast recursive grep | `rg -n 'timeout' /etc` |
| `cut` | extract columns by delimiter | `cut -d: -f1 /etc/passwd` |
| `awk` | field-aware processing & arithmetic | `awk '$9 >= 500 {print $7}' access.log` |
| `sed` | stream editing / substitution | `sed 's/old/new/g'` |
| `sort` | order lines | `sort -k2 -n -r` |
| `uniq -c` | count *adjacent* duplicates | always after `sort` |
| `tr` | translate/delete characters | `tr -s ' '` squeeze spaces |
| `wc -l` | count lines | |
| `head`/`tail` | ends of a stream | `tail -f` follows a growing file |
| `jq` | query JSON properly | `jq -r '.items[].name'` |

**The single most useful pipeline in operations**, which you will run hundreds of times:

```bash
awk '{print $1}' access.log | sort | uniq -c | sort -rn | head
#    ^extract field   ^group  ^count      ^rank        ^top
```

"Extract → sort → count → rank" answers *"what is happening most?"*, which is the first question in almost every incident.

`uniq` only collapses **adjacent** duplicates — that is why `sort` always comes first. Forgetting this produces silently wrong counts, which is worse than an error.

### 3.3 Never parse structured data with line tools

If the data is JSON, use `jq`. `grep '"status"' file.json` will work right up until the formatting changes and then quietly return nothing. Same for YAML (`yq`) and XML. Reaching for `grep` on structured data is a smell that a reviewer will (correctly) flag.

---

## Day 4 — Processes, signals, and resources

### 4.1 What a process is

A process is a running program with its own memory space, a numeric **PID**, a **parent** (PPID), an owner, a working directory, a set of open **file descriptors**, and an environment. Every process except PID 1 has a parent, forming a tree — `pstree -p` draws it.

PID 1 on Ubuntu is `systemd`. It is special: it adopts orphaned processes, and **if it dies the machine panics**. In a container, PID 1 is *your application*, and that has consequences you will meet in Week 7.

### 4.2 Inspecting

```bash
ps aux                       # everything, BSD syntax; the one to memorise
ps -ef --forest              # tree view, SysV syntax
ps -eo pid,ppid,user,%cpu,%mem,etime,cmd --sort=-%cpu | head
top / htop                   # live
pgrep -a nginx               # find by name, show command line
pstree -p
```

Reading `ps aux` columns: `VSZ` is virtual memory (mostly meaningless — it includes memory never touched), `RSS` is resident memory (what is actually in RAM — this is the number you usually want), `STAT` is state, `TIME` is cumulative CPU consumed.

`STAT` letters worth knowing: `R` running/runnable, `S` sleeping (waiting on something — most processes, most of the time), **`D` uninterruptible sleep (almost always blocked on disk or network I/O — a machine full of `D` processes has an I/O problem, not a CPU problem)**, `Z` zombie (finished, but its parent has not read its exit status — harmless individually, a bug in the parent if they accumulate).

### 4.3 Signals

A signal is an asynchronous notification to a process.

| Signal | Number | Meaning | Catchable? |
|---|---|---|---|
| `SIGTERM` | 15 | "Please shut down." The default of `kill`. | Yes — the program may clean up |
| `SIGINT` | 2 | Ctrl-C | Yes |
| `SIGHUP` | 1 | Terminal closed; **conventionally, "reload your config"** | Yes |
| `SIGKILL` | 9 | Die now. Handled by the kernel. | **No** |
| `SIGSTOP` / `SIGCONT` | 19/18 | Pause / resume | No / Yes |

```bash
kill 1234            # sends SIGTERM - the polite default
kill -HUP $(pidof nginx)
kill -9 1234         # last resort
```

> **`kill -9` is not "kill harder", it is "kill without letting it clean up".** The process gets no chance to flush buffers, finish a transaction, remove a lock file or deregister from a load balancer. Reaching for `-9` first is a habit that eventually corrupts data. Send `SIGTERM`, wait a few seconds, and only then escalate. This is exactly the sequence `docker stop` and `systemd` use, and Week 7 shows you the timeout knob.

### 4.4 Where resources are spent

```bash
uptime                       # load average: 1, 5, 15 minutes
free -h                      # memory - read the "available" column, not "free"
df -h                        # disk space per filesystem
df -i                        # disk INODES  ← check this too; drill 02b depends on it
du -xh --max-depth=1 /var | sort -h    # what is big under here
ncdu /var                    # interactive version
lsof -p <pid>                # every file this process has open
```

**Load average is not CPU percentage.** It is the average number of processes runnable *or* blocked on uninterruptible I/O. Compare it to your core count: load 2.0 on 2 cores is fully busy; on 8 cores it is idle. Load 8.0 on 2 cores means six units of work are *waiting* — that is saturation, and saturation is what users experience as slowness.

**`free -h`: read `available`, not `free`.** Linux deliberately uses spare RAM as disk cache, so `free` is almost always small. That is the system working correctly, not a problem. `available` estimates what a new process could get.

---

## Day 5 — Consolidation, drills, and the method

Day 5 is `challenges.md` plus your first two chaos drills:

```bash
cd infra
make snapshot VM=lab NAME=pre-w01
make break VM=lab DRILL=01-permissions
```

**The method you are drilling** — write it on a sticky note:

1. **Reproduce it.** If you cannot make it fail on demand, you cannot know when you have fixed it.
2. **Read the whole error, including the errno.** `Permission denied` (EACCES) and `No such file or directory` (ENOENT) send you to completely different places.
3. **Identify the layer.** Is it the file? the process? the user? the network? the application? Prove which one before descending into it.
4. **One hypothesis, one test.** Write both down.
5. **Fix the cause, not the symptom.** `chmod 777` makes the symptom disappear and creates a security finding. Ask *why* the permission was wrong.
6. **Verify by reproducing the original failing command** — not by "it looks fine now".

## Recommended reading

- *The Linux Command Line*, William Shotts — free PDF at <https://linuxcommand.org/tlcl.php>. Chapters 1–10 for this week.
- `man hier` — the filesystem hierarchy, straight from the system.
- Julia Evans' free zines and posts — <https://jvns.ca/> — especially on `strace`, `ps` and networking.
- <https://explainshell.com/> — paste any command line and it annotates every flag.
