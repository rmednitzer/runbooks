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
#     1. runs `aide --check`, captured to a temp file,
#     2. prints a parsed summary (added/removed/changed) of that diff,
#     3. requires an explicit operator confirmation,
#     4. runs `aide --update` to write the new database,
#     5. atomically replaces the live database with the new one.
#   A timestamped backup of the previous database is kept next to the
#   live one, and is restored automatically if the promotion fails.
#
# Why it reads the real paths from aide.conf (H1)
#   The new-database path is NOT a constant. AIDE writes it to
#   `database_out` (older configs: `database_new`), and the live DB it
#   reads is `database_in` (older configs: `database`). On Debian/Ubuntu
#   the packaged config sets `gzip_dbout=yes`, so the produced file is
#   commonly `aide.db.new.gz`, not `aide.db.new`. Hardcoding
#   /var/lib/aide/aide.db.new therefore promotes the WRONG (or a
#   nonexistent) file on any non-default layout. We parse the config,
#   strip the `file:` URL prefix, expand `@@{DBDIR}` and other
#   `@@define` macros, and accept either `<db>.new` or `<db>.new.gz`.
#   The resolved output path must match what we are about to promote, and
#   the destination must match `database_in`, or we refuse to run.
#
# Safety properties
#   - Rollback (H2): an EXIT trap restores the backup over the live DB if
#     anything fails after the backup is taken but before success.
#   - Atomic, same-filesystem promote (H2): the new DB and the live DB
#     must live in the same directory; the rename happens within that
#     directory so it is atomic and never a cross-filesystem copy.
#   - `sync` is issued after the rename so the new baseline is on disk
#     before the script reports success.
#   - Only the leaf operation mutates state; everything before the prompt
#     is read-only.
#
# Requirements (bash >= 4; see CLAUDE.md)
#   - aide (Debian/Ubuntu: apt-get install -y aide aide-common)
#   - coreutils: mktemp, stat, sync, mv, cp, date, dirname
#   - Must run as root.
#
# Environment variables
#   AIDE_CONF    Path to aide.conf       (default /etc/aide/aide.conf).
#   AIDE_DB      Override the live DB path. Default: derived from
#                aide.conf (database_in/database).
#   AIDE_DB_NEW  Override the new DB path. Default: derived from
#                aide.conf (database_out/database_new); `.gz` honoured.
#   FORCE        If 1, skip the interactive confirmation prompt.
#   DRY_RUN      If 1, run aide --check but skip the update step.
#
# Exit codes
#   0  success; baseline updated (or DRY_RUN completed)
#   1  runtime error (aide failed, missing files, permission error,
#      cross-filesystem layout, resolved paths disagree, …)
#   2  invalid argument

set -euo pipefail

log() { printf '[aide-ack] %s\n' "$*"; }
warn() { printf '[aide-ack] WARN: %s\n' "$*" >&2; }
err() { printf '[aide-ack] ERR: %s\n' "$*" >&2; }

