#!/usr/bin/env bash
# etcd-restore.sh — guided Talos etcd restore from a snapshot.
#
# ############################################################################
# ##  DANGER — THIS REBUILDS CLUSTER STATE FROM A BACKUP.                    ##
# ##  Running `talosctl bootstrap --recover-from=` REPLACES the live etcd    ##
# ##  with the contents of a snapshot. Everything written to the cluster     ##
# ##  AFTER that snapshot was taken is LOST. Only do this when etcd quorum   ##
# ##  is genuinely, unrecoverably lost. If a majority of control-plane       ##
# ##  members are still healthy, DO NOT run this — fix etcd instead.         ##
# ############################################################################
#
# Why this exists
#   Talos has no SSH and no host shell, so there is no `etcdctl snapshot
#   restore` on the box. Disaster recovery from a permanent etcd quorum
#   loss is done with `talosctl bootstrap --recover-from=<snapshot>`: the
#   bootstrap call uploads the snapshot to a single control-plane node,
#   initialises etcd FROM that snapshot, and brings the Kubernetes API
#   back with the cluster state captured at snapshot time. This script is
#   the guided, guard-railed wrapper around that one irreversible call.
#
# The recovery workflow (what this script enforces / documents)
#   PRECONDITIONS you must satisfy BEFORE the recover (these cannot be
#   safely automated blind, so the script checks what it can and refuses
#   to run unless you ACK the rest):
#     1. etcd quorum is really lost. Confirm with talos/talos-health-check.sh
#        and `talosctl etcd members` — a single failed member of three is
#        NOT quorum loss; recover only when the cluster cannot form quorum.
#     2. The target node is READY FOR BOOTSTRAP — i.e. it has no running
#        etcd. If a control-plane node is up but etcd is wedged, first wipe
#        its etcd data by resetting EPHEMERAL:
#          talosctl -n <node> reset --graceful=false --reboot \
#            --system-labels-to-wipe=EPHEMERAL
#        (talos/reset-node.sh wraps that.) All control-plane etcd services
#        should be in the "Preparing" state before you bootstrap.
#     3. You are bootstrapping exactly ONE node. Never run bootstrap
#        against more than one node — that splits brain.
#   This script verifies the snapshot file + its checksum, requires
#   DRY_RUN-first discipline, and demands an explicit typed confirmation.
#
# Snapshot integrity
#   A snapshot taken by `talosctl etcd snapshot` carries an integrity
#   hash that bootstrap verifies. If (and only if) the snapshot was copied
#   raw from the etcd data dir with `talosctl cp`, the recover needs
#   --recover-skip-hash-check; set SKIP_HASH_CHECK=1 to add it. Do not set
#   it for snapshots produced by talos/etcd-snapshot.sh — leave the check on.
#
# Requirements (bash >= 4 on GNU/Linux; see CLAUDE.md)
#   - talosctl on PATH, valid talosconfig (default or TALOSCONFIG).
#   - The snapshot file readable on THIS host (SNAPSHOT).
#   - coreutils sha256sum (to verify the .sha256 sidecar when present).
#   Targets bash >= 4 + GNU coreutils (CLAUDE.md platform note).
#
# Environment variables
#   SNAPSHOT         Path to the snapshot file to restore from (required).
#   NODES            The SINGLE control-plane node to bootstrap (required).
#   TALOSCONFIG      Path to talosconfig (talosctl --talosconfig).
#   ENDPOINTS        Endpoint addresses (talosctl --endpoints). Optional.
#   CONTEXT          talosconfig context name. Optional.
#   SKIP_HASH_CHECK  If 1, add --recover-skip-hash-check (ONLY for raw
#                    `talosctl cp` copies, never for etcd-snapshot.sh files).
#   FORCE            If 1, skip the typed confirmation (for automation that
#                    has already gated this elsewhere; use with extreme care).
#   DRY_RUN          If 1, print the exact bootstrap command and exit
#                    WITHOUT touching the cluster. Run this first, always.
#
# Exit codes
#   0  restore completed (or DRY_RUN / operator-abort completed cleanly)
#   1  runtime error (talosctl failed, snapshot missing/corrupt, …)
#   2  invalid argument (SNAPSHOT/NODES unset, multiple nodes, …)

