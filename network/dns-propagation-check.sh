#!/usr/bin/env bash
# dns-propagation-check.sh — query one record across many resolvers, flag divergence.
#
# Why this exists
#   "Half the fleet resolves the new IP, half still has the old one" is a
#   classic 03:00 symptom after a DNS change (a record edit, a failover, a
#   CDN swap). Before blaming the app you want to know what each resolver
#   actually returns for the record RIGHT NOW. This script queries the same
#   name+type against a set of resolvers (public ones plus this host's own
#   configured resolvers), normalises and sorts each answer set, and flags
#   any resolver whose answer DIVERGES from the majority — the propagation
#   /split-horizon/stale-cache picture on one page. It is read-only.
#
# What "divergence" means here
#   For each resolver we collect the sorted set of answer records. The
#   majority answer (the set returned by the most resolvers) is the
#   baseline; any resolver returning a different set (including an empty
#   answer / failure) is reported as DIVERGENT. Exit is non-zero if any
#   resolver diverges, so this is usable as an ad-hoc check.
#
# Requirements (bash >= 4 on GNU/Linux; see CLAUDE.md)
#   - dig (bind9-dnsutils / bind-utils) — primary query tool.
#   - getent is used only to read this host's own resolvers via
#     /etc/resolv.conf parsing; not required.
#   - coreutils sort, comm; awk.
#   Targets bash >= 4 + GNU coreutils. dig must be present (checked at
#   startup); without it the script cannot run.
#
# Environment variables
#   NAME        DNS name to query (required, or pass as $1).
#   RTYPE       Record type: A, AAAA, CNAME, MX, TXT, NS, … (default A).
#   RESOLVERS   Space/comma-separated resolver IPs to query. Default:
#               a built-in public set (1.1.1.1, 8.8.8.8, 9.9.9.9, plus
#               the IPv6 anycasts) UNION this host's /etc/resolv.conf
#               nameservers.
#   TIMEOUT     Per-query timeout in seconds (default 3).
#   TRIES       dig retries per resolver (default 1).
#
# Exit codes
#   0  all resolvers agree (no divergence)
#   1  at least one resolver diverged, OR a runtime error
#   2  invalid argument (missing NAME, bad TIMEOUT, …)

set -euo pipefail

log() { printf '[dns-prop] %s\n' "$*"; }
warn() { printf '[dns-prop] WARN: %s\n' "$*" >&2; }
err() { printf '[dns-prop] ERR: %s\n' "$*" >&2; }

# Temp dir holding one answer file per resolver; cleaned up on any exit.
WORK_DIR=""
cleanup() {
  [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]] && rm -rf -- "${WORK_DIR}"
  return 0
}
trap 'cleanup' EXIT
trap 'err "failed at line ${LINENO}"; exit 1' ERR