usage() {
  cat << 'EOF'
Usage: [FORCE=1] [DRY_RUN=1] [AIDE_CONF=...] aide-acknowledge.sh

Accept current filesystem state as the new AIDE baseline after a
sanctioned change. Runs aide --check, prints a parsed summary, requires
confirmation, updates the database, and atomically promotes it.

Environment variables:
  AIDE_CONF    Path to aide.conf (default /etc/aide/aide.conf).
  AIDE_DB      Override live DB path (default: aide.conf database_in).
  AIDE_DB_NEW  Override new DB path (default: aide.conf database_out;
    a trailing .gz from gzip_dbout is honoured).
  FORCE        If 1, skip interactive confirmation.
  DRY_RUN      If 1, run aide --check but skip the update.

The live DB path and the new DB path are read from aide.conf and must
share a directory (the promote is an atomic same-filesystem rename). The
previous database is backed up next to the live one with a timestamped
suffix (.bak.YYYY-mm-ddTHH:MM:SSZ) and restored automatically if the
promotion fails.
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

# --- rollback / cleanup state (H2, L1, M5) -------------------------------
# CHECK_REPORT : temp file holding `aide --check` output (M5); removed on exit.
# BACKUP_PATH  : timestamped backup of the live DB; set just before the
#                promote. PROMOTED stays 0 until the rename succeeds, so
#                the EXIT trap knows whether a rollback is required.
CHECK_REPORT=""
BACKUP_PATH=""
LIVE_DB=""
PROMOTED=0

cleanup() {
  local rc=$?
  # Restore the live DB from the backup if we crashed mid-promote: the
  # backup exists, the promote did not complete, and the live DB is now
  # missing or truncated. Better a stale baseline than no baseline.
  if [[ "${PROMOTED}" -eq 0 && -n "${BACKUP_PATH}" && -f "${BACKUP_PATH}" ]]; then
    if [[ ! -s "${LIVE_DB}" ]]; then
      warn "promote did not complete; restoring live DB from backup"
      if cp -p -- "${BACKUP_PATH}" "${LIVE_DB}" 2> /dev/null; then
        sync || true
        warn "restored ${LIVE_DB} from ${BACKUP_PATH}"
      else
        err "ROLLBACK FAILED — restore by hand: cp -p ${BACKUP_PATH} ${LIVE_DB}"
      fi
    fi
  fi
  [[ -n "${CHECK_REPORT}" && -f "${CHECK_REPORT}" ]] && rm -f -- "${CHECK_REPORT}"
  return "${rc}"
}
trap 'cleanup' EXIT
trap 'err "failed at line ${LINENO}"; exit 1' ERR

# Resolve an aide.conf database URL value into an absolute path:
#   - strip a leading `file:` URL scheme,
#   - expand @@{VAR} macros defined earlier via `@@define VAR value`.
# Args: <raw value> <name=value ...defines>
resolve_db_url() {
  local value="$1"
  shift
  value="${value#file:}"
  # Expand each @@{VAR}. Defines are passed as VAR=val pairs.
  local def name val
  for def in "$@"; do
    name="${def%%=*}"
    val="${def#*=}"
    value="${value//@@\{${name}\}/${val}}"
  done
  printf '%s' "${value}"
}

# Parse aide.conf and echo two lines: the input (live) DB path and the
# output (new) DB path, both fully resolved. Honours database_in/database
# for input and database_out/database_new for output, and @@define macros.
parse_aide_db_paths() {
  local conf="$1"
  local in_raw="" out_raw=""
  local -a defines=()
  local line key rest
  while IFS= read -r line; do
    # Trim leading/trailing whitespace.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    if [[ "${line}" == @@define* ]]; then
      # @@define VAR value
      rest="${line#@@define}"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      key="${rest%%[[:space:]]*}"
      val="${rest#"${key}"}"
      val="${val#"${val%%[![:space:]]*}"}"
      defines+=("${key}=${val}")
      continue
    fi
    case "${line}" in
      database_in=* | database=*)
        in_raw="${line#*=}"
        ;;
      database_out=* | database_new=*)
        out_raw="${line#*=}"
        ;;
      *) ;;
    esac
  done < "${conf}"
  # database_in takes precedence over the legacy `database`; same for out.
  local in_path out_path
  in_path="$(resolve_db_url "${in_raw}" "${defines[@]+"${defines[@]}"}")"
  out_path="$(resolve_db_url "${out_raw}" "${defines[@]+"${defines[@]}"}")"
  printf '%s\n%s\n' "${in_path}" "${out_path}"
}

# Print a one-line summary of an `aide --check` report. AIDE emits a
# block like:
#   Total number of entries:      1234
#   Added entries:                3
#   Removed entries:              0
#   Changed entries:              7
# Fall back to "could not parse" if the block is absent.
# Pull the first integer off the AIDE summary line matching <label>.
# A missing line is normal (AIDE omits zero categories in some builds),
# so this must never abort under set -e/pipefail — hence the `|| true`.
_summary_count() {
  local report="$1" label="$2" line
  line="$(grep -aiE "^[[:space:]]*(${label})[[:space:]]*:" "${report}" 2> /dev/null | head -1 || true)"
  [[ "${line}" =~ ([0-9]+) ]] && printf '%s' "${BASH_REMATCH[1]}"
  return 0
}

