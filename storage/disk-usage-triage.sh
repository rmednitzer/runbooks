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
# Requirements (bash >= 4; see CLAUDE.md)
#   - GNU coreutils df/du (uses `df --output`, `df -x`, `du --max-depth`)
#   - GNU findutils find (uses `-printf`, `-xdev`)
#   - awk, sort, head, tail
#   - findmnt (util-linux), used to validate MOUNT
#   - lsof (optional; deleted-file scan skipped with a warning if absent)
#   - journalctl (optional; journal report skipped if absent)
#   - ionice/nice (optional; if present, the du walk runs at idle I/O and
#     low CPU priority so triage does not pile onto a struggling box)
#   These GNU-specific flags mean this script targets GNU/Linux, not
#   BusyBox or BSD userland.
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

# Uniform failure reporting. This script is read-only and has no temp
# files, so there is nothing to clean up on exit.
trap 'err "failed at line ${LINENO}"; exit 1' ERR

# Prefix (as an array) that drops the du walk to idle I/O + low CPU
# priority when ionice/nice are available — important on a box that is
# already paging at 03:00. Empty when neither tool is present.
NICE_PREFIX=()
init_nice_prefix() {
  if command -v ionice > /dev/null 2>&1; then
    NICE_PREFIX+=(ionice -c3)
  fi
  if command -v nice > /dev/null 2>&1; then
    NICE_PREFIX+=(nice -n19)
  fi
}

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
  # The du walk is the heaviest part; run it at idle I/O + low CPU
  # priority (NICE_PREFIX) so it does not worsen the incident.
  "${NICE_PREFIX[@]}" du -x -h --max-depth=3 -- "${mp}" 2> /dev/null |
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
    *) ;;
  esac

  local threshold="${THRESHOLD:-80}"
  local top_n="${TOP_N:-10}"
  local min_mib="${MIN_FILE_MIB:-100}"

  # is_int is a pure predicate; set -e being disabled in this test is the
  # intended behaviour (we branch on it).
  # shellcheck disable=SC2310
  if ! is_int "${threshold}" || ! is_int "${top_n}" || ! is_int "${min_mib}"; then
    err "THRESHOLD, TOP_N, MIN_FILE_MIB must be non-negative integers"
    exit 2
  fi
  if ((threshold > 100)); then
    err "THRESHOLD must be 0..100 (got ${threshold})"
    exit 2
  fi

  require_cmd df du find awk sort head tail findmnt
  init_nice_prefix
  if ((${#NICE_PREFIX[@]} > 0)); then
    log "du walk niced via: ${NICE_PREFIX[*]}"
  fi

  log "thresholds: usage >= ${threshold}%  top_n=${top_n}  min_file=${min_mib} MiB"

  local mounts=()
  if [[ -n "${MOUNT:-}" ]]; then
    # set -e intentionally disabled for this branch test.
    # shellcheck disable=SC2310
    if ! findmnt -no TARGET --target "${MOUNT}" > /dev/null 2>&1; then
      err "MOUNT is not a mountpoint: ${MOUNT}"
      exit 2
    fi
    mounts=("${MOUNT}")
  else
    # M2: address columns by NAME (pcent,target) so spaces in a
    # mountpoint do not shift fields, and read `target` as the remainder
    # of the line. Drop the ext*/xfs/btrfs whitelist (which silently
    # skipped zfs/f2fs/bcachefs and produced false "nothing above
    # threshold") in favour of excluding known pseudo-filesystems.
    local line pct mp
    # df's exit status is intentionally not propagated (a missing FS just
    # yields no rows); tail strips the header line. is_int below is a pure
    # predicate, branched on deliberately.
    # shellcheck disable=SC2310,SC2312
    while IFS= read -r line; do
      # `df --output=pcent,target` right-justifies pcent, so the line can
      # have leading spaces — trim them first. pcent is then the first
      # token (e.g. "87%"); target is the remainder (may contain spaces).
      line="${line#"${line%%[![:space:]]*}"}"
      pct="${line%%[[:space:]]*}"
      pct="${pct%\%}"
      mp="${line#"${pct}%"}"
      mp="${mp#"${mp%%[![:space:]]*}"}"
      [[ -z "${mp}" || "${mp}" == "target" ]] && continue
      if is_int "${pct}" && ((pct >= threshold)); then
        mounts+=("${mp}")
      fi
    done < <(df -P --local --output=pcent,target \
      -x tmpfs -x devtmpfs -x overlay -x squashfs -x ramfs \
      -x proc -x sysfs -x cgroup -x cgroup2 -x devpts -x mqueue \
      -x efivarfs -x autofs -x debugfs -x tracefs -x fuse.portal \
      2> /dev/null | tail -n +2)
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

# Only execute when run directly; sourcing (e.g. from bats) must not run main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
