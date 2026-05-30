#!/usr/bin/env bash
# kubeconfig-rotate.sh — (re)fetch the admin kubeconfig from a Talos cluster.
#
# Why this exists
#   On Talos the Kubernetes admin kubeconfig is issued BY the cluster: you
#   ask a control-plane node for it with `talosctl kubeconfig`. There is no
#   SSH and no static admin file to scp off the box — the credential is
#   minted over the Talos API (mTLS). You need this when:
#     - bootstrapping a workstation that has never talked to the cluster,
#     - the admin client cert in your kubeconfig has expired or is about to
#       (Talos admin kubeconfig certs are short-lived by design),
#     - the cluster CA was rotated and your cached kubeconfig is now stale.
#   This script wraps `talosctl kubeconfig` with a clear target path, a
#   timestamped backup of any kubeconfig it is about to overwrite, and
#   DRY_RUN so you can preview the exact call.
#
# Merge vs replace (MERGE)
#   `talosctl kubeconfig <path>`:
#     - If <path> is a DIRECTORY, talosctl writes <path>/kubeconfig.
#     - If <path> is a FILE that exists, talosctl MERGES the new cluster/
#       context/credentials into it by default (so your other clusters
#       survive), and --force overwrites instead.
#   This script targets a FILE (KUBECONFIG_OUT). MERGE=1 (the default here)
#   merges into it; MERGE=0 passes --force to replace the file wholesale.
#   Either way we keep a timestamped .bak of the prior file first.
#
# This is low-risk but still rotates a credential
#   It does not change the cluster; it only writes a kubeconfig on THIS
#   host. But it DOES replace/merge a credential file, so we back up the
#   previous one and support DRY_RUN. Re-running is safe (idempotent enough
#   — you just refetch a fresh credential).
#
# Requirements (bash >= 4 on GNU/Linux; see CLAUDE.md)
#   - talosctl on PATH, valid talosconfig (default or TALOSCONFIG).
#   - coreutils: cp, date, dirname.
#   Targets bash >= 4 + GNU coreutils (CLAUDE.md platform note).
#
# Environment variables
#   TALOSCONFIG     Path to talosconfig (talosctl --talosconfig).
#   NODES           Control-plane node to ask (talosctl --nodes). Optional;
#                   defaults to the talosconfig context.
#   ENDPOINTS       Endpoint addresses (talosctl --endpoints). Optional.
#   CONTEXT         talosconfig context name. Optional.
#   KUBECONFIG_OUT  Destination kubeconfig FILE (default ./kubeconfig).
#   MERGE           If 1 (default), merge into an existing KUBECONFIG_OUT;
#                   if 0, pass --force to replace it wholesale.
#   DRY_RUN         If 1, print the planned command and exit.
#
# Exit codes
#   0  kubeconfig written (or DRY_RUN completed)
#   1  runtime error (talosctl failed, output not written, …)
#   2  invalid argument

set -euo pipefail

log() { printf '[kubeconfig-rotate] %s\n' "$*"; }
warn() { printf '[kubeconfig-rotate] WARN: %s\n' "$*" >&2; }
err() { printf '[kubeconfig-rotate] ERR: %s\n' "$*" >&2; }

# Uniform failure reporting. No temp files created by this script.
trap 'err "failed at line ${LINENO}"; exit 1' ERR

