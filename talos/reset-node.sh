#!/usr/bin/env bash
# reset-node.sh — wipe a Talos node back to maintenance mode.
#
# ############################################################################
# ##  EXTREME DANGER — THIS WIPES THE NODE.                                  ##
# ##  `talosctl reset` erases the selected disk partitions and reboots the   ##
# ##  node into maintenance mode. With wipe-mode "all" the ENTIRE system     ##
# ##  disk is wiped — the node leaves the cluster and must be re-installed   ##
# ##  and re-joined. On a control-plane node this REMOVES an etcd member and ##
# ##  can DESTROY QUORUM. There is no undo. Do not run during an incident    ##
# ##  unless you have decided this node is being rebuilt.                     ##
# ############################################################################
#
# Why this exists
#   Talos has no SSH and no host shell, so you cannot log in and re-image a
#   node by hand. The supported way to return a node to a clean state is
#   `talosctl reset`, which wipes the chosen partitions and drops the node
#   back to maintenance mode (ready for a fresh machine config / re-join).
#   You need it to:
#     - decommission or rebuild a node,
#     - wipe a wedged control-plane node's EPHEMERAL partition before an
#       etcd recover (talos/etcd-restore.sh) so its stale etcd data is gone,
#     - recover a node stuck in a bad config.
#   This script wraps that one irreversible call behind a DRY_RUN-first
#   workflow and a DOUBLE confirmation (typed token + an explicit second
#   y/N naming the exact node and wipe scope).
#
# Wipe scope (WIPE_MODE / SYSTEM_LABELS)
#   `--wipe-mode` selects WHAT is wiped (talosctl values: auto, all, state,
#   ephemeral; default auto):
#     - ephemeral : wipe only EPHEMERAL (pod data, images, etcd data dir).
#                   The node keeps its install + machine config. This is the
#                   right scope for the "wipe etcd before recover" case.
#     - all       : wipe the whole system disk. The node leaves the cluster
#                   entirely and must be re-installed. DECOMMISSION scope.
#     - state     : wipe STATE (machine config / secrets).
#     - auto      : Talos decides based on context.
#   Alternatively, `--system-labels-to-wipe` names exact partitions to wipe
#   (e.g. EPHEMERAL). If SYSTEM_LABELS is set it is used INSTEAD of
#   WIPE_MODE. The classic recover-prep is:
#     SYSTEM_LABELS=EPHEMERAL GRACEFUL=0 reset-node.sh
#
# Graceful (GRACEFUL)
#   --graceful (default true in talosctl) drains the node and leaves etcd
#   cleanly before wiping — correct for a planned decommission of a HEALTHY
#   node. For a node whose etcd is ALREADY broken (the recover-prep case) a
#   graceful reset can hang trying to leave a dead etcd, so set GRACEFUL=0
#   to reset non-gracefully. The script makes you choose explicitly.
#
# Requirements (bash >= 4 on GNU/Linux; see CLAUDE.md)
#   - talosctl on PATH, valid talosconfig (default or TALOSCONFIG).
#   Targets bash >= 4 + GNU coreutils (CLAUDE.md platform note).
#
# Environment variables
#   NODES          The SINGLE node to reset (talosctl --nodes; required).
#   TALOSCONFIG    Path to talosconfig (talosctl --talosconfig).
#   ENDPOINTS      Endpoint addresses (talosctl --endpoints). Optional.
#   CONTEXT        talosconfig context name. Optional.
#   WIPE_MODE      --wipe-mode value: auto|all|state|ephemeral (default
#                  ephemeral here — the safer scope; choose 'all' to fully
#                  decommission). Ignored if SYSTEM_LABELS is set.
#   SYSTEM_LABELS  Comma-separated partition labels for
#                  --system-labels-to-wipe (e.g. EPHEMERAL). Overrides
#                  WIPE_MODE when set.
#   GRACEFUL       1 (default) drains + leaves etcd cleanly; 0 resets
#                  non-gracefully (for an already-broken node).
#   REBOOT         1 (default) reboot after reset; 0 to leave it powered
#                  off-ish per talosctl semantics.
#   FORCE          If 1, skip BOTH confirmations (automation that has gated
#                  this elsewhere; extreme care).
#   DRY_RUN        If 1, print the exact reset command and exit. RUN FIRST.
#
# Exit codes
#   0  reset accepted (or DRY_RUN / operator-abort completed cleanly)
#   1  runtime error (talosctl reset failed, …)
#   2  invalid argument (NODES unset, multiple nodes, bad WIPE_MODE, …)

