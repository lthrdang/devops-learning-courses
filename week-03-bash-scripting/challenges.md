# Week 03 — Challenges

---

### C3.1 — The log analyser

Write `analyse.sh` that takes an nginx access log and prints a report:

```
Requests:      5000
Time range:    01/Mar/2026:00:00:00 .. 01/Mar/2026:23:36:23
Error rate:    19.2%  (960 of 5000)
5xx rate:       5.9%

Top paths                        Top clients               Status codes
  530  /health                     831  10.0.0.12            3655  200
  ...
```

Requirements: reads from a file argument **or** stdin; `-n N` controls how many rows per section; exits non-zero if the 5xx rate exceeds a `-t THRESHOLD`; passes `shellcheck`; handles an empty file without dividing by zero.

That last requirement is the interesting one.

---

### C3.2 — Make `backup.sh` restorable

Add a `restore` mode: `backup.sh restore -a ARCHIVE -d DEST`. It must verify the checksum before extracting, refuse to overwrite a non-empty destination unless `-f` is given, and support `--dry-run` to list what *would* be extracted.

Then perform a **real restore drill**: delete the source data entirely, restore from an archive, and verify byte-for-byte that you got it back. Write down how long it took.

> An untested backup is not a backup. Most organisations discover this on the day it matters.

---

### C3.3 — The rollout script

Write `rollout.sh` that deploys a file to a list of hosts, one at a time, with a health check between each:

- reads hosts from a file;
- for each host: copy the file, restart a service, wait for the health endpoint to return 200 (with a timeout);
- if a host fails the health check, **stop immediately** and report which hosts were already updated;
- `--dry-run` shows the plan;
- `--parallel N` (stretch) does N at a time.

Test it against your `lab` and `alpha` VMs. Then deliberately break the health endpoint on the second host and confirm the rollout halts rather than continuing.

---

### C3.4 — Find the bug

Each of these has at least one bug. Find them all without running anything, then run them to confirm.

```bash
# A
files=$(ls /var/log/*.log)
for f in $files; do
    lines=$(wc -l < $f)
    echo "$f has $lines lines"
done

# B
if [ $USER = "root" ]; then echo "running as root"; fi

# C
tmp=/tmp/work.$$
mkdir $tmp
process_data > $tmp/out
mv $tmp/out /final/location
rm -rf $tmp

# D
count=0
grep ERROR app.log | while read line; do
    count=$((count + 1))
done
if [ $count -gt 10 ]; then alert; fi

# E
VERSION=$(curl -s https://api.example.com/version)
echo "deploying $VERSION"
docker run myapp:$VERSION
```

For each, state the bug, the circumstances under which it bites, and the fix.

---

### C3.5 — Bash to Python

Take the log analyser from C3.1 and identify the exact point at which it should have been written in Python instead. Write two paragraphs justifying the boundary you chose. Then re-implement one function of it in Python and compare the two for readability, testability and speed on a 1 GB log.

---

### C3.6 — The 3am script

Write a script you would be willing to have a colleague run, as root, at 3am, in a production incident, having never read it. It should clear disk space on a full filesystem.

It must: identify the largest consumers, distinguish deleted-but-open files from real ones, never delete anything without an explicit confirmation or `--yes`, log everything it does to a file that survives, and refuse to run on `/` unless forced.

Then write the paragraph you would put at the top of the file explaining what it will and will not do. Judge the script by that paragraph.
