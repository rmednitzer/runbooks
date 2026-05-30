#!/usr/bin/env bash
# conntrack-triage.sh — is the netfilter conntrack table near exhaustion?
#
# Why this exists
#   "nf_conntrack: table full, dropping packet" in dmesg means new
#   connections are being SILENTLY DROPPED — a brutal, hard-to-diagnose
#   outage on a busy box (NAT gateway, reverse proxy, k8s node). The fix is
#   obvious once you SEE it, but the symptom (random connection failures)
#   rarely points at conntrack. This script gives the one-page picture an
#   operator wants: current conntrack count vs the configured max and the
#   percentage used, whether the kernel has logged table-full drops, and
#   the top talkers in the table (by destination port and by source IP) so
#   you can see WHAT is filling it. It is read-only.
#
# Where the numbers come from
#   - count/max: from sysctl net.netfilter.nf_conntrack_count /
#     nf_conntrack_max, falling back to the /proc/sys paths directly so the
#     script works without the `sysctl` binary.
#   - drops: dmesg / kernel log lines mentioning "nf_conntrack: table full".
#   - top talkers: the `conntrack -L` table (conntrack-tools) when present,
#     else /proc/net/nf_conntrack. Either is parsed read-only.
#
# Requirements (bash >= 4 on GNU/Linux; see CLAUDE.md)
#   - Read access to /proc/sys/net/netfilter/* (root recommended; conntrack
#     accounting must be enabled in the kernel — it is, on any box doing
#     NAT/stateful filtering).
#   - coreutils awk, sort, head; optional: sysctl, conntrack (conntrack-
#     tools), dmesg.
#   Targets bash >= 4 + GNU coreutils. If conntrack is not in use on this
#   host (no nf_conntrack), the script says so and exits cleanly.
#
# Environment variables
#   WARN_PCT   Warn (and exit non-zero) at/above this % of max (default 80).
#   TOP_N      Number of top talkers to list per dimension (default 10).
#
# Exit codes
#   0  conntrack usage below WARN_PCT (or conntrack not in use here)
#   1  usage at/above WARN_PCT, table-full drops seen, OR a runtime error
#   2  invalid argument (bad WARN_PCT / TOP_N)

set -euo pipefail

log() { printf '[conntrack] %s\n' "$*"; }
warn() { printf '[conntrack] WARN: %s\n' "$*" >&2; }
err() { printf '[conntrack] ERR: %s\n' "$*" >&2; }

# Uniform failure reporting. No temp files in this script.
trap 'err "failed at line ${LINENO}"; exit 1' ERR

