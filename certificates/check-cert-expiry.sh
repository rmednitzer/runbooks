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
# Requirements
#   - openssl
#   - GNU date (for RFC-date arithmetic)
#
# Environment variables
#   HOST            Hostname to connect to (required, or pass as $1).
#   PORT            TCP port (default 443).
#   SNI             SNI name (default: HOST).
#   STARTTLS        STARTTLS protocol passed to openssl s_client
#                   (smtp, imap, pop3, ftp, xmpp, …); empty disables.
#   THRESHOLD_DAYS  Fail when days remaining is below this (default 30).
#   CONNECT_TIMEOUT openssl s_client connection timeout, seconds
#                   (default 10).
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

usage() {
  cat << 'EOF'
Usage:
  HOST=<host> [PORT=443] [SNI=<host>] [STARTTLS=smtp] \
    [THRESHOLD_DAYS=30] [CONNECT_TIMEOUT=10] check-cert-expiry.sh
  check-cert-expiry.sh <host> [port]

Report TLS certificate expiry on a host:port. Exits non-zero when days
remaining drops below THRESHOLD_DAYS or the connection fails.

Environment variables:
  HOST            Hostname (required, or pass as $1).
  PORT            TCP port (default 443).
  SNI             SNI name (default: HOST).
  STARTTLS        STARTTLS protocol (smtp, imap, pop3, ftp, xmpp, …).
  THRESHOLD_DAYS  Fail below this (default 30).
  CONNECT_TIMEOUT openssl s_client timeout, seconds (default 10).

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
  if ! [[ "${timeout_s}" =~ ^[0-9]+$ ]]; then
    err "CONNECT_TIMEOUT must be a non-negative integer (got: ${timeout_s})"
    exit 2
  fi

  require_cmd openssl date

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

  local s_client_args=(
    -connect "${host}:${port}"
    -servername "${sni}"
    -showcerts
  )
  if [[ -n "${starttls}" ]]; then
    s_client_args+=(-starttls "${starttls}")
  fi

  local cert
  if ! cert="$(openssl s_client "${s_client_args[@]}" \
    -connect_timeout "${timeout_s}" < /dev/null 2> /dev/null |
    openssl x509 -outform PEM 2> /dev/null)"; then
    err "could not retrieve certificate from ${host}:${port}"
    exit 1
  fi
  if [[ -z "${cert}" ]]; then
    err "empty certificate from ${host}:${port}"
    exit 1
  fi

  local not_after subject issuer
  not_after="$(printf '%s\n' "${cert}" | openssl x509 -noout -enddate 2> /dev/null | sed -n 's/^notAfter=//p')"
  subject="$(printf '%s\n' "${cert}" | openssl x509 -noout -subject 2> /dev/null | sed -n 's/^subject= //p')"
  issuer="$(printf '%s\n' "${cert}" | openssl x509 -noout -issuer 2> /dev/null | sed -n 's/^issuer= //p')"

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
  log "not_after  : ${not_after}"
  log "days_left  : ${days_left}"

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
