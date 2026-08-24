#!/usr/bin/env bash
# DRILL 01 - permissions & ownership.  Week 01.
# Do not read this file before attempting the drill.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

install -d -m 0755 /opt/lab/reports
cat > /opt/lab/report.sh <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
out=/opt/lab/reports/disk-$(date +%F).txt
df -h > "$out"
echo "wrote $out"
INNER
chmod 0755 /opt/lab/report.sh
chown ubuntu:ubuntu /opt/lab/report.sh

# --- the damage ---
# The directory the script writes into is owned by root and not group-writable.
# 'ubuntu' can traverse it (x) and list it (r) but cannot create files in it (w).
chown root:root /opt/lab/reports
chmod 0755 /opt/lab/reports
# Second, subtler layer: the log file the user is told to check is unreadable,
# so a careless learner concludes "there are no logs" instead of "I am denied".
: > /var/log/lab-report.log
chown root:root /var/log/lab-report.log
chmod 0600 /var/log/lab-report.log
echo "$(date -Is) report.sh invoked" >> /var/log/lab-report.log

base64 -w0 > /root/.drill-01-permissions <<'NOTE'
CAUSE: /opt/lab/reports is owned root:root mode 0755, so user 'ubuntu' has no
write bit on the directory and cannot create a file inside it. Directory write
permission - not file permission - controls file creation.
SECOND FAULT: /var/log/lab-report.log is mode 0600 root:root, so `cat` as ubuntu
gives "Permission denied", which is NOT the same as "the log is empty".
FIX: chown ubuntu:ubuntu /opt/lab/reports  (or chgrp + chmod g+w)
     chmod 0644 /var/log/lab-report.log
LESSON: read the exact errno. "Permission denied" on a *directory* almost always
means the write/execute bit on the directory, not on the file you are creating.
NOTE
chmod 0600 /root/.drill-01-permissions

cat <<'MSG'

  SYMPTOM REPORTED BY THE USER
  ----------------------------
  "I run /opt/lab/report.sh as the ubuntu user and it prints nothing useful and
   exits non-zero. It worked on my other machine. There's a log at
   /var/log/lab-report.log but it looks empty to me."

  Reproduce it:   sudo -u ubuntu /opt/lab/report.sh ; echo "exit=$?"

MSG
