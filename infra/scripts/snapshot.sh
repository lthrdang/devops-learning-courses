#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# snapshot.sh - take / restore / list VM snapshots, on either Multipass driver.
#
#   snapshot.sh save    <vm> <label>
#   snapshot.sh restore <vm> <label>
#   snapshot.sh list    <vm>
#   snapshot.sh drop    <vm> <label>
#
# WHY THIS WRAPPER EXISTS:
# `multipass snapshot` is supported on the qemu and hyperv drivers but NOT on
# the lxd driver. On lxd we call `lxc snapshot` directly against the same
# instance. Detecting a capability at runtime instead of assuming it is a habit
# worth forming early.
# ---------------------------------------------------------------------------
set -euo pipefail

log() { printf '[snap] %s\n' "$*"; }
die() { printf '[snap] %s\n' "$*" >&2; exit 1; }

driver() { multipass get local.driver 2>/dev/null || echo qemu; }

save() {
  local vm=$1 label=$2
  case "$(driver)" in
    lxd)
      log "lxd driver: lxc snapshot ${vm}/${label}"
      lxc snapshot "$vm" "$label"
      ;;
    *)
      log "stopping ${vm} (multipass requires a stopped instance to snapshot)"
      multipass stop "$vm"
      multipass snapshot "$vm" --name "$label" --comment "course lab: ${label}"
      multipass start "$vm"
      ;;
  esac
  log "saved '${label}' for ${vm}"
}

restore() {
  local vm=$1 label=$2
  case "$(driver)" in
    lxd)
      log "lxd driver: lxc restore ${vm} ${label}"
      lxc restore "$vm" "$label"
      ;;
    *)
      multipass stop "$vm"
      # --destructive skips the "snapshot your current state first?" prompt.
      multipass restore "${vm}.${label}" --destructive
      multipass start "$vm"
      ;;
  esac
  log "restored ${vm} to '${label}'"
}

list() {
  local vm=$1
  case "$(driver)" in
    lxd) lxc info "$vm" | sed -n '/Snapshots:/,$p' ;;
    *)   multipass list --snapshots | awk -v n="$vm" 'NR==1 || $1==n' ;;
  esac
}

drop() {
  local vm=$1 label=$2
  case "$(driver)" in
    lxd) lxc delete "${vm}/${label}" ;;
    *)   multipass delete "${vm}.${label}" --purge ;;
  esac
  log "deleted snapshot '${label}' of ${vm}"
}

case "${1:-}" in
  save)    [[ $# -eq 3 ]] || die "usage: snapshot.sh save <vm> <label>";    save    "$2" "$3" ;;
  restore) [[ $# -eq 3 ]] || die "usage: snapshot.sh restore <vm> <label>"; restore "$2" "$3" ;;
  list)    [[ $# -eq 2 ]] || die "usage: snapshot.sh list <vm>";            list    "$2" ;;
  drop)    [[ $# -eq 3 ]] || die "usage: snapshot.sh drop <vm> <label>";    drop    "$2" "$3" ;;
  *) die "usage: snapshot.sh {save|restore|list|drop} <vm> [label]" ;;
esac