usage() {
  cat << 'EOF'
Usage: [WARN_PCT=80] [TOP_N=10] conntrack-triage.sh

Report netfilter conntrack table usage vs max, any "table full" drops,
and the top talkers filling the table (by dest port and source IP). For
diagnosing nf_conntrack exhaustion (silent connection drops). Read-only.

Environment variables:
  WARN_PCT   Warn + exit non-zero at/above this % of max (default 80).
  TOP_N      Top talkers to list per dimension (default 10).

Run as root for full table visibility. Examples:
  ./conntrack-triage.sh
  WARN_PCT=90 TOP_N=20 ./conntrack-triage.sh
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

# Read a single kernel tunable by name, preferring sysctl but falling back
# to the /proc/sys path so the script works without the sysctl binary.
# Prints the value, or nothing if unavailable.
read_tunable() {
  local key="$1"
  local proc="/proc/sys/${key//.//}"
  if command -v sysctl > /dev/null 2>&1; then
    # sysctl -n prints just the value; suppress its error if key is absent.
    sysctl -n "${key}" 2> /dev/null && return 0
  fi
  if [[ -r "${proc}" ]]; then
    cat -- "${proc}" 2> /dev/null && return 0
  fi
  return 0
}

# Echo the conntrack table contents (one flow per line) from the best
# available source: conntrack -L (richer), else /proc/net/nf_conntrack.
# Prints nothing if neither is available.
conntrack_table() {
  if command -v conntrack > /dev/null 2>&1; then
    conntrack -L 2> /dev/null && return 0
  fi
  if [[ -r /proc/net/nf_conntrack ]]; then
    cat -- /proc/net/nf_conntrack 2> /dev/null && return 0
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

  local warn_pct="${WARN_PCT:-80}"
  local top_n="${TOP_N:-10}"
  if ! [[ "${warn_pct}" =~ ^[0-9]+$ ]] || ((warn_pct < 1 || warn_pct > 100)); then
    err "WARN_PCT must be 1..100 (got: ${warn_pct})"
    exit 2
  fi
  if ! [[ "${top_n}" =~ ^[0-9]+$ ]] || ((top_n < 1)); then
    err "TOP_N must be a positive integer (got: ${top_n})"
    exit 2
  fi

  require_cmd awk sort head

  if [[ "${EUID}" -ne 0 ]]; then
    warn "not running as root — table visibility may be partial"
  fi

  # Is conntrack even in use here? If the count tunable is missing, this
  # box is not tracking connections; nothing to triage.
  local count max
  count="$(read_tunable net.netfilter.nf_conntrack_count)"
  max="$(read_tunable net.netfilter.nf_conntrack_max)"

  if [[ -z "${count}" || -z "${max}" ]]; then
    log "nf_conntrack does not appear to be in use on this host"
    log "(no net.netfilter.nf_conntrack_count/max) — nothing to triage"
    exit 0
  fi
  if ! [[ "${count}" =~ ^[0-9]+$ && "${max}" =~ ^[0-9]+$ ]] || ((max == 0)); then
    err "unexpected conntrack count/max values (count='${count}' max='${max}')"
    exit 1
  fi

  local pct=$((count * 100 / max))
  log "conntrack count : ${count}"
  log "conntrack max   : ${max}"
  log "usage           : ${pct}% of max (warn at ${warn_pct}%)"
  log "mode            : READ-ONLY"

  # Kernel "table full" drops — the smoking gun. Best-effort via dmesg.
  log ""
  log "--- 'table full' drops in the kernel log ---"
  local drops=""
  if command -v dmesg > /dev/null 2>&1; then
    # set -e intentionally disabled: grep finding nothing is normal.
    # shellcheck disable=SC2310,SC2312
    drops="$(dmesg 2> /dev/null | grep -i 'nf_conntrack: table full' | tail -n 5 || true)"
  fi
  if [[ -n "${drops}" ]]; then
    printf '%s\n' "${drops}" | awk '{ print "    " $0 }'
  else
    log "    none found (dmesg may be restricted; check rate-limited kernel logs)"
  fi

  # Top talkers: parse the table for destination ports and source IPs. Both
  # conntrack -L and /proc/net/nf_conntrack expose dport=/src= tokens, so we
  # extract those tokens regardless of source.
  local table
  table="$(conntrack_table)"

  log ""
  log "--- top ${top_n} destination ports in the conntrack table ---"
  if [[ -n "${table}" ]]; then
    # Pull every dport=NNN token, count and rank.
    # shellcheck disable=SC2312
    printf '%s\n' "${table}" |
      grep -oE 'dport=[0-9]+' | sort | uniq -c | sort -rn |
      head -n "${top_n}" | awk '{ printf "    %8d  %s\n", $1, $2 }' || true
  else
    log "    (no readable conntrack table: install conntrack-tools or check"
    log "     /proc/net/nf_conntrack permissions)"
  fi

  log ""
  log "--- top ${top_n} source addresses in the conntrack table ---"
  if [[ -n "${table}" ]]; then
    # The FIRST src= on each line is the original-direction source.
    # shellcheck disable=SC2312
    printf '%s\n' "${table}" |
      grep -oE 'src=[0-9a-fA-F.:]+' | sort | uniq -c | sort -rn |
      head -n "${top_n}" | awk '{ printf "    %8d  %s\n", $1, $2 }' || true
  fi

  log ""
  log "remedies if exhausted: raise net.netfilter.nf_conntrack_max, shorten"
  log "timeouts (nf_conntrack_tcp_timeout_*), or exempt high-volume flows with"
  log "a 'notrack' rule. Tune via the automation/roles/common Ansible role."

  log ""
  if ((pct >= warn_pct)) || [[ -n "${drops}" ]]; then
    err "conntrack table at ${pct}% of max${drops:+ and table-full drops were logged}"
    exit 1
  fi
  log "OK: conntrack usage is below ${warn_pct}%"
}

# Only execute when run directly; sourcing (e.g. from bats) must not run main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
