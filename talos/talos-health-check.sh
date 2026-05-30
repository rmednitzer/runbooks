#!/usr/bin/env bash
# talos-health-check.sh — one-page Talos cluster health summary (read-only).
#
# Why this exists
#   Talos Linux has NO SSH, NO shell, NO PAM, and no package manager on the
#   node. The host is a sealed, immutable API endpoint: every operator
#   action goes over the Talos gRPC API (mTLS) using `talosctl` and a
#   `talosconfig` (client cert + endpoints). So when a Talos cluster pages
#   at 03:00 you cannot `ssh` in and run `systemctl status` — your first
#   move is `talosctl`. This script is the Talos analogue of "log in and
#   look around": it runs the read-only checks an operator wants first —
#   `talosctl health`, node membership, etcd member list and status,
#   service state, and a recent-error dmesg tail — and prints them as a
#   single triage page. It changes NOTHING.
#
# The Talos no-SSH model (read this once if Talos is new to you)
#   - There is no node login. `talosctl` talks to apid on each node over
#     mTLS. Authentication is the client certificate inside talosconfig.
#   - `--endpoints/-e` are the control-plane IPs talosctl connects TO;
#     `--nodes/-n` are the machines a request is ABOUT (apid proxies to
#     them). Both default to whatever the current talosconfig context sets.
#   - This script honours TALOSCONFIG (path to the talosconfig) and an
#     optional NODES / ENDPOINTS override, exactly as talosctl does.
#
# What it checks (all read-only)
#   1. talosctl version (client+server) — confirms connectivity + mTLS.
#   2. talosctl get members — Talos discovery view of every node.
#   3. talosctl health --server=false — the built-in readiness assertions
#      (apid/etcd/kubelet up, k8s nodes Ready, control-plane static pods).
#      --server=false runs the checks CLIENT-side so it works against an
#      already-running cluster without needing the original init node.
#   4. talosctl etcd members / etcd status — etcd quorum view (control
#      plane only; on worker-only targets this is skipped with a note).
#   5. talosctl services — Talos service (apid, etcd, kubelet, …) states.
#   6. recent kernel errors via `talosctl dmesg` (best-effort tail).
#
# Requirements (bash >= 4 on GNU/Linux; see CLAUDE.md)
#   - talosctl (the Talos CLI) on PATH.
#   - A valid talosconfig: either the default (~/.talos/config) or one
#     pointed at by TALOSCONFIG / the TALOSCONFIG env var.
#   - Network reachability to the control-plane endpoints over the Talos
#     API port (default 50000).
#   This script targets bash >= 4 and GNU coreutils (see the platform note
#   in CLAUDE.md). It is read-only and safe to run AND re-run at any time.
#
# Environment variables
#   TALOSCONFIG   Path to the talosconfig (passed to talosctl
#                 --talosconfig). If unset, talosctl uses its default
#                 (~/.talos/config or the TALOSCONFIG it already honours).
#   NODES         Comma/space-separated node addresses (talosctl --nodes).
#                 If unset, the talosconfig context's nodes are used.
#   ENDPOINTS     Comma/space-separated endpoint addresses (talosctl
#                 --endpoints). If unset, the context's endpoints are used.
#   CONTEXT       talosconfig context name (talosctl --context).
#   DMESG_TAIL    Lines of dmesg to show (default 20; 0 disables dmesg).
#
# Exit codes
#   0  health checks ran and the cluster reported healthy
#   1  runtime error, OR `talosctl health` reported the cluster UNHEALTHY
#   2  invalid argument (bad DMESG_TAIL, …)

set -euo pipefail

log() { printf '[talos-health] %s\n' "$*"; }
warn() { printf '[talos-health] WARN: %s\n' "$*" >&2; }
err() { printf '[talos-health] ERR: %s\n' "$*" >&2; }

# Uniform failure reporting. This script is read-only and has no temp
# files, so there is nothing to clean up on exit.
trap 'err "failed at line ${LINENO}"; exit 1' ERR

