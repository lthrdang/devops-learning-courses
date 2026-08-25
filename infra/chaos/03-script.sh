#!/usr/bin/env bash
# DRILL 03 - a backup script that lies about succeeding.  Week 03.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

install -d -m 0755 /opt/lab/data /opt/lab/backups
for i in 1 2 3; do echo "record ${i}" > "/opt/lab/data/file${i}.txt"; done

# --- the damage: a plausible, badly written script ---
# Three planted faults; the key is in /root/.drill-03-script. Nothing inside the
# heredoc may name them - this file lands on the learner's VM, so a comment in
# here turns `cat /opt/lab/backup.sh` into the answer sheet.
cat > /opt/lab/backup.sh <<'INNER'
#!/bin/bash
# Nightly backup of /opt/lab/data
SRC=/opt/lab/data
DEST=/opt/lab/backups
STAMP=$(date +%Y%m%d-%H%M%S)

ARCHIVE=$BACKUP_ROOT/archive-$STAMP.tar.gz

tar -czf $ARCHIVE $SRC 2>/dev/null

echo "backup written to $ARCHIVE"
if [ $? -eq 0 ]; then
  echo "$(date -Is) backup OK" >> /var/log/lab-backup.log
  exit 0
fi
echo "$(date -Is) backup FAILED" >> /var/log/lab-backup.log
exit 1
INNER
chmod 0755 /opt/lab/backup.sh
: > /var/log/lab-backup.log
chmod 0644 /var/log/lab-backup.log
bash /opt/lab/backup.sh >/dev/null 2>&1 || true

base64 -w0 > /root/.drill-03-script <<'NOTE'
THREE INDEPENDENT BUGS in /opt/lab/backup.sh:
1. $BACKUP_ROOT is undefined, so ARCHIVE becomes "/archive-<stamp>.tar.gz".
   Without `set -u` bash silently substitutes an empty string. Adding
   `set -euo pipefail` turns this into an immediate, loud failure.
2. `tar ... 2>/dev/null` throws away the only diagnostic there was, and the
   script never checks tar's exit status.
3. `echo "..."` runs BEFORE `if [ $? -eq 0 ]`, so $? is echo's status, which is
   effectively always 0. The script therefore logs "backup OK" unconditionally.
   $? must be captured immediately after the command you care about, or better,
   used directly: `if tar -czf "$ARCHIVE" "$SRC"; then ...`
FIX: set -euo pipefail; quote every expansion; give BACKUP_ROOT a default
     (${BACKUP_ROOT:=/opt/lab/backups}); test tar directly; verify the artefact
     exists and is non-empty before declaring success.
LESSON: a backup that is never restore-tested is not a backup. Any script that
        reports success must verify the artefact, not the absence of complaints.
        Run `shellcheck /opt/lab/backup.sh` - it finds bugs 1 and 3 instantly.
NOTE
chmod 0600 /root/.drill-03-script

cat <<'MSG'

  SYMPTOM REPORTED BY THE USER
  ----------------------------
  "The nightly backup job has been logging 'backup OK' every night for three
   weeks. I went to restore a file today and /opt/lab/backups is empty."

  Reproduce it:   sudo /opt/lab/backup.sh ; echo "exit=$?"
                  ls -la /opt/lab/backups ; tail /var/log/lab-backup.log

MSG
