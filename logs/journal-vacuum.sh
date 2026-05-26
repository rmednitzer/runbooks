#!/usr/bin/env bash
# journal-vacuum.sh — vacuum systemd journal to free disk space.
#
# Why this exists
#   When /var/log/journal grows large enough to threaten /var, the
#   operator needs to vacuum the journal without restarting services.
#   journalctl supports vacuuming by age (--vacuum-time) or size
#   (--vacuum-size); this script wraps both with a safe default
#   (KEEP_DAYS=7), shows before/after disk usage, and supports DRY_RUN.
#   For the longer-term fix — tune SystemMaxUse / MaxRetentionSec — see
#   the `common` role in the automation repo; this script is the
#   immediate-relief lever.
#
# Requirements
#   - journalctl (systemd >= 218)
#   - Must run as root (journalctl --vacuum-* requires write access to
#     /var/log/journal).
#
# Environment variables
#   KEEP_DAYS   Retain journal entries newer than N days (default 7).
#   KEEP_SIZE   Vacuum to a target on-disk size (e.g. 500M, 2G); when
#               set, overrides KEEP_DAYS.
#   DRY_RUN     If 1, print the planned action without executing it.
#
# Exit codes
#   0  success
#   1  runtime error (journalctl failed, missing dep, …)
#   2  invalid argument

set -euo pipefail

log() { printf '[journal-vacuum] %s\n' "$*"; }
warn() { printf '[journal-vacuum] WARN: %s\n' "$*" >&2; }
err() { printf '[journal-vacuum] ERR: %s\n' "$*" >&2; }

usage() {
  cat << 'EOF'
Usage: [KEEP_DAYS=7] [KEEP_SIZE=500M] [DRY_RUN=1] journal-vacuum.sh

Vacuum the systemd journal to free disk space.

Environment variables:
  KEEP_DAYS   Retain entries newer than N days (default 7).
  KEEP_SIZE   Vacuum to a target on-disk size (e.g. 500M, 2G).
              When set, overrides KEEP_DAYS.
  DRY_RUN     If 1, print planned action without executing.

Examples:
  ./journal-vacuum.sh                     # keep last 7 days
  KEEP_DAYS=2 ./journal-vacuum.sh         # keep last 2 days
  KEEP_SIZE=500M ./journal-vacuum.sh      # cap journal at 500 MiB
  DRY_RUN=1 KEEP_DAYS=3 ./journal-vacuum.sh
EOF
}

run() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "DRY_RUN: $*"
  else
    log "+ $*"
    "$@"
  fi
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" > /dev/null 2>&1; then
      err "required command not found: ${cmd}"
      exit 1
    fi
  done
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
  esac

  if [[ "${EUID}" -ne 0 ]]; then
    err "must run as root"
    exit 1
  fi

  require_cmd journalctl

  local keep_days="${KEEP_DAYS:-7}"
  local keep_size="${KEEP_SIZE:-}"

  if [[ -z "${keep_size}" ]]; then
    if ! [[ "${keep_days}" =~ ^[0-9]+$ ]]; then
      err "KEEP_DAYS must be a non-negative integer (got: ${keep_days})"
      exit 2
    fi
  else
    # systemd accepts K, M, G, T suffixes (binary multipliers). Validate
    # the shape; reject anything weirder so we don't pass garbage along.
    if ! [[ "${keep_size}" =~ ^[0-9]+[KMGT]?$ ]]; then
      err "KEEP_SIZE must match ^[0-9]+[KMGT]?\$ (got: ${keep_size})"
      exit 2
    fi
  fi

  log "--- before ---"
  journalctl --disk-usage || true
  df -h /var/log 2> /dev/null || df -h /var || true

  if [[ -n "${keep_size}" ]]; then
    log "strategy: vacuum to <= ${keep_size}"
    run journalctl --vacuum-size="${keep_size}"
  else
    log "strategy: vacuum entries older than ${keep_days} days"
    run journalctl --vacuum-time="${keep_days}d"
  fi

  log "--- after ---"
  journalctl --disk-usage || true
  df -h /var/log 2> /dev/null || df -h /var || true

  log ""
  log "for permanent retention tuning, set SystemMaxUse= /"
  log "MaxRetentionSec= in /etc/systemd/journald.conf.d/ (handled by the"
  log "automation/roles/common Ansible role)."
}

main "$@"
