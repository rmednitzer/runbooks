#!/usr/bin/env bash
# check-cert-expiry.sh — report TLS certificate expiry on a host:port.
#
# Why this exists
#   Spot-check a certificate's expiry around a renewal, for endpoints
#   that ACME automation does not cover (legacy services, internal CAs,
#   third-party endpoints we depend on). Connects with openssl s_client,
#   parses the leaf certificate's notAfter, and reports days remaining.
#   Exits non-zero when days remaining drops below THRESHOLD_DAYS — fit
#   for an ad-hoc cron + ops alert without a full monitoring pipeline.
#
#   Only the LEAF certificate is inspected. Intermediates/roots in the
#   chain are not checked here; if a renewal also rotated an intermediate
#   you must verify that separately. The script also warns when the leaf
#   is not yet valid (notBefore in the future) — a clock skew or a
#   prematurely deployed certificate.
#
# Connection timeout
#   openssl s_client has NO connection-timeout option of its own, so the
#   whole openssl invocation is wrapped in coreutils timeout(1)
#   (CONNECT_TIMEOUT seconds). A hung TCP connect therefore fails fast
#   instead of blocking the operator (or a cron slot) indefinitely.
#
# Requirements (bash >= 4; see CLAUDE.md)
#   - openssl
#   - GNU date (for RFC-date arithmetic)
#   - coreutils timeout (to bound the openssl connection)
#
# Environment variables
#   HOST            Hostname to connect to (required, or pass as $1).
#   PORT            TCP port (default 443).
#   SNI             SNI name (default: HOST).
#   STARTTLS        STARTTLS protocol passed to openssl s_client
#                   (smtp, imap, pop3, ftp, xmpp, …); empty disables.
#   THRESHOLD_DAYS  Fail when days remaining is below this (default 30).
#   CONNECT_TIMEOUT Seconds to allow the openssl connection to run before
#                   timeout(1) kills it (default 10).
#
# Exit codes
#   0  success; days remaining >= THRESHOLD_DAYS
#   1  certificate expired, expiring within THRESHOLD_DAYS, or
#      connection / parse failure
#   2  invalid argument

set -euo pipefail

log() { printf '[cert-expiry] %s\n' "$*"; }
warn() { printf '[cert-expiry] WARN: %s\n' "$*" >&2; }
err() { printf '[cert-expiry] ERR: %s\n' "$*" >&2; }

# Temp file holding the retrieved PEM; cleaned up on any exit.
PEM_FILE=""
cleanup() {
  [[ -n "${PEM_FILE}" && -f "${PEM_FILE}" ]] && rm -f -- "${PEM_FILE}"
  return 0
}
# Uniform failure reporting + temp-file cleanup. EXIT runs cleanup on
# every path; ERR pinpoints the failing line for an operator at 03:00.
trap 'cleanup' EXIT
trap 'err "failed at line ${LINENO}"; exit 1' ERR

