#!/usr/bin/env bash
# aide-acknowledge.sh — accept current filesystem state as the new AIDE baseline.
#
# Why this exists
#   AIDE (Advanced Intrusion Detection Environment, applied by the
#   `aide` role in the automation repo) reports every change against a
#   stored database at each scheduled check. After a sanctioned change
#   (package upgrade, config push, planned deploy), the next AIDE report
#   will keep flagging those same files until the baseline is refreshed.
#   This script:
#     1. shows the current diff (`aide --check`),
#     2. requires an explicit operator confirmation,
#     3. runs `aide --update` to write aide.db.new,
#     4. atomically replaces aide.db with aide.db.new.
#   A timestamped backup of the previous database is kept next to the
#   live one for rollback.
#
# Requirements
#   - aide (Debian/Ubuntu: apt-get install -y aide aide-common)
#   - Must run as root.
#
# Environment variables
#   AIDE_CONF    Path to aide.conf       (default /etc/aide/aide.conf).
#   AIDE_DB      Path to aide.db         (default /var/lib/aide/aide.db).
#   AIDE_DB_NEW  Path to aide.db.new     (default /var/lib/aide/aide.db.new).
#   FORCE        If 1, skip the interactive confirmation prompt.
#   DRY_RUN      If 1, run aide --check but skip the update step.
#
# Exit codes
#   0  success; baseline updated (or DRY_RUN completed)
#   1  runtime error (aide failed, missing files, permission error, …)
#   2  invalid argument

set -euo pipefail

log() { printf '[aide-ack] %s\n' "$*"; }
warn() { printf '[aide-ack] WARN: %s\n' "$*" >&2; }
err() { printf '[aide-ack] ERR: %s\n' "$*" >&2; }

usage() {
  cat << 'EOF'
Usage: [FORCE=1] [DRY_RUN=1] [AIDE_CONF=...] [AIDE_DB=...] aide-acknowledge.sh

Accept current filesystem state as the new AIDE baseline after a
sanctioned change. Shows the current diff, requires confirmation,
updates the database, and atomically replaces aide.db.

Environment variables:
  AIDE_CONF    Path to aide.conf (default /etc/aide/aide.conf).
  AIDE_DB      Path to aide.db   (default /var/lib/aide/aide.db).
  AIDE_DB_NEW  Path to aide.db.new (default /var/lib/aide/aide.db.new).
  FORCE        If 1, skip interactive confirmation.
  DRY_RUN      If 1, run aide --check but skip the update.

The previous database is backed up next to the live database with a
timestamped suffix (.bak.YYYY-mm-ddTHH:MM:SSZ) before being replaced.
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

confirm() {
  local prompt="$1"
  local ans
  printf '%s [y/N]: ' "${prompt}" >&2
  if ! read -r ans < /dev/tty; then
    err "no controlling tty; set FORCE=1 to skip the prompt"
    exit 1
  fi
  case "${ans}" in
    y | Y | yes | YES) return 0 ;;
    *) return 1 ;;
  esac
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

  require_cmd aide

  local aide_conf="${AIDE_CONF:-/etc/aide/aide.conf}"
  local aide_db="${AIDE_DB:-/var/lib/aide/aide.db}"
  local aide_db_new="${AIDE_DB_NEW:-/var/lib/aide/aide.db.new}"

  if [[ ! -f "${aide_conf}" ]]; then
    err "aide.conf not found: ${aide_conf}"
    exit 1
  fi
  if [[ ! -f "${aide_db}" ]]; then
    err "aide.db not found: ${aide_db} (has aide --init ever run?)"
    exit 1
  fi

  log "config : ${aide_conf}"
  log "db     : ${aide_db}"
  log "db.new : ${aide_db_new}"

  log ""
  log "--- aide --check (current diff) ---"
  # `aide --check` exits non-zero whenever it finds differences; that is
  # expected and informational here, not a failure of this script.
  set +e
  aide --config "${aide_conf}" --check
  local check_rc=$?
  set -e
  log "aide --check returned ${check_rc}"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "DRY_RUN: skipping --update and database replacement"
    exit 0
  fi

  if [[ "${FORCE:-0}" != "1" ]]; then
    if ! confirm "Accept the diff above as the new AIDE baseline?"; then
      log "aborted by operator"
      exit 0
    fi
  fi

  log ""
  log "--- aide --update ---"
  if ! aide --config "${aide_conf}" --update; then
    err "aide --update failed"
    exit 1
  fi
  if [[ ! -f "${aide_db_new}" ]]; then
    err "expected new database not produced: ${aide_db_new}"
    exit 1
  fi

  local ts backup
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  backup="${aide_db}.bak.${ts}"
  log "backing up: ${aide_db} -> ${backup}"
  cp -p -- "${aide_db}" "${backup}"

  log "promoting: ${aide_db_new} -> ${aide_db}"
  # mv on the same filesystem is atomic; aide writes db.new beside db
  # by default, so this is safe.
  mv -f -- "${aide_db_new}" "${aide_db}"

  log "done. new baseline: ${aide_db} ($(stat -c '%y' "${aide_db}"))"
  log "previous baseline kept at: ${backup}"
}

main "$@"
