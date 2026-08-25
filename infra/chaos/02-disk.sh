#!/usr/bin/env bash
# DRILL 02b - "no space left on device" with a disk that looks half empty. Week 02.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

# --- the damage ---
# A small dedicated filesystem whose INODES are exhausted, not its blocks.
# df -h shows plenty of free space; df -i tells the truth.
install -d -m 0755 /opt/lab/spool
if ! mountpoint -q /opt/lab/spool; then
  dd if=/dev/zero of=/opt/lab/.spool.img bs=1M count=64 status=none
  mkfs.ext4 -q -N 512 -F /opt/lab/.spool.img          # only 512 inodes
  mount -o loop /opt/lab/.spool.img /opt/lab/spool
fi
chmod 0777 /opt/lab/spool
# Burn every inode with empty files.
for i in $(seq 1 600); do : > "/opt/lab/spool/msg-${i}" 2>/dev/null || break; done

# Layer two: a deleted-but-still-open file on the root filesystem. Classic.
# du cannot see it because it has no directory entry; the space is only freed
# when the holding process closes the descriptor or dies.
# The payload is inlined rather than written to /opt/lab/.holder.sh, because a
# script left sitting next to the damage is an answer sheet: five readable lines
# that hand over the whole trick to anyone who runs `ls -a /opt/lab` before they
# run `df -i`. Inlined, the only way to it is through the evidence - lsof, or
# /proc/<pid>/fd - which is the skill the drill is for.
setsid bash -c '
f=/var/log/lab-ghost.log
exec 9>"$f"
rm -f "$f"
dd if=/dev/zero of=/proc/self/fd/9 bs=1M count=300 status=none 2>/dev/null || true
sleep infinity
' >/dev/null 2>&1 < /dev/null &
sleep 2

base64 -w0 > /root/.drill-02-disk <<'NOTE'
CAUSE 1: /opt/lab/spool is a small ext4 image created with only 512 inodes and
they are all consumed by empty files. `df -h` shows free BLOCKS; `df -i` shows
zero free INODES. Every filesystem has both limits, and either can run out.
   Find it with:  df -i
   Fix:           rm /opt/lab/spool/msg-*
CAUSE 2: a background process holds an open file descriptor to
/var/log/lab-ghost.log, which has already been unlinked, occupying ~300 MB on /.
`du` walks directory entries, so it cannot see it; the kernel frees the blocks
only when the last fd closes.
   Find it with:  sudo lsof +L1        (link count < 1)
             or:  sudo ls -l /proc/*/fd | grep deleted
   Fix:           kill the holding process, or truncate via /proc/PID/fd/N
LESSON: "df says full, du says empty" has exactly two usual causes - deleted
        open files, and something mounted over a directory that still has data
        underneath it. And always check df -i before you believe df -h.
TEARDOWN: fixing the two causes does not undo the setup. Left behind are the loop
        mount on /opt/lab/spool, its backing image /opt/lab/.spool.img, and the
        holder process if you only truncated its fd. Clean up by hand with:
             sudo pkill -f lab-ghost.log
             sudo umount /opt/lab/spool && sudo rm -f /opt/lab/.spool.img
        `make restore` reverts all of it, because it rolls the whole disk back.
        A plain reboot does NOT: it kills the holder and drops the mount, so the
        symptom appears to fix itself while the image file sits there waiting to
        confuse the next session. "It went away on its own" is never a fix.
NOTE
chmod 0600 /root/.drill-02-disk

cat <<'MSG'

  SYMPTOM REPORTED BY THE USER
  ----------------------------
  "Writes into /opt/lab/spool fail with 'No space left on device'. But df -h
   says that filesystem is only 3% used, so that makes no sense. Separately, the
   root filesystem has lost about 300 MB since this morning and `du -sh /` does
   not account for it."

  Reproduce it:   touch /opt/lab/spool/hello
                  df -h /opt/lab/spool

MSG