set -euo pipefail

log() { printf '[reset-node] %s\n' "$*"; }
warn() { printf '[reset-node] WARN: %s\n' "$*" >&2; }
err() { printf '[reset-node] ERR: %s\n' "$*" >&2; }

# Uniform failure reporting. No temp files created by this script.
trap 'err "failed at line ${LINENO}"; exit 1' ERR

usage() {
  cat << 'EOF'
Usage: NODES=<node> [TALOSCONFIG=...] [ENDPOINTS=...] [CONTEXT=...] \
       [WIPE_MODE=ephemeral] [SYSTEM_LABELS=EPHEMERAL] [GRACEFUL=1] \
       [REBOOT=1] [FORCE=1] [DRY_RUN=1] reset-node.sh

!! EXTREME DANGER: `talosctl reset` WIPES the node back to maintenance
!! mode. wipe-mode 'all' wipes the whole system disk (node must be
!! re-installed). On a control-plane node this removes an etcd member and
!! can DESTROY QUORUM. No undo.

Talos has no SSH; re-imaging is done through the talosctl API. Resets ONE
node. DRY_RUN first; then a typed token AND a second y/N confirmation.

Environment variables:
  NODES          The SINGLE node to reset (required; one node only).
  TALOSCONFIG    Path to talosconfig (talosctl --talosconfig).
  ENDPOINTS      Endpoint addresses (talosctl --endpoints). Optional.
  CONTEXT        talosconfig context name. Optional.
  WIPE_MODE      auto|all|state|ephemeral (default ephemeral — safer
                 scope; use 'all' to decommission). Ignored if
                 SYSTEM_LABELS is set.
  SYSTEM_LABELS  Partition labels for --system-labels-to-wipe (e.g.
                 EPHEMERAL). Overrides WIPE_MODE when set.
  GRACEFUL       1 (default) drains + leaves etcd cleanly; 0 for an
                 already-broken node (avoids hanging on dead etcd).
  REBOOT         1 (default) reboot after reset; 0 otherwise.
  FORCE          If 1, skip BOTH confirmations. Extreme care.
  DRY_RUN        If 1, print the reset command and exit. RUN THIS FIRST.

Common uses:
  # Decommission / rebuild a node (full wipe):
  NODES=10.0.0.9 WIPE_MODE=all DRY_RUN=1 ./reset-node.sh
  # Wipe a wedged control-plane node's etcd before an etcd recover:
  NODES=10.0.0.2 SYSTEM_LABELS=EPHEMERAL GRACEFUL=0 DRY_RUN=1 ./reset-node.sh
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

# First gate: a typed token (literal string) — too deliberate to fat-finger.
confirm_typed() {
  local want="$1" ans
  printf 'Type %s to proceed (anything else aborts): ' "${want}" >&2
  if ! read -r ans < /dev/tty; then
    err "no controlling tty; set FORCE=1 only if you have gated this elsewhere"
    exit 1
  fi
  [[ "${ans}" == "${want}" ]]
}

# Second gate: an explicit y/N that re-states the exact node + scope, so
# the operator confirms against the real target, not a remembered one.
confirm_yn() {
  local prompt="$1" ans
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

  if [[ -z "${NODES:-}" ]]; then
    err "NODES is required: the SINGLE node to reset"
    exit 2
  fi
  if [[ "${NODES}" == *,* ]]; then
    err "NODES must be a SINGLE node — reset one node at a time (got: ${NODES})"
    exit 2
  fi

  local graceful="${GRACEFUL:-1}"
  local reboot="${REBOOT:-1}"
  if [[ "${graceful}" != "0" && "${graceful}" != "1" ]]; then
    err "GRACEFUL must be 0 or 1 (got: ${graceful})"
    exit 2
  fi
  if [[ "${reboot}" != "0" && "${reboot}" != "1" ]]; then
    err "REBOOT must be 0 or 1 (got: ${reboot})"
    exit 2
  fi

  require_cmd talosctl
  build_talos_flags

  # Assemble reset args. talosctl takes --graceful / --reboot as
  # explicit booleans (=true/=false) so the chosen value is unambiguous.
  local -a reset_args=(reset)
  reset_args+=("--graceful=$([[ "${graceful}" == "1" ]] && echo true || echo false)")
  reset_args+=("--reboot=$([[ "${reboot}" == "1" ]] && echo true || echo false)")

  # Scope: SYSTEM_LABELS (exact partitions) overrides WIPE_MODE.
  local scope_desc
  if [[ -n "${SYSTEM_LABELS:-}" ]]; then
    reset_args+=(--system-labels-to-wipe "${SYSTEM_LABELS}")
    scope_desc="partitions [${SYSTEM_LABELS}]"
  else
    local wipe_mode="${WIPE_MODE:-ephemeral}"
    case "${wipe_mode}" in
      auto | all | state | ephemeral) ;;
      *)
        err "WIPE_MODE must be one of auto|all|state|ephemeral (got: ${wipe_mode})"
        exit 2
        ;;
    esac
    reset_args+=(--wipe-mode "${wipe_mode}")
    scope_desc="wipe-mode ${wipe_mode}"
  fi

  log "node       : ${NODES}  (resetting ONE node)"
  log "scope      : ${scope_desc}"
  log "graceful   : ${graceful}"
  log "reboot     : ${reboot}"
  log "command    : talosctl ${TALOS_FLAGS[*]} ${reset_args[*]}"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "DRY_RUN: the command above would run. Nothing was sent to the cluster."
    log "DRY_RUN: re-run without DRY_RUN to actually reset (two confirmations)."
    exit 0
  fi

  warn ""
  warn "############################################################"
  warn "#  ABOUT TO RESET (WIPE) NODE ${NODES}"
  warn "#  scope: ${scope_desc}"
  warn "#  This is IRREVERSIBLE. On a control-plane node it removes an"
  warn "#  etcd member and can DESTROY QUORUM."
  warn "############################################################"

  if [[ "${FORCE:-0}" != "1" ]]; then
    # Gate 1: typed token.
    # set -e intentionally disabled for this branch test.
    # shellcheck disable=SC2310
    if ! confirm_typed "WIPE"; then
      log "aborted by operator at confirmation 1 (no changes made)"
      exit 0
    fi
    # Gate 2: explicit y/N naming the exact node + scope.
    # shellcheck disable=SC2310
    if ! confirm_yn "Reset node ${NODES} (${scope_desc}) — are you absolutely sure?"; then
      log "aborted by operator at confirmation 2 (no changes made)"
      exit 0
    fi
  else
    warn "FORCE=1: skipping BOTH confirmations"
  fi

  log "+ talosctl ${reset_args[*]}"
  # shellcheck disable=SC2310
  if ! talosctl "${TALOS_FLAGS[@]}" "${reset_args[@]}"; then
    err "talosctl reset failed"
    err "if a graceful reset hung on a dead etcd, retry with GRACEFUL=0"
    exit 1
  fi

  log ""
  log "reset command accepted for ${NODES}. The node is wiping + rebooting"
  log "into maintenance mode. Re-apply a machine config to re-join, or (for"
  log "an etcd recover) proceed with talos/etcd-restore.sh."
}

# Only execute when run directly; sourcing (e.g. from bats) must not run main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