usage() {
  cat << 'EOF'
Usage: [TALOSCONFIG=...] [NODES=...] [ENDPOINTS=...] [CONTEXT=...] \
       [DMESG_TAIL=20] talos-health-check.sh

Read-only Talos cluster health triage: version/connectivity, node
membership, `talosctl health` assertions, etcd quorum, service states,
and a recent-error dmesg tail. Changes nothing on the cluster.

Talos has no SSH/shell/PAM — everything is the talosctl gRPC API over
mTLS. --endpoints are the control-plane IPs talosctl connects TO;
--nodes are the machines a request is ABOUT.

Environment variables:
  TALOSCONFIG   Path to talosconfig (talosctl --talosconfig). Default:
                talosctl's own default (~/.talos/config).
  NODES         Node addresses (talosctl --nodes). Default: context's.
  ENDPOINTS     Endpoint addresses (talosctl --endpoints). Default: ctx.
  CONTEXT       talosconfig context name (talosctl --context).
  DMESG_TAIL    dmesg lines to show (default 20; 0 disables).

Examples:
  TALOSCONFIG=./talosconfig ./talos-health-check.sh
  NODES=10.0.0.2,10.0.0.3 ./talos-health-check.sh
  ENDPOINTS=10.0.0.2 NODES=10.0.0.2 DMESG_TAIL=0 ./talos-health-check.sh
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

# Assemble the common talosctl flags (talosconfig/context/endpoints/nodes)
# into a global array TALOS_FLAGS so every call shares the same targeting.
# Only flags whose env var is set are added; otherwise talosctl falls back
# to its talosconfig context, exactly as a bare `talosctl` would.
TALOS_FLAGS=()
build_talos_flags() {
  TALOS_FLAGS=()
  if [[ -n "${TALOSCONFIG:-}" ]]; then
    TALOS_FLAGS+=(--talosconfig "${TALOSCONFIG}")
  fi
  if [[ -n "${CONTEXT:-}" ]]; then
    TALOS_FLAGS+=(--context "${CONTEXT}")
  fi
  if [[ -n "${ENDPOINTS:-}" ]]; then
    TALOS_FLAGS+=(--endpoints "${ENDPOINTS}")
  fi
  if [[ -n "${NODES:-}" ]]; then
    TALOS_FLAGS+=(--nodes "${NODES}")
  fi
}

# Run a read-only talosctl subcommand under a banner. A non-zero exit is
# reported but NOT fatal here — partial telemetry (e.g. etcd unreachable)
# is exactly what we want to surface during triage, not a reason to abort
# the whole summary. This is fire-and-forget: it ALWAYS returns 0 so a
# failing section never aborts the run (and never trips set -e in callers).
# For the section whose verdict matters (health), see run_health below.
talos_section() {
  local title="$1"
  shift
  log ""
  log "=== ${title} ==="
  local rc=0
  # set -e intentionally disabled: we report and continue on failure.
  # shellcheck disable=SC2310
  talosctl "${TALOS_FLAGS[@]}" "$@" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    warn "${title}: talosctl exited ${rc} (continuing triage)"
  fi
  return 0
}

# Run `talosctl health` under a banner and return ITS exit status — this is
# the one section whose verdict is the script's overall result.
run_health() {
  log ""
  log "=== health (talosctl health --server=false) ==="
  local rc=0
  # set -e intentionally disabled: we want the status, not an abort.
  # shellcheck disable=SC2310
  talosctl "${TALOS_FLAGS[@]}" health --server=false || rc=$?
  return "${rc}"
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
    *) ;;
  esac

  local dmesg_tail="${DMESG_TAIL:-20}"
  if ! [[ "${dmesg_tail}" =~ ^[0-9]+$ ]]; then
    err "DMESG_TAIL must be a non-negative integer (got: ${dmesg_tail})"
    exit 2
  fi

  require_cmd talosctl
  build_talos_flags

  log "talosconfig: ${TALOSCONFIG:-<talosctl default>}"
  log "context    : ${CONTEXT:-<default>}"
  log "endpoints  : ${ENDPOINTS:-<from context>}"
  log "nodes      : ${NODES:-<from context>}"
  log "mode       : READ-ONLY (no changes are made)"

  # 1. Connectivity + version. If this fails the rest will too, but we
  #    keep going so the operator sees every error in one pass.
  talos_section "version (client + node)" version

  # 2. Talos discovery membership — every node Talos knows about.
  talos_section "members (talosctl get members)" get members

  # 3. The authoritative readiness assertion. --server=false runs the
  #    checks client-side so it works on a running cluster without the
  #    original bootstrap/init node. Its exit status is the cluster verdict.
  local health_rc=0
  # set -e intentionally disabled: run_health returns the verdict status.
  # shellcheck disable=SC2310
  run_health || health_rc=$?

  # 4. etcd quorum view. Control-plane only; on worker targets talosctl
  #    returns an error which we surface as informational.
  talos_section "etcd members" etcd members
  talos_section "etcd status" etcd status

  # 5. Talos service states (apid, etcd, kubelet, machined, …).
  talos_section "services (talosctl services)" services

  # 6. Recent kernel ring-buffer errors (best-effort). dmesg streams the
  #    whole buffer; we tail the last DMESG_TAIL lines. Skipped when 0.
  if [[ "${dmesg_tail}" -gt 0 ]]; then
    log ""
    log "=== recent dmesg (last ${dmesg_tail} lines) ==="
    # talosctl dmesg has no --tail of its own here; bound it with coreutils
    # tail. Pipe failures (e.g. dmesg unsupported) are non-fatal.
    # shellcheck disable=SC2310,SC2312
    talosctl "${TALOS_FLAGS[@]}" dmesg 2> /dev/null | tail -n "${dmesg_tail}" ||
      warn "dmesg unavailable (continuing)"
  fi

  log ""
  if [[ "${health_rc}" -eq 0 ]]; then
    log "RESULT: talosctl health reported the cluster HEALTHY"
    exit 0
  fi
  err "RESULT: talosctl health reported the cluster UNHEALTHY (exit ${health_rc})"
  err "inspect the sections above; for etcd quorum loss see talos/etcd-restore.sh"
  exit 1
}

# Only execute when run directly; sourcing (e.g. from bats) must not run main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