usage() {
  cat << 'EOF'
Usage: NAME=<name> [RTYPE=A] [RESOLVERS="1.1.1.1 8.8.8.8"] [TIMEOUT=3] \
       [TRIES=1] dns-propagation-check.sh
       dns-propagation-check.sh <name> [rtype]

Query one DNS record across multiple resolvers and flag any resolver whose
answer diverges from the majority (propagation / stale-cache / split-
horizon triage). Read-only.

Environment variables:
  NAME        DNS name to query (required, or pass as $1).
  RTYPE       Record type (default A).
  RESOLVERS   Resolver IPs to query (default: a public set UNION this
              host's /etc/resolv.conf nameservers).
  TIMEOUT     Per-query timeout seconds (default 3).
  TRIES       dig retries per resolver (default 1).

Examples:
  NAME=example.com ./dns-propagation-check.sh
  ./dns-propagation-check.sh api.internal AAAA
  NAME=example.com RESOLVERS="1.1.1.1 8.8.8.8 9.9.9.9" ./dns-propagation-check.sh
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

# Read this host's own resolvers from /etc/resolv.conf (the answer THIS box
# would get). Best-effort: prints nothing if the file is unreadable.
host_resolvers() {
  [[ -r /etc/resolv.conf ]] || return 0
  awk '/^[[:space:]]*nameserver[[:space:]]+/ { print $2 }' /etc/resolv.conf 2> /dev/null || true
}

# Query <resolver> for the current name/type and print a normalised,
# sorted answer set (one record per line). An error/timeout prints the
# sentinel "<NO-ANSWER>" so a failing resolver shows up as divergent
# rather than silently matching. dig +short gives just the answer data.
query_resolver() {
  local resolver="$1" name="$2" rtype="$3" tmo="$4" tries="$5"
  local out
  # set -e intentionally disabled: a resolver failing is data, not fatal.
  # shellcheck disable=SC2310
  out="$(dig +short +timeout="${tmo}" +tries="${tries}" \
    "@${resolver}" "${name}" "${rtype}" 2> /dev/null || true)"
  # Strip blank lines, sort for set-comparison stability.
  out="$(printf '%s\n' "${out}" | awk 'NF' | sort || true)"
  if [[ -z "${out}" ]]; then
    printf '<NO-ANSWER>\n'
  else
    printf '%s\n' "${out}"
  fi
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
    *) ;;
  esac

  local name="${NAME:-${1:-}}"
  local rtype="${RTYPE:-${2:-A}}"
  local tmo="${TIMEOUT:-3}"
  local tries="${TRIES:-1}"

  if [[ -z "${name}" ]]; then
    err "NAME is required (use --help for usage)"
    exit 2
  fi
  if ! [[ "${tmo}" =~ ^[0-9]+$ ]] || ((tmo < 1)); then
    err "TIMEOUT must be a positive integer, seconds (got: ${tmo})"
    exit 2
  fi
  if ! [[ "${tries}" =~ ^[0-9]+$ ]] || ((tries < 1)); then
    err "TRIES must be a positive integer (got: ${tries})"
    exit 2
  fi
  # Uppercase the record type so 'a' and 'A' behave the same.
  rtype="${rtype^^}"

  require_cmd dig awk sort

  # Build the resolver set: explicit RESOLVERS, else a public set UNION the
  # host's own nameservers. De-duplicate while preserving order.
  local -a resolvers=()
  local r
  if [[ -n "${RESOLVERS:-}" ]]; then
    local raw="${RESOLVERS//,/ }"
    for r in ${raw}; do resolvers+=("${r}"); done
  else
    local -a public=(1.1.1.1 8.8.8.8 9.9.9.9 2606:4700:4700::1111 2001:4860:4860::8888)
    for r in "${public[@]}"; do resolvers+=("${r}"); done
    local hr
    # host_resolvers ends in `|| true`, so it cannot fail; the process
    # substitution's return value is irrelevant here.
    # shellcheck disable=SC2312
    while IFS= read -r hr; do
      [[ -n "${hr}" ]] && resolvers+=("${hr}")
    done < <(host_resolvers)
  fi

  # De-duplicate.
  local -A seen=()
  local -a uniq=()
  for r in "${resolvers[@]}"; do
    [[ -z "${r}" ]] && continue
    if [[ -z "${seen[${r}]:-}" ]]; then
      seen[${r}]=1
      uniq+=("${r}")
    fi
  done
  resolvers=("${uniq[@]}")

  if ((${#resolvers[@]} == 0)); then
    err "no resolvers to query (set RESOLVERS or provide /etc/resolv.conf)"
    exit 2
  fi

  log "name       : ${name}"
  log "type       : ${rtype}"
  log "resolvers  : ${resolvers[*]}"
  log "timeout    : ${tmo}s  tries=${tries}"
  log "mode       : READ-ONLY"
  log ""

  WORK_DIR="$(mktemp -d)"

  # Query each resolver, store its answer set, and tally identical sets so
  # we can pick the majority. We key the tally by a hash of the answer set.
  local -A tally=()
  local idx=0
  local -a res_file=() res_key=()
  for r in "${resolvers[@]}"; do
    local f="${WORK_DIR}/ans.${idx}"
    query_resolver "${r}" "${name}" "${rtype}" "${tmo}" "${tries}" > "${f}"
    # Key = the answer set itself, flattened to one line (records are
    # already sorted, so identical sets produce identical keys).
    local key
    key="$(awk 'BEGIN{ORS=";"} {print}' "${f}")"
    res_file+=("${f}")
    res_key+=("${key}")
    tally[${key}]=$(("${tally[${key}]:-0}" + 1))
    idx=$((idx + 1))
  done

  # Find the majority key (most frequent answer set).
  local majority_key="" majority_count=0 k
  for k in "${!tally[@]}"; do
    if ((tally[${k}] > majority_count)); then
      majority_count="${tally[${k}]}"
      majority_key="${k}"
    fi
  done

  # Report each resolver, marking divergence from the majority.
  local divergent=0
  idx=0
  for r in "${resolvers[@]}"; do
    local f="${res_file[${idx}]}"
    local key="${res_key[${idx}]}"
    local marker="ok"
    if [[ "${key}" != "${majority_key}" ]]; then
      marker="DIVERGENT"
      divergent=1
    fi
    log "=== ${r}  [${marker}] ==="
    # Print the answer set indented; awk keeps it tidy.
    awk '{ print "    " $0 }' "${f}"
    idx=$((idx + 1))
  done

  log ""
  log "majority answer seen on ${majority_count}/${#resolvers[@]} resolver(s):"
  printf '%s' "${majority_key}" | tr ';' '\n' | awk 'NF { print "    " $0 }'

  if ((divergent == 1)); then
    log ""
    err "DNS answers DIVERGE across resolvers (see DIVERGENT entries above)"
    err "likely propagation lag, a stale cache, or split-horizon DNS"
    exit 1
  fi
  log ""
  log "OK: all resolvers agree"
}

# Only execute when run directly; sourcing (e.g. from bats) must not run main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
