#!/usr/bin/env bash
# disk-usage-triage.sh — find what is filling up a disk.
#
# Why this exists
#   Disk-full alerts are the most common 03:00 page. Before deciding to
#   extend an LV (storage/extend-lvm.sh), vacuum logs (logs/journal-
#   vacuum.sh), or hunt down a runaway process, the operator needs to
#   know what is consuming the space. This script prints a one-page
#   triage for every filesystem above THRESHOLD: top directories, large
#   files, journal usage, and — critically — open deleted files held by
#   running processes, which du alone will miss.
#
# Requirements
#   - df, du, find (coreutils + findutils)
#   - lsof (optional; deleted-file scan skipped with a warning if absent)
#   - journalctl (optional; journal report skipped if absent)
#
# Environment variables
#   THRESHOLD     Mount usage % to trigger the deep scan (default 80).
#   TOP_N         Number of largest entries to report (default 10).
#   MIN_FILE_MIB  Minimum size for the large-files scan, MiB (default 100).
#   MOUNT         Restrict scan to one mountpoint; otherwise every local
#                 filesystem above THRESHOLD is scanned.
#
# Exit codes
#   0  success
#   1  runtime error
#   2  invalid argument

set -euo pipefail

log() { printf '[disk-triage] %s\n' "$*"; }
warn() { printf '[disk-triage] WARN: %s\n' "$*" >&2; }
err() { printf '[disk-triage] ERR: %s\n' "$*" >&2; }

usage() {
  cat << 'EOF'
Usage: [THRESHOLD=80] [TOP_N=10] [MIN_FILE_MIB=100] [MOUNT=/var] disk-usage-triage.sh

Identify what is filling up a disk: largest directories, largest files,
journal size, and deleted-but-open files held by running processes.

Environment variables:
  THRESHOLD     Mount usage % to trigger the deep scan (default 80).
  TOP_N         Number of largest entries to report (default 10).
  MIN_FILE_MIB  Minimum size for the large-files scan, MiB (default 100).
  MOUNT         Restrict scan to one mountpoint (default: all local FS).

Read-only — does not modify anything on disk.
EOF
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

is_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

scan_mount() {
  local mp="$1"
  local top_n="$2"
  local min_mib="$3"

  log ""
  log "================================================================"
  log "Mountpoint: ${mp}"
  log "================================================================"
  df -h -- "${mp}" || true

  log ""
  log "--- top ${top_n} directories under ${mp} (du, one-filesystem) ---"
  du -x -h --max-depth=3 -- "${mp}" 2> /dev/null |
    sort -h |
    tail -n "${top_n}" || true

  log ""
  log "--- files >= ${min_mib} MiB under ${mp} (one-filesystem) ---"
  find "${mp}" -xdev -type f -size +"${min_mib}"M -printf '%s\t%p\n' 2> /dev/null |
    sort -nr |
    head -n "${top_n}" |
    awk '{ printf "%10.1f MiB\t%s\n", $1 / 1024 / 1024, $2 }' || true
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
  esac

  local threshold="${THRESHOLD:-80}"
  local top_n="${TOP_N:-10}"
  local min_mib="${MIN_FILE_MIB:-100}"

  if ! is_int "${threshold}" || ! is_int "${top_n}" || ! is_int "${min_mib}"; then
    err "THRESHOLD, TOP_N, MIN_FILE_MIB must be non-negative integers"
    exit 2
  fi
  if ((threshold > 100)); then
    err "THRESHOLD must be 0..100 (got ${threshold})"
    exit 2
  fi

  require_cmd df du find awk sort head tail

  log "thresholds: usage >= ${threshold}%  top_n=${top_n}  min_file=${min_mib} MiB"

  local mounts=()
  if [[ -n "${MOUNT:-}" ]]; then
    if ! findmnt -no TARGET --target "${MOUNT}" > /dev/null 2>&1; then
      err "MOUNT is not a mountpoint: ${MOUNT}"
      exit 2
    fi
    mounts=("${MOUNT}")
  else
    local line pct mp
    while IFS= read -r line; do
      pct="$(awk '{print $5}' <<< "${line}" | tr -d '%')"
      mp="$(awk '{print $6}' <<< "${line}")"
      if is_int "${pct}" && ((pct >= threshold)); then
        mounts+=("${mp}")
      fi
    done < <(df -P --local --type=ext4 --type=ext3 --type=ext2 --type=xfs --type=btrfs 2> /dev/null | tail -n +2)
  fi

  if ((${#mounts[@]} == 0)); then
    log "no local filesystems at or above ${threshold}% usage"
    log "current state:"
    df -h --local || true
    exit 0
  fi

  log "filesystems to scan: ${mounts[*]}"

  local mp
  for mp in "${mounts[@]}"; do
    scan_mount "${mp}" "${top_n}" "${min_mib}"
  done

  log ""
  log "--- systemd journal disk usage ---"
  if command -v journalctl > /dev/null 2>&1; then
    journalctl --disk-usage 2> /dev/null || warn "journalctl --disk-usage failed"
  else
    warn "journalctl not present — skipping journal usage check"
  fi

  log ""
  log "--- deleted files still held open (run as root for full coverage) ---"
  if command -v lsof > /dev/null 2>&1; then
    # Format: COMMAND PID USER FD TYPE DEVICE SIZE NODE NAME
    # Report only regular files (REG) that are deleted, top by SIZE.
    lsof -nP +L1 2> /dev/null |
      awk 'NR == 1 || ($5 == "REG" && $0 ~ /\(deleted\)$/)' |
      head -n "$((top_n + 1))" || true
  else
    warn "lsof not present — skipping deleted-files scan"
    warn "(install: apt-get install -y lsof)"
  fi

  log ""
  log "next steps:"
  log "  - large dirs?  rotate, archive, or move to a separate volume"
  log "  - large files? truncate or delete (beware: deleting a file held"
  log "                 open does not free space; restart the holder)"
  log "  - journal big? logs/journal-vacuum.sh"
  log "  - LV full?     storage/extend-lvm.sh"
}

main "$@"
