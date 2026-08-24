#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# lab-down.sh - stop or destroy lab instances.
#
#   lab-down.sh stop  [vm...]    stop (default: all)  - frees RAM, keeps state
#   lab-down.sh nuke  [vm...]    delete and purge     - irreversible
#
# Destroying the lab should feel cheap. If it does not, your environment is not
# reproducible, and reproducibility is the whole discipline.
# ---------------------------------------------------------------------------
set -euo pipefail

log() { printf '[down] %s\n' "$*"; }
die() { printf '[down] %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  stop)
    shift
    if [[ $# -eq 0 ]]; then multipass stop --all; else multipass stop "$@"; fi
    log 'stopped. They still appear in multipass list; start brings them back.'
    ;;
  nuke)
    shift
    printf '[down] This DELETES instances permanently. Ctrl-C within 5s to abort.\n'
    sleep 5
    if [[ $# -eq 0 ]]; then multipass delete --all --purge; else multipass delete --purge "$@"; fi
    multipass purge
    log "gone. Rebuild with: make wNN-up"
    ;;
  *) die "usage: lab-down.sh {stop|nuke} [vm...]" ;;
esac