usage() {
  cat << 'EOF'
Usage:
  HOST=<host> [PORT=443] [SNI=<host>] [STARTTLS=smtp] \
    [THRESHOLD_DAYS=30] [CONNECT_TIMEOUT=10] check-cert-expiry.sh
  check-cert-expiry.sh <host> [port]

Report TLS certificate expiry on a host:port. Exits non-zero when days
remaining drops below THRESHOLD_DAYS or the connection fails. Only the
leaf certificate is inspected.

Environment variables:
  HOST            Hostname (required, or pass as $1).
  PORT            TCP port (default 443).
  SNI             SNI name (default: HOST).
  STARTTLS        STARTTLS protocol (smtp, imap, pop3, ftp, xmpp, …).
  THRESHOLD_DAYS  Fail below this (default 30).
  CONNECT_TIMEOUT Seconds before timeout(1) kills openssl (default 10).

Examples:
  HOST=example.com ./check-cert-expiry.sh
  ./check-cert-expiry.sh example.com 8443
  HOST=mail.example.com PORT=587 STARTTLS=smtp ./check-cert-expiry.sh
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

main() {
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
    *) ;;
  esac

  local host="${HOST:-${1:-}}"
  local port="${PORT:-${2:-443}}"
  local sni="${SNI:-${host}}"
  local starttls="${STARTTLS:-}"
  local threshold_days="${THRESHOLD_DAYS:-30}"
  local timeout_s="${CONNECT_TIMEOUT:-10}"

  if [[ -z "${host}" ]]; then
    err "HOST is required (use --help for usage)"
    exit 2
  fi
  if ! [[ "${port}" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
    err "PORT must be 1..65535 (got: ${port})"
    exit 2
  fi
  if ! [[ "${threshold_days}" =~ ^[0-9]+$ ]]; then
    err "THRESHOLD_DAYS must be a non-negative integer (got: ${threshold_days})"
    exit 2
  fi
  # Must be >= 1: `timeout 0 ...` means "no timeout" in coreutils, which
  # would defeat the purpose of bounding the connection.
  if ! [[ "${timeout_s}" =~ ^[0-9]+$ ]] || ((timeout_s < 1)); then
    err "CONNECT_TIMEOUT must be a positive integer, seconds (got: ${timeout_s})"
    exit 2
  fi

  require_cmd openssl date timeout

  # GNU `date -d` is required; BusyBox date will not parse openssl's
  # output. Detect by feature, not by uname.
  if ! date -d '2030-01-01' +%s > /dev/null 2>&1; then
    err "GNU date with -d is required (this looks like BusyBox)"
    exit 1
  fi

  log "endpoint   : ${host}:${port}"
  log "sni        : ${sni}"
  log "starttls   : ${starttls:-<none>}"
  log "threshold  : ${threshold_days} days"

  # -connect carries the host:port exactly once. openssl s_client has no
  # connection-timeout flag, so the whole call is wrapped in timeout(1)
  # below — do NOT add an openssl -connect_timeout option; it does not
  # exist ("Unknown option") and silently aborts the connection.
  local s_client_args=(
    -connect "${host}:${port}"
    -servername "${sni}"
    -showcerts
  )
  if [[ -n "${starttls}" ]]; then
    s_client_args+=(-starttls "${starttls}")
  fi

  PEM_FILE="$(mktemp)"

  # timeout(1) bounds the connection: a hung TCP connect is killed after
  # CONNECT_TIMEOUT seconds instead of blocking forever. We capture the
  # leaf PEM to a temp file (cleaned up by the EXIT trap) rather than a
  # giant shell variable. `openssl x509` reads the first (leaf)
  # certificate from the s_client output and re-emits it as PEM.
  if ! timeout "${timeout_s}" openssl s_client "${s_client_args[@]}" \
    < /dev/null 2> /dev/null |
    openssl x509 -outform PEM > "${PEM_FILE}" 2> /dev/null; then
    err "could not retrieve certificate from ${host}:${port}" \
      "(connection failed, timed out after ${timeout_s}s, or no TLS cert offered)"
    exit 1
  fi
  if [[ ! -s "${PEM_FILE}" ]]; then
    err "empty certificate from ${host}:${port}"
    exit 1
  fi

  local not_after not_before subject issuer
  not_after="$(openssl x509 -in "${PEM_FILE}" -noout -enddate 2> /dev/null | sed -n 's/^notAfter=//p')"
  not_before="$(openssl x509 -in "${PEM_FILE}" -noout -startdate 2> /dev/null | sed -n 's/^notBefore=//p')"
  subject="$(openssl x509 -in "${PEM_FILE}" -noout -subject 2> /dev/null | sed -n 's/^subject= *//p')"
  issuer="$(openssl x509 -in "${PEM_FILE}" -noout -issuer 2> /dev/null | sed -n 's/^issuer= *//p')"

  if [[ -z "${not_after}" ]]; then
    err "could not parse notAfter from certificate"
    exit 1
  fi

  local expiry_epoch now_epoch days_left
  if ! expiry_epoch="$(date -d "${not_after}" +%s 2> /dev/null)"; then
    err "could not parse expiry date: ${not_after}"
    exit 1
  fi
  now_epoch="$(date +%s)"
  days_left=$(((expiry_epoch - now_epoch) / 86400))

  log "subject    : ${subject}"
  log "issuer     : ${issuer}"
  log "not_before : ${not_before:-<unparsed>}"
  log "not_after  : ${not_after}"
  log "days_left  : ${days_left}"

  # notBefore in the future means the cert is not yet valid — clock skew
  # on this host, or a certificate deployed ahead of its validity window.
  # Warn but keep going so the expiry check still reports.
  if [[ -n "${not_before}" ]]; then
    local not_before_epoch
    if not_before_epoch="$(date -d "${not_before}" +%s 2> /dev/null)"; then
      if ((not_before_epoch > now_epoch)); then
        warn "certificate is NOT YET VALID (notBefore ${not_before}); check clock skew"
      fi
    fi
  fi

  if ((days_left < 0)); then
    err "certificate EXPIRED ${days_left#-} day(s) ago"
    exit 1
  fi
  if ((days_left < threshold_days)); then
    err "certificate expires in ${days_left} day(s); threshold is ${threshold_days}"
    exit 1
  fi
  log "OK"
}

main "$@"
