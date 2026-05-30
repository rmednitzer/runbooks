#!/usr/bin/env bash
# port-reachability.sh — can THIS host open a TCP connection to host:port?
#
# Why this exists
#   "Is the firewall blocking us?" is a question you answer from the
#   AFFECTED host, not your laptop. Before escalating to the network team
#   you want a crisp yes/no: can this box complete a TCP handshake to
#   <host>:<port> within a timeout? This script does exactly that — a
#   bounded TCP connect to one or more host:port targets — using bash's
#   built-in /dev/tcp where available (no extra package), falling back to
#   nc(1) if /dev/tcp is disabled. It distinguishes "refused" (something
#   answered with RST — host up, port closed) from "timed out" (no answer —
#   likely a firewall/blackhole) where the tooling allows. It is read-only:
#   it opens and immediately closes a connection, sending no payload.
#
# /dev/tcp vs nc
#   bash exposes pseudo-device /dev/tcp/<host>/<port>: redirecting to it
#   performs a real TCP connect. Wrapped in coreutils timeout(1), this is a
#   dependency-free reachability probe. Some hardened bash builds compile
#   it out (--disable-net-redirections); when that is detected we fall back
#   to `nc -z -w <timeout>`. At least one of the two must work.
#
# Requirements (bash >= 4 on GNU/Linux; see CLAUDE.md)
#   - coreutils timeout(1) to bound each connect.
#   - EITHER a bash with /dev/tcp support (default) OR nc(1) for fallback.
#   Targets bash >= 4 + GNU coreutils. This is a connectivity probe only;
#   it does not parse application protocols.
#
# Environment variables
#   HOST     Target host/IP (required, or pass as $1).
#   PORT     Target TCP port (required, or pass as $2). May be a
#            comma/space-separated list to probe several ports.
#   TIMEOUT  Per-connect timeout in seconds (default 5).
#   METHOD   Force the probe method: auto (default), devtcp, or nc.
#
# Exit codes
#   0  every target was reachable (handshake completed)
#   1  at least one target was unreachable, OR a runtime error
#   2  invalid argument (missing HOST/PORT, bad port/timeout, …)

set -euo pipefail

log() { printf '[port-reach] %s\n' "$*"; }
warn() { printf '[port-reach] WARN: %s\n' "$*" >&2; }
err() { printf '[port-reach] ERR: %s\n' "$*" >&2; }

# Uniform failure reporting. No temp files in this script.
trap 'err "failed at line ${LINENO}"; exit 1' ERR