usage() {
  cat << 'EOF'
Usage: [TALOSCONFIG=...] [NODES=...] [ENDPOINTS=...] [CONTEXT=...] \
       [KUBECONFIG_OUT=./kubeconfig] [MERGE=1] [DRY_RUN=1] \
       kubeconfig-rotate.sh

(Re)fetch the Kubernetes admin kubeconfig from a Talos cluster via
`talosctl kubeconfig`. Talos mints the admin credential over its API —
there is no SSH/static admin file. Backs up any file it overwrites.

Environment variables:
  TALOSCONFIG     Path to talosconfig (talosctl --talosconfig).
  NODES           Control-plane node to ask (talosctl --nodes). Optional.
  ENDPOINTS       Endpoint addresses (talosctl --endpoints). Optional.
  CONTEXT         talosconfig context name. Optional.
  KUBECONFIG_OUT  Destination kubeconfig FILE (default ./kubeconfig).
  MERGE           1 (default) merges into an existing file; 0 uses --force
                  to replace it wholesale.
  DRY_RUN         If 1, print the planned command and exit.

Examples:
  TALOSCONFIG=./talosconfig KUBECONFIG_OUT=~/.kube/config ./kubeconfig-rotate.sh
  NODES=10.0.0.2 MERGE=0 ./kubeconfig-rotate.sh        # replace, not merge
  DRY_RUN=1 ./kubeconfig-rotate.sh
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

# Common talosctl targeting flags.
TALOS_FLAGS=()
build_talos_flags() {
  TALOS_FLAGS=()
  [[ -n "${TALOSCONFIG:-}" ]] && TALOS_FLAGS+=(--talosconfig "${TALOSCONFIG}")
  [[ -n "${CONTEXT:-}" ]] && TALOS_FLAGS+=(--context "${CONTEXT}")
  [[ -n "${ENDPOINTS:-}" ]] && TALOS_FLAGS+=(--endpoints "${ENDPOINTS}")
  [[ -n "${NODES:-}" ]] && TALOS_FLAGS+=(--nodes "${NODES}")
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

  require_cmd talosctl cp date dirname
  build_talos_flags

  local out="${KUBECONFIG_OUT:-./kubeconfig}"
  local merge="${MERGE:-1}"
  if [[ "${merge}" != "0" && "${merge}" != "1" ]]; then
    err "MERGE must be 0 or 1 (got: ${merge})"
    exit 2
  fi

  # Build the talosctl kubeconfig args. We always pass an explicit FILE
  # path. --force replaces; default merges into an existing file.
  local -a kc_args=(kubeconfig "${out}")
  if [[ "${merge}" == "0" ]]; then
    # --force overwrites the file; --merge=false replaces (rather than merges)
    # so stale contexts/users from the old kubeconfig do not survive.
    kc_args+=(--force --merge=false)
  fi

  local mode_label="force-replace"
  [[ "${merge}" == "1" ]] && mode_label="merge into existing"

  log "output     : ${out}"
  log "mode       : ${mode_label}"
  log "command    : talosctl ${TALOS_FLAGS[*]} ${kc_args[*]}"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "DRY_RUN: the command above would run. Nothing written."
    exit 0
  fi

  # Back up any existing kubeconfig before talosctl touches it, so a bad
  # merge or a wrong --context is recoverable.
  if [[ -f "${out}" ]]; then
    local ts backup
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    backup="${out}.bak.${ts}"
    log "backing up : ${out} -> ${backup}"
    cp -p -- "${out}" "${backup}"
  else
    # Ensure the parent directory exists for a first-time fetch.
    local dir
    dir="$(dirname -- "${out}")"
    if [[ ! -d "${dir}" ]]; then
      log "creating parent directory: ${dir}"
      mkdir -p -- "${dir}"
    fi
  fi

  log "+ talosctl ${kc_args[*]}"
  # shellcheck disable=SC2310
  if ! talosctl "${TALOS_FLAGS[@]}" "${kc_args[@]}"; then
    err "talosctl kubeconfig failed"
    err "is the target a reachable control-plane node? (talos/talos-health-check.sh)"
    exit 1
  fi

  if [[ ! -f "${out}" ]]; then
    err "talosctl reported success but ${out} was not written"
    exit 1
  fi

  log ""
  log "kubeconfig written: ${out}"
  log "test it: KUBECONFIG=${out} kubectl get nodes"
}

# Only execute when run directly; sourcing (e.g. from bats) must not run main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