set -euo pipefail

log() { printf '[etcd-restore] %s\n' "$*"; }
warn() { printf '[etcd-restore] WARN: %s\n' "$*" >&2; }
err() { printf '[etcd-restore] ERR: %s\n' "$*" >&2; }

# Uniform failure reporting. No temp files created by this script.
trap 'err "failed at line ${LINENO}"; exit 1' ERR

usage() {
  cat << 'EOF'
Usage: SNAPSHOT=<file> NODES=<cp-node> [TALOSCONFIG=...] [ENDPOINTS=...] \
       [CONTEXT=...] [SKIP_HASH_CHECK=1] [FORCE=1] [DRY_RUN=1] etcd-restore.sh

!! DANGER: rebuilds cluster state from a snapshot via
!! `talosctl bootstrap --recover-from=`. Everything written AFTER the
!! snapshot is LOST. Only run on genuine, unrecoverable etcd quorum loss.

Talos has no SSH/etcdctl on the node; recovery is the talosctl API path.
Bootstrap exactly ONE control-plane node, which must have NO running etcd
(reset EPHEMERAL first if needed — see talos/reset-node.sh).

Environment variables:
  SNAPSHOT         Snapshot file to restore from (required).
  NODES            The ONE control-plane node to bootstrap (required).
  TALOSCONFIG      Path to talosconfig (talosctl --talosconfig).
  ENDPOINTS        Endpoint addresses (talosctl --endpoints). Optional.
  CONTEXT          talosconfig context name. Optional.
  SKIP_HASH_CHECK  If 1, add --recover-skip-hash-check (ONLY for raw
                   `talosctl cp` copies, never for etcd-snapshot.sh files).
  FORCE            If 1, skip the typed confirmation. Extreme care.
  DRY_RUN          If 1, print the command and exit. RUN THIS FIRST.

Recommended order:
  1. talos/talos-health-check.sh        # confirm quorum is truly lost
  2. talos/reset-node.sh                 # wipe EPHEMERAL on the target if
                                         #   etcd is wedged but node is up
  3. SNAPSHOT=... NODES=... DRY_RUN=1 ./etcd-restore.sh   # preview
  4. SNAPSHOT=... NODES=... ./etcd-restore.sh             # confirm + run

Example:
  SNAPSHOT=./talos-etcd-backups/etcd-...snapshot NODES=10.0.0.2 \
    TALOSCONFIG=./talosconfig DRY_RUN=1 ./etcd-restore.sh
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

# Typed confirmation: a plain y/N is too easy to fat-finger for an action
# this destructive, so we require the operator to type the literal word.
confirm_typed() {
  local want="$1" ans
  printf 'Type %s to proceed (anything else aborts): ' "${want}" >&2
  if ! read -r ans < /dev/tty; then
    err "no controlling tty; set FORCE=1 only if you have gated this elsewhere"
    exit 1
  fi
  [[ "${ans}" == "${want}" ]]
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

# Verify the snapshot against its .sha256 sidecar if etcd-snapshot.sh wrote
# one. A mismatch is fatal: restoring a corrupt snapshot is worse than not
# restoring. A missing sidecar is allowed (warn only) — operators may bring
# their own snapshot.
verify_snapshot_checksum() {
  local snap="$1"
  local sidecar="${snap}.sha256"
  if [[ ! -f "${sidecar}" ]]; then
    warn "no checksum sidecar (${sidecar}); cannot verify snapshot integrity"
    return 0
  fi
  log "verifying snapshot against ${sidecar}"
  # Compare the recorded hash to the file's hash directly. `sha256sum -c` of
  # the sidecar would fail when the sidecar records a path that does not
  # resolve from the current directory; the hash is all we need to confirm
  # the snapshot has not bit-rotted.
  local expected actual
  expected="$(awk 'NR == 1 { print $1 }' "${sidecar}")"
  # shellcheck disable=SC2312
  actual="$(sha256sum -- "${snap}" | awk '{ print $1 }')"
  if [[ -z "${expected}" || "${expected}" != "${actual}" ]]; then
    err "snapshot checksum FAILED — refusing to restore a corrupt snapshot"
    exit 1
  fi
  log "checksum OK"
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
    *) ;;
  esac

  if [[ -z "${SNAPSHOT:-}" ]]; then
    err "SNAPSHOT is required (path to the snapshot file)"
    exit 2
  fi
  if [[ -z "${NODES:-}" ]]; then
    err "NODES is required: the SINGLE control-plane node to bootstrap"
    exit 2
  fi
  # Reject a comma- OR whitespace-separated list: the guard's intent is exactly
  # one node, so a value like "10.0.0.2 10.0.0.3" must not slip past a
  # comma-only check (which would fan the bootstrap out and split brain).
  if [[ "${NODES}" =~ [[:space:],] ]]; then
    err "NODES must be a SINGLE node — bootstrapping >1 node splits brain (got: ${NODES}); pass one node, no comma- or space-separated list"
    exit 2
  fi

  require_cmd talosctl sha256sum
  build_talos_flags

  if [[ ! -f "${SNAPSHOT}" ]]; then
    err "snapshot file not found: ${SNAPSHOT}"
    exit 1
  fi
  if [[ ! -s "${SNAPSHOT}" ]]; then
    err "snapshot file is empty: ${SNAPSHOT}"
    exit 1
  fi

  # Build the recover command. --recover-from carries the snapshot path;
  # --recover-skip-hash-check is added ONLY when SKIP_HASH_CHECK=1.
  local -a bootstrap_args=(bootstrap "--recover-from=${SNAPSHOT}")
  if [[ "${SKIP_HASH_CHECK:-0}" == "1" ]]; then
    bootstrap_args+=(--recover-skip-hash-check)
    warn "SKIP_HASH_CHECK=1: snapshot integrity hash will NOT be verified by talosctl"
  fi

  log "node       : ${NODES}  (bootstrapping ONE control-plane node)"
  log "snapshot   : ${SNAPSHOT}"
  log "skip-hash  : ${SKIP_HASH_CHECK:-0}"
  log "command    : talosctl ${TALOS_FLAGS[*]} ${bootstrap_args[*]}"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "DRY_RUN: the command above would run. Nothing was sent to the cluster."
    log "DRY_RUN: re-run without DRY_RUN to actually restore (you will be asked to confirm)."
    exit 0
  fi

  # Verify integrity before we even prompt — no point confirming a restore
  # of a corrupt file.
  verify_snapshot_checksum "${SNAPSHOT}"

  # Loud, explicit, typed confirmation. This is irreversible.
  warn ""
  warn "############################################################"
  warn "#  ABOUT TO RECOVER etcd ON ${NODES}"
  warn "#  ALL cluster state written AFTER the snapshot is LOST."
  warn "#  Only proceed if etcd quorum is unrecoverable and the node"
  warn "#  has NO running etcd (Preparing state)."
  warn "############################################################"
  if [[ "${FORCE:-0}" != "1" ]]; then
    # set -e intentionally disabled for this branch test.
    # shellcheck disable=SC2310
    if ! confirm_typed "RECOVER"; then
      log "aborted by operator (no changes made)"
      exit 0
    fi
  else
    warn "FORCE=1: skipping typed confirmation"
  fi

  log "+ talosctl ${bootstrap_args[*]}"
  # shellcheck disable=SC2310
  if ! talosctl "${TALOS_FLAGS[@]}" "${bootstrap_args[@]}"; then
    err "talosctl bootstrap --recover-from failed"
    err "check: is the node ready for bootstrap (etcd Preparing, EPHEMERAL wiped)?"
    err "check: does the snapshot need --recover-skip-hash-check (raw talosctl cp copy)?"
    exit 1
  fi

  log ""
  log "recover command accepted. etcd is initialising from the snapshot."
  log "watch recovery with: talos/talos-health-check.sh"
  log "once this node is healthy, re-join the OTHER control-plane nodes"
  log "(reset them with talos/reset-node.sh so they rejoin a fresh etcd)."
}

# Only execute when run directly; sourcing (e.g. from bats) must not run main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