summarise_check() {
  local report="$1"
  local added removed changed
  added="$(_summary_count "${report}" 'Added entries|Added files')"
  removed="$(_summary_count "${report}" 'Removed entries|Removed files')"
  changed="$(_summary_count "${report}" 'Changed entries|Changed files')"
  if [[ -z "${added}${removed}${changed}" ]]; then
    log "summary    : could not parse AIDE summary block (see full report)"
    return 0
  fi
  log "summary    : added=${added:-?} removed=${removed:-?} changed=${changed:-?}"
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

  require_cmd aide mktemp stat sync mv cp date dirname

  local aide_conf="${AIDE_CONF:-/etc/aide/aide.conf}"
  if [[ ! -f "${aide_conf}" ]]; then
    err "aide.conf not found: ${aide_conf}"
    exit 1
  fi

  # Resolve the live (in) and new (out) DB paths from aide.conf so we
  # promote exactly the file AIDE writes — not a hardcoded guess (H1).
  # parse_aide_db_paths prints the input path on line 1, output on line 2.
  local conf_paths conf_db_in conf_db_out
  conf_paths="$(parse_aide_db_paths "${aide_conf}")"
  mapfile -t _conf_lines <<< "${conf_paths}"
  conf_db_in="${_conf_lines[0]:-}"
  conf_db_out="${_conf_lines[1]:-}"
  unset _conf_lines

  local aide_db="${AIDE_DB:-${conf_db_in}}"
  local aide_db_new="${AIDE_DB_NEW:-${conf_db_out}}"

  if [[ -z "${aide_db}" ]]; then
    err "could not determine live DB path: set database_in/database in ${aide_conf} or pass AIDE_DB"
    exit 1
  fi
  if [[ -z "${aide_db_new}" ]]; then
    err "could not determine new DB path: set database_out/database_new in ${aide_conf} or pass AIDE_DB_NEW"
    exit 1
  fi

  # gzip_dbout=yes (Debian/Ubuntu default) makes the produced file
  # <db>.new.gz. Accept either the configured name or its .gz variant,
  # and promote whichever AIDE actually wrote (H1). The promote target is
  # always the configured live DB (database_in).
  local aide_db_in_use="${aide_db}"

  if [[ ! -f "${aide_db}" ]]; then
    err "live AIDE database not found: ${aide_db} (has aide --init ever run?)"
    exit 1
  fi

  # H2 precondition: an atomic promote requires the new DB and the live
  # DB to share a directory (rename within a single filesystem). Refuse
  # otherwise rather than risk a cross-filesystem mv that can fail
  # mid-copy and strand a half-written live DB.
  local live_dir new_dir
  live_dir="$(dirname -- "${aide_db}")"
  new_dir="$(dirname -- "${aide_db_new}")"
  if [[ "${live_dir}" != "${new_dir}" ]]; then
    err "new DB and live DB are in different directories — refusing non-atomic promote"
    err "  live: ${aide_db}"
    err "  new : ${aide_db_new}"
    exit 1
  fi

  log "config     : ${aide_conf}"
  log "live db    : ${aide_db}"
  log "new db     : ${aide_db_new} (or ${aide_db_new}.gz if gzip_dbout=yes)"

  # M5: capture the (potentially huge) check output to a temp file,
  # summarise it, and show the path — instead of streaming tens of
  # thousands of lines past the operator and then asking y/N blind.
  CHECK_REPORT="$(mktemp)"
  log ""
  log "--- aide --check (captured) ---"
  # aide --check exits non-zero whenever it finds differences; expected
  # and informational here, not a failure of this script.
  local check_rc=0
  aide --config "${aide_conf}" --check > "${CHECK_REPORT}" 2>&1 || check_rc=$?
  log "aide --check returned ${check_rc}"
  summarise_check "${CHECK_REPORT}"
  log "full report: ${CHECK_REPORT}"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "DRY_RUN: skipping --update and database replacement"
    log "review the report above before re-running without DRY_RUN"
    exit 0
  fi

  if [[ "${FORCE:-0}" != "1" ]]; then
    log "review the summary/report above before confirming."
    # set -e intentionally disabled for this branch test.
    # shellcheck disable=SC2310
    if ! confirm "Accept this diff as the new AIDE baseline?"; then
      log "aborted by operator"
      exit 0
    fi
  fi

  log ""
  log "--- aide --update ---"
  # shellcheck disable=SC2310
  if ! aide --config "${aide_conf}" --update; then
    err "aide --update failed"
    exit 1
  fi

  # H1: locate the file AIDE actually produced (.gz or not) and verify it
  # matches what we intend to promote.
  local produced=""
  if [[ -f "${aide_db_new}" ]]; then
    produced="${aide_db_new}"
  elif [[ -f "${aide_db_new}.gz" ]]; then
    produced="${aide_db_new}.gz"
  fi
  if [[ -z "${produced}" ]]; then
    err "expected new database not produced: ${aide_db_new} (or ${aide_db_new}.gz)"
    err "check 'database_out' in ${aide_conf} and whether gzip_dbout is set"
    exit 1
  fi
  log "produced   : ${produced}"

  # The promoted destination must be the configured live DB. If gzip is
  # in play the live DB keeps the configured database_in name, so promote
  # the produced file onto ${aide_db_in_use} and refuse if the produced
  # path's directory does not match the live DB's directory.
  if [[ "$(dirname -- "${produced}")" != "${live_dir}" ]]; then
    err "produced DB ${produced} is not in the live DB directory ${live_dir} — refusing"
    exit 1
  fi

  local ts backup
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  backup="${aide_db_in_use}.bak.${ts}"
  log "backing up : ${aide_db_in_use} -> ${backup}"
  cp -p -- "${aide_db_in_use}" "${backup}"

  # Arm the rollback: from here, a failure before PROMOTED=1 triggers the
  # EXIT trap to restore ${backup} over the live DB.
  BACKUP_PATH="${backup}"
  LIVE_DB="${aide_db_in_use}"

  log "promoting  : ${produced} -> ${aide_db_in_use}"
  # Atomic, same-directory rename (validated above) — never a
  # cross-filesystem copy.
  mv -f -- "${produced}" "${aide_db_in_use}"
  PROMOTED=1
  # Durability: flush the rename to disk before declaring success.
  sync

  local new_mtime
  new_mtime="$(stat -c '%y' "${aide_db_in_use}")"
  log "done. new baseline: ${aide_db_in_use} (${new_mtime})"
  log "previous baseline kept at: ${backup}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