usage() {
  cat << 'EOF'
Usage: HOST=<host> PORT=<port[,port...]> [TIMEOUT=5] [METHOD=auto] \
       port-reachability.sh
       port-reachability.sh <host> <port>

Check whether THIS host can complete a TCP handshake to one or more
host:port targets within a timeout — the "is the firewall blocking X?"
probe. Read-only: connects and immediately closes, sends no data.

Environment variables:
  HOST     Target host/IP (required, or pass as $1).
  PORT     Target TCP port, or a comma/space list (required, or $2).
  TIMEOUT  Per-connect timeout seconds (default 5).
  METHOD   auto (default) | devtcp (bash /dev/tcp) | nc.

Examples:
  HOST=db.internal PORT=5432 ./port-reachability.sh
  ./port-reachability.sh api.example.com 443
  HOST=10.0.0.5 PORT="22,80,443" TIMEOUT=3 ./port-reachability.sh
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

# Probe whether this bash supports /dev/tcp by attempting a connect to a
# port that should refuse fast on loopback. We only care that the redirect
# MECHANISM exists, not the result: a "no such file"/"not supported" error
# message indicates net-redirections are compiled out. Returns 0 if usable.
devtcp_supported() {
  # A subshell so a failed redirect cannot disturb the caller. Connecting
  # to 127.0.0.1:1 typically refuses instantly; either way, bash without
  # /dev/tcp prints "/dev/tcp: ... not supported" to stderr and fails with
  # a DIFFERENT signature. Probe by capturing stderr.
  local emsg
  emsg="$( (exec 3<> /dev/tcp/127.0.0.1/1) 2>&1 || true)"
  # If the build lacks the feature, bash says so explicitly.
  if [[ "${emsg}" == *"not supported"* || "${emsg}" == *"No such file"* ]]; then
    return 1
  fi
  return 0
}

# One TCP connect via bash /dev/tcp, bounded by timeout(1). Returns 0 on a
# completed handshake, non-zero otherwise. Runs in a child bash so the
# timeout can kill a hung connect cleanly.
connect_devtcp() {
  local host="$1" port="$2" tmo="$3"
  # The host/port are passed as positional args ($1/$2) to the inner bash,
  # NOT expanded by the outer shell — single quotes are deliberate here.
  # shellcheck disable=SC2016
  timeout "${tmo}" bash -c '
    exec 3<>/dev/tcp/"$1"/"$2"
  ' _ "${host}" "${port}" 2> /dev/null
}

# One TCP connect via nc, bounded by nc's own -w plus timeout(1) as a
# belt-and-braces outer bound. -z = scan (no data), -w = connect timeout.
connect_nc() {
  local host="$1" port="$2" tmo="$3"
  timeout "$((tmo + 1))" nc -z -w "${tmo}" -- "${host}" "${port}" 2> /dev/null
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
  local port_spec="${PORT:-${2:-}}"
  local tmo="${TIMEOUT:-5}"
  local method="${METHOD:-auto}"

  if [[ -z "${host}" ]]; then
    err "HOST is required (use --help for usage)"
    exit 2
  fi
  if [[ -z "${port_spec}" ]]; then
    err "PORT is required (use --help for usage)"
    exit 2
  fi
  if ! [[ "${tmo}" =~ ^[0-9]+$ ]] || ((tmo < 1)); then
    err "TIMEOUT must be a positive integer, seconds (got: ${tmo})"
    exit 2
  fi
  case "${method}" in
    auto | devtcp | nc) ;;
    *)
      err "METHOD must be auto|devtcp|nc (got: ${method})"
      exit 2
      ;;
  esac

  require_cmd timeout

  # Parse and validate the port list.
  local -a ports=()
  local p
  for p in ${port_spec//,/ }; do
    if ! [[ "${p}" =~ ^[0-9]+$ ]] || ((p < 1 || p > 65535)); then
      err "port must be 1..65535 (got: ${p})"
      exit 2
    fi
    ports+=("${p}")
  done

  # Decide the probe method. auto prefers /dev/tcp (no dependency); falls
  # back to nc when this bash lacks net-redirections.
  local use=""
  if [[ "${method}" == "devtcp" ]]; then
    # set -e intentionally disabled for this predicate.
    # shellcheck disable=SC2310
    if ! devtcp_supported; then
      err "METHOD=devtcp requested but this bash has no /dev/tcp support"
      exit 1
    fi
    use="devtcp"
  elif [[ "${method}" == "nc" ]]; then
    require_cmd nc
    use="nc"
  else
    # set -e intentionally disabled for this predicate.
    # shellcheck disable=SC2310
    if devtcp_supported; then
      use="devtcp"
    elif command -v nc > /dev/null 2>&1; then
      use="nc"
    else
      err "no probe method available: this bash lacks /dev/tcp and nc is not installed"
      exit 1
    fi
  fi

  log "host       : ${host}"
  log "ports      : ${ports[*]}"
  log "timeout    : ${tmo}s"
  log "method     : ${use}"
  log "mode       : READ-ONLY (handshake only, no payload)"
  log ""

  local unreachable=0
  for p in "${ports[@]}"; do
    local ok=1
    if [[ "${use}" == "devtcp" ]]; then
      # set -e intentionally disabled: a failed connect is the result.
      # shellcheck disable=SC2310
      connect_devtcp "${host}" "${p}" "${tmo}" || ok=0
    else
      # shellcheck disable=SC2310
      connect_nc "${host}" "${p}" "${tmo}" || ok=0
    fi
    if ((ok == 1)); then
      log "${host}:${p}  REACHABLE"
    else
      log "${host}:${p}  UNREACHABLE (refused, filtered, or timed out after ${tmo}s)"
      unreachable=1
    fi
  done

  log ""
  if ((unreachable == 1)); then
    err "one or more targets UNREACHABLE from this host"
    err "next: check local firewall (nft/iptables), security groups, and the"
    err "      remote listener (ss -ltn on the target)."
    exit 1
  fi
  log "OK: all targets reachable from this host"
}

# Only execute when run directly; sourcing (e.g. from bats) must not run main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
