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
# The active-file trap (M3)
#   --vacuum-size / --vacuum-time only delete ARCHIVED journal files;
#   they never touch the ACTIVE journal. If most of the space is in the
#   active file (a single service spewing logs right now — the usual page
#   trigger), a vacuum reports success while freeing almost nothing. This
#   script measures the before/after delta and WARNS when the reclaim is
#   negligible, pointing at `journalctl --rotate`. Set ROTATE=1 to rotate
#   first: rotation seals the active file into an archive so the vacuum
#   can then reclaim it. Tradeoff: rotation forces a brand-new active
#   file (a tiny, momentary bookkeeping cost), so it is opt-in.
#
# Requirements (bash >= 4; see CLAUDE.md)
#   - journalctl (systemd >= 218)
#   - GNU coreutils (numfmt for byte parsing; falls back gracefully)
#   - Must run as root (journalctl --vacuum-* requires write access to
#     /var/log/journal).
#
# Environment variables
#   KEEP_DAYS   Retain journal entries newer than N days (default 7).
#   KEEP_SIZE   Vacuum to a target on-disk size (e.g. 500M, 2G); when
#               set, overrides KEEP_DAYS.
#   ROTATE      If 1, run `journalctl --rotate` BEFORE vacuuming so the
#               active file can be reclaimed (forces a new active file).
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

# Uniform failure reporting. No temp files to clean up here.
trap 'err "failed at line ${LINENO}"; exit 1' ERR

usage() {
  cat << 'EOF'
Usage: [KEEP_DAYS=7] [KEEP_SIZE=500M] [ROTATE=1] [DRY_RUN=1] journal-vacuum.sh

Vacuum the systemd journal to free disk space.

Environment variables:
  KEEP_DAYS   Retain entries newer than N days (default 7).
  KEEP_SIZE   Vacuum to a target on-disk size (e.g. 500M, 2G).
              When set, overrides KEEP_DAYS.
  ROTATE      If 1, run `journalctl --rotate` before vacuuming so the
              ACTIVE journal file can be reclaimed too (forces a new
              active file). Without it, vacuuming only frees ARCHIVED
              files and may reclaim almost nothing.
  DRY_RUN     If 1, print planned action without executing.

Examples:
  ./journal-vacuum.sh                     # keep last 7 days
  KEEP_DAYS=2 ./journal-vacuum.sh         # keep last 2 days
  KEEP_SIZE=500M ./journal-vacuum.sh      # cap journal at 500 MiB
  ROTATE=1 KEEP_SIZE=500M ./journal-vacuum.sh   # also reclaim active file
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

# Echo the journal's on-disk size in BYTES, parsed from
#   "Archived and active journals take up 1.2G in the file system."
# Returns empty (and 0 success) if it cannot parse — callers treat an
# empty value as "unknown" and skip the delta check rather than failing.
journal_bytes() {
  local usage size
  usage="$(journalctl --disk-usage 2> /dev/null || true)"
  # Grab the number+unit token (e.g. 1.2G, 512.0M, 900K, 42B).
  if [[ "${usage}" =~ ([0-9]+(\.[0-9]+)?[KMGTPE]?B?)[[:space:]]+in[[:space:]]+the ]]; then
    size="${BASH_REMATCH[1]}"
    # numfmt understands IEC suffixes; strip a trailing literal "B" since
    # journalctl writes e.g. "1.2G" (no B) but also a bare "B" for bytes.
    size="${size%B}"
    if command -v numfmt > /dev/null 2>&1; then
      numfmt --from=iec "${size}" 2> /dev/null || true
    fi
  fi
  return 0
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
    *) ;;
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

  local before_bytes
  before_bytes="$(journal_bytes)"

  # ROTATE seals the active file into an archive so the subsequent vacuum
  # can reclaim it too (M3). Without this, --vacuum-* only touches
  # already-archived files.
  if [[ "${ROTATE:-0}" == "1" ]]; then
    log "strategy: rotate first (seals the active file so it can be reclaimed)"
    run journalctl --rotate
  fi

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

  # M3: compare before/after and warn if the vacuum reclaimed almost
  # nothing — the classic case where the space is in the ACTIVE file that
  # a vacuum cannot touch. Skipped under DRY_RUN (nothing changed) and
  # when sizes could not be parsed.
  if [[ "${DRY_RUN:-0}" != "1" && -n "${before_bytes}" ]]; then
    local after_bytes freed
    after_bytes="$(journal_bytes)"
    if [[ -n "${after_bytes}" ]]; then
      freed=$((before_bytes - after_bytes))
      ((freed < 0)) && freed=0
      log "reclaimed  : ${freed} bytes (before=${before_bytes} after=${after_bytes})"
      # "Negligible" threshold: < 1 MiB freed while > 64 MiB remains.
      if ((freed < 1048576 && after_bytes > 67108864)); then
        warn "vacuum freed almost nothing (${freed} bytes) but ${after_bytes} bytes remain."
        warn "the space is likely in the ACTIVE journal file, which --vacuum-* cannot delete."
        if [[ "${ROTATE:-0}" != "1" ]]; then
          warn "re-run with ROTATE=1 to seal+reclaim the active file:"
          warn "  ROTATE=1 ${KEEP_SIZE:+KEEP_SIZE=${KEEP_SIZE} }journal-vacuum.sh"
        else
          warn "even after --rotate little was freed; investigate a live log spammer"
          warn "(journalctl -n200 -p warning) or check SystemMaxUse= sizing."
        fi
      fi
    fi
  fi

  log ""
  log "for permanent retention tuning, set SystemMaxUse= /"
  log "MaxRetentionSec= in /etc/systemd/journald.conf.d/ (handled by the"
  log "automation/roles/common Ansible role)."
}

# Only execute when run directly; sourcing (e.g. from bats) must not run main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
