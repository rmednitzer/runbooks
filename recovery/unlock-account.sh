#!/usr/bin/env bash
# unlock-account.sh — clear fail2ban bans and pam_faillock lockouts.
#
# Why this exists
#   The fleet runs fail2ban (sshd jail plus the recidive jail for repeat
#   offenders) and pam_faillock (configured by the `users` role in the
#   automation repo). Either can lock out a legitimate user after a
#   typo, an IP flap, or a misfired playbook. This script clears either
#   or both, in a single invocation: unbans an IP from every jail it
#   appears in, and resets pam_faillock counters for a user. It refuses
#   to run if neither IP nor TARGET_USER is set, so it cannot silently
#   no-op during an incident.
#
# Requirements
#   - fail2ban-client (when IP is set)
#   - faillock from libpam-modules (when TARGET_USER is set)
#   - Must run as root.
#
# Environment variables
#   TARGET_USER  Local username to reset faillock counters for.
#                (Named TARGET_USER, not USER, because USER is already
#                set in every shell and would otherwise self-target.)
#   IP           IP address to unban from every fail2ban jail.
#   DRY_RUN      If 1, print actions without executing them.
#
# Exit codes
#   0  success
#   1  runtime error (fail2ban-client failure, missing dep, …)
#   2  invalid argument (neither TARGET_USER nor IP set, malformed IP, …)

set -euo pipefail

log() { printf '[unlock-account] %s\n' "$*"; }
warn() { printf '[unlock-account] WARN: %s\n' "$*" >&2; }
err() { printf '[unlock-account] ERR: %s\n' "$*" >&2; }

usage() {
  cat << 'EOF'
Usage: [TARGET_USER=<name>] [IP=<addr>] [DRY_RUN=1] unlock-account.sh

Clear fail2ban bans and pam_faillock lockouts. At least one of
TARGET_USER or IP must be set.

Environment variables:
  TARGET_USER  Local username to reset faillock counters for.
  IP           IP address to unban from every fail2ban jail.
  DRY_RUN      If 1, print actions without executing.

TARGET_USER is deliberately named to avoid colliding with the always-set
USER variable.

Examples:
  TARGET_USER=alice ./unlock-account.sh
  IP=192.0.2.10 ./unlock-account.sh
  TARGET_USER=alice IP=192.0.2.10 ./unlock-account.sh
  DRY_RUN=1 IP=2001:db8::1 ./unlock-account.sh
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

# Validate that a string looks like an IPv4 or IPv6 literal. Not a full
# RFC validator — guards against accidental hostnames or empty values
# being passed to fail2ban-client.
is_ip_literal() {
  local s="$1"
  if [[ "${s}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local oct
    for oct in ${s//./ }; do
      ((oct <= 255)) || return 1
    done
    return 0
  fi
  if [[ "${s}" == *:* && "${s}" =~ ^[0-9A-Fa-f:.]+$ ]]; then
    return 0
  fi
  return 1
}

unban_ip() {
  local ip="$1"
  require_cmd fail2ban-client

  local jails_csv
  if ! jails_csv="$(fail2ban-client status 2> /dev/null | sed -n 's/.*Jail list:[[:space:]]*//p')"; then
    err "fail2ban-client status failed"
    exit 1
  fi
  if [[ -z "${jails_csv}" ]]; then
    warn "no fail2ban jails are configured"
    return 0
  fi

  log "fail2ban jails: ${jails_csv}"

  local jail
  local -a jails
  IFS=', ' read -r -a jails <<< "${jails_csv}"
  for jail in "${jails[@]}"; do
    [[ -z "${jail}" ]] && continue
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
      log "DRY_RUN: fail2ban-client set ${jail} unbanip ${ip}"
    else
      log "+ fail2ban-client set ${jail} unbanip ${ip}"
      if ! fail2ban-client set "${jail}" unbanip "${ip}" > /dev/null 2>&1; then
        log "  (not banned in ${jail})"
      fi
    fi
  done

  log "current bans:"
  for jail in "${jails[@]}"; do
    [[ -z "${jail}" ]] && continue
    fail2ban-client status "${jail}" 2> /dev/null |
      sed -n 's/^[[:space:]]*|- Banned IP list:[[:space:]]*/  '"${jail}"': /p' || true
  done
}

unlock_user() {
  local u="$1"
  require_cmd faillock

  if ! id "${u}" > /dev/null 2>&1; then
    err "user not found: ${u}"
    exit 1
  fi

  log "faillock state before:"
  faillock --user "${u}" || true

  run faillock --user "${u}" --reset

  log "faillock state after:"
  faillock --user "${u}" || true
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
  esac

  if [[ -z "${TARGET_USER:-}" && -z "${IP:-}" ]]; then
    err "at least one of TARGET_USER or IP must be set (use --help)"
    exit 2
  fi

  if [[ "${EUID}" -ne 0 ]]; then
    err "must run as root"
    exit 1
  fi

  if [[ -n "${IP:-}" ]]; then
    if ! is_ip_literal "${IP}"; then
      err "IP does not look like an IPv4/IPv6 literal: ${IP}"
      exit 2
    fi
    log "=== unban IP ${IP} ==="
    unban_ip "${IP}"
  fi

  if [[ -n "${TARGET_USER:-}" ]]; then
    log "=== reset faillock for user ${TARGET_USER} ==="
    unlock_user "${TARGET_USER}"
  fi
}

main "$@"
