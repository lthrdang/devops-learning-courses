#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# lab-up.sh - post-launch helpers used by the Makefile.
#
#   lab-up.sh post  <vm>...    wait for cloud-init, print a readiness summary
#   lab-up.sh hosts <vm>...    write /etc/hosts entries so VMs can use names
#   lab-up.sh ssh   <vm>...    install your SSH key + write ~/.ssh/config on host
#
# Read this script. By week 3 you will be writing scripts exactly like it, and
# every construct used here is taught in that week.
# ---------------------------------------------------------------------------
set -euo pipefail

# Colours only when stdout is a terminal - a script that emits escape codes into
# a log file is a script that makes incidents harder to read.
if [[ -t 1 ]]; then
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; RST=$'\e[0m'
else
  RED=''; GRN=''; YEL=''; RST=''
fi

log()  { printf '%s[lab]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[lab]%s %s\n' "$YEL" "$RST" "$*" >&2; }
die()  { printf '%s[lab]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

vm_ip() {
  # multipass list --format csv columns: Name,State,IPv4,Image
  # An instance can report several addresses; take the first.
  multipass list --format csv \
    | awk -F, -v n="$1" 'NR>1 && $1==n {split($3,a," "); print a[1]; exit}'
}

cmd_post() {
  local vm
  for vm in "$@"; do
    log "waiting for cloud-init on ${vm} ..."
    # --wait blocks until provisioning finishes; without it, the next command
    # may run before packages are installed. This is THE most common cause of
    # "it works when I run it by hand but not from a script".
    if ! multipass exec "$vm" -- cloud-init status --wait >/dev/null 2>&1; then
      warn "cloud-init did not finish cleanly on ${vm}"
      warn "investigate: multipass exec ${vm} -- sudo tail -50 /var/log/cloud-init-output.log"
    fi
    multipass exec "$vm" -- test -f /opt/lab/.provisioned \
      || warn "${vm}: provisioning marker missing - the VM is usable but not fully set up"
  done

  echo
  printf '%-10s %-10s %-16s %s\n' NAME STATE IPv4 NOTE
  for vm in "$@"; do
    local state ip
    state=$(multipass list --format csv | awk -F, -v n="$vm" 'NR>1 && $1==n {print $2}')
    ip=$(vm_ip "$vm")
    printf '%-10s %-10s %-16s %s\n' "$vm" "${state:-?}" "${ip:-none}" "multipass shell ${vm}"
  done
  echo
}

cmd_hosts() {
  # Give every VM a stable name for its peers. Multipass IPs change across
  # restarts, so re-run this after `multipass start`. Week 4 makes you do it
  # by hand once before letting you use this script.
  local names=("$@") vm peer ip block=""
  for peer in "${names[@]}"; do
    ip=$(vm_ip "$peer")
    [[ -n "$ip" ]] || die "no IP for ${peer}; is it running?"
    block+="${ip} ${peer}"$'\n'
  done

  for vm in "${names[@]}"; do
    log "writing peer entries into ${vm}:/etc/hosts"
    # Delete any previous block, then append a fresh one. Idempotency matters:
    # a provisioning script you cannot run twice is a provisioning script you
    # cannot trust.
    multipass exec "$vm" -- sudo sed -i '/# >>> lab peers/,/# <<< lab peers/d' /etc/hosts
    printf '# >>> lab peers\n%s# <<< lab peers\n' "$block" \
      | multipass exec "$vm" -- sudo tee -a /etc/hosts >/dev/null
  done
  log "done - each VM can now reach the others by name, e.g. ping -c1 ${names[0]}"
}

cmd_ssh() {
  # Real SSH access from the host, rather than `multipass shell`.
  local key="${HOME}/.ssh/id_ed25519" vm ip
  if [[ ! -f "${key}.pub" ]]; then
    log "generating an SSH keypair at ${key}"
    ssh-keygen -t ed25519 -N '' -C "lab@$(hostname)" -f "$key"
  fi

  for vm in "$@"; do
    ip=$(vm_ip "$vm") || true
    [[ -n "$ip" ]] || die "no IP for ${vm}"
    log "installing public key on ${vm}"
    multipass exec "$vm" -- bash -c \
      'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys' \
      < "${key}.pub"

    # Refresh this host's ~/.ssh/config entry
    local cfg="${HOME}/.ssh/config"
    touch "$cfg"; chmod 600 "$cfg"
    if grep -q "^Host ${vm}\$" "$cfg" 2>/dev/null; then
      warn "an entry for '${vm}' already exists in ${cfg}; update HostName to ${ip} yourself"
    else
      {
        echo ""
        echo "Host ${vm}"
        echo "    HostName ${ip}"
        echo "    User ubuntu"
        echo "    IdentityFile ${key}"
        echo "    StrictHostKeyChecking accept-new"
      } >> "$cfg"
      log "added '${vm}' to ${cfg} - try:  ssh ${vm}"
    fi
  done
}

need multipass
case "${1:-}" in
  post)  shift; [[ $# -gt 0 ]] || die "usage: lab-up.sh post <vm>..." ; cmd_post  "$@" ;;
  hosts) shift; [[ $# -gt 1 ]] || die "usage: lab-up.sh hosts <vm> <vm>...";  cmd_hosts "$@" ;;
  ssh)   shift; [[ $# -gt 0 ]] || die "usage: lab-up.sh ssh <vm>..."  ; cmd_ssh   "$@" ;;
  *) die "usage: lab-up.sh {post|hosts|ssh} <vm>..." ;;
esac
