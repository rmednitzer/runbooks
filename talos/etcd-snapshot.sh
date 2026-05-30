#!/usr/bin/env bash
# etcd-snapshot.sh — take a consistent Talos etcd snapshot to a timestamped file.
#
# Why this exists
#   etcd holds the ENTIRE Kubernetes cluster state. On Talos there is no
#   SSH and no host shell — you cannot log in and `etcdctl snapshot save`.
#   The supported, consistent backup path is `talosctl etcd snapshot
#   <path>`, which streams a point-in-time snapshot of etcd out of a
#   control-plane node over the Talos API (mTLS). This script wraps that:
#   it writes the snapshot to a timestamped file under a backup directory,
#   verifies the file was actually written and is non-empty, records a
#   SHA-256 checksum next to it, and prints the exact restore command. Run
#   it on a schedule and before every risky change (upgrade, config edit).
#
# Why a snapshot, not `talosctl cp` of the data dir
#   `talosctl etcd snapshot` takes a CONSISTENT snapshot (it goes through
#   etcd's snapshot API). Copying the raw member data directory with
#   `talosctl cp` can capture a torn, mid-write state; restoring from THAT
#   requires the `--recover-skip-hash-check` flag and is not recommended.
#   Prefer this script. See talos/etcd-restore.sh for the restore side.
#
# This is a BACKUP — it is safe
#   Taking a snapshot is read-only against cluster state; it does not
#   modify etcd or any node. The only thing it writes is the snapshot file
#   (and its .sha256) on THIS machine. DRY_RUN is still supported so you
#   can see exactly what would run without contacting the cluster.
#
# Requirements (bash >= 4 on GNU/Linux; see CLAUDE.md)
#   - talosctl on PATH, with a valid talosconfig (default or TALOSCONFIG).
#   - A single control-plane node targeted via NODES (snapshot is taken
#     from ONE node; do not fan it out).
#   - coreutils: mktemp, date, stat; sha256sum for the checksum.
#   Targets bash >= 4 + GNU coreutils (CLAUDE.md platform note).
#
# Environment variables
#   TALOSCONFIG   Path to talosconfig (talosctl --talosconfig).
#   NODES         Control-plane node to snapshot (talosctl --nodes).
#                 REQUIRED here: a snapshot must come from exactly one
#                 control-plane member, not a fan-out.
#   ENDPOINTS     Endpoint addresses (talosctl --endpoints). Optional.
#   CONTEXT       talosconfig context name (talosctl --context). Optional.
#   BACKUP_DIR    Directory to write snapshots into (default
#                 ./talos-etcd-backups). Created if missing.
#   DRY_RUN       If 1, print the planned command without contacting the
#                 cluster or writing a snapshot.
#
# Exit codes
#   0  snapshot written and verified (or DRY_RUN completed)
#   1  runtime error (talosctl failed, empty/missing snapshot, …)
#   2  invalid argument (NODES unset, BACKUP_DIR not creatable, …)

set -euo pipefail

log() { printf '[etcd-snapshot] %s\n' "$*"; }
warn() { printf '[etcd-snapshot] WARN: %s\n' "$*" >&2; }
err() { printf '[etcd-snapshot] ERR: %s\n' "$*" >&2; }

# Uniform failure reporting. The snapshot file is the deliverable, so we
# do NOT delete it on a late failure; a partial file is reported instead.
trap 'err "failed at line ${LINENO}"; exit 1' ERR

usage() {
  cat << 'EOF'
Usage: NODES=<cp-node> [TALOSCONFIG=...] [ENDPOINTS=...] [CONTEXT=...] \
       [BACKUP_DIR=./talos-etcd-backups] [DRY_RUN=1] etcd-snapshot.sh

Take a consistent Talos etcd snapshot via `talosctl etcd snapshot` and
write it to a timestamped file with a SHA-256 checksum. Safe/read-only
against the cluster; the only writes are the local snapshot + checksum.

Talos has no SSH: the snapshot is streamed out over the talosctl API.
Take it from exactly ONE control-plane node (NODES), not a fan-out.

Environment variables:
  TALOSCONFIG   Path to talosconfig (talosctl --talosconfig).
  NODES         Control-plane node to snapshot (REQUIRED; one node).
  ENDPOINTS     Endpoint addresses (talosctl --endpoints). Optional.
  CONTEXT       talosconfig context name. Optional.
  BACKUP_DIR    Output directory (default ./talos-etcd-backups).
  DRY_RUN       If 1, print the planned command and exit.

Examples:
  NODES=10.0.0.2 TALOSCONFIG=./talosconfig ./etcd-snapshot.sh
  NODES=10.0.0.2 BACKUP_DIR=/var/backups/talos-etcd ./etcd-snapshot.sh
  NODES=10.0.0.2 DRY_RUN=1 ./etcd-snapshot.sh

Restore pointer: see talos/etcd-restore.sh (talosctl bootstrap
--recover-from=<snapshot>). Keep these snapshots off-cluster.
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

# Common talosctl targeting flags (see talos-health-check.sh for the model).
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

  # A snapshot must be taken from exactly one control-plane member; refuse
  # to guess. (talosctl would pick the context default, but for a backup
  # we want the operator to name the node explicitly.)
  if [[ -z "${NODES:-}" ]]; then
    err "NODES is required: name exactly one control-plane node to snapshot"
    exit 2
  fi
  if [[ "${NODES}" == *,* ]]; then
    err "NODES must be a SINGLE control-plane node for a snapshot (got: ${NODES})"
    exit 2
  fi

  require_cmd talosctl date stat sha256sum
  build_talos_flags

  local backup_dir="${BACKUP_DIR:-./talos-etcd-backups}"
  local ts snapshot
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  snapshot="${backup_dir}/etcd-${NODES//[:\/]/_}-${ts}.snapshot"

  log "node       : ${NODES}"
  log "backup dir : ${backup_dir}"
  log "snapshot   : ${snapshot}"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "DRY_RUN: mkdir -p ${backup_dir}"
    log "DRY_RUN: talosctl ${TALOS_FLAGS[*]} etcd snapshot ${snapshot}"
    log "DRY_RUN: write a basename sidecar ${snapshot}.sha256 next to the snapshot"
    log "DRY_RUN: no snapshot taken, nothing written"
    exit 0
  fi

  if ! mkdir -p -- "${backup_dir}"; then
    err "could not create backup directory: ${backup_dir}"
    exit 2
  fi

  # Take the snapshot. talosctl writes the file at the given path on THIS
  # host (the snapshot is streamed back over the API). A non-zero exit, an
  # absent file, or a zero-byte file all mean the backup failed.
  log "+ talosctl etcd snapshot ${snapshot}"
  # shellcheck disable=SC2310
  if ! talosctl "${TALOS_FLAGS[@]}" etcd snapshot "${snapshot}"; then
    err "talosctl etcd snapshot failed"
    err "is ${NODES} a control-plane node with a healthy etcd? (talos/talos-health-check.sh)"
    exit 1
  fi

  if [[ ! -f "${snapshot}" ]]; then
    err "talosctl reported success but no snapshot file at ${snapshot}"
    exit 1
  fi
  if [[ ! -s "${snapshot}" ]]; then
    err "snapshot file is empty: ${snapshot} (treating as failure)"
    exit 1
  fi

  # Record a checksum next to the snapshot so a later restore can verify
  # the file has not bit-rotted in transit/storage.
  # Record the checksum with the snapshot's BASENAME (not the full path) so
  # the sidecar is a standard, relocatable `sha256sum -c`-able file.
  (cd -- "${backup_dir}" &&
    sha256sum -- "$(basename -- "${snapshot}")" > "$(basename -- "${snapshot}").sha256")

  local size
  size="$(stat -c '%s' -- "${snapshot}")"
  log "verified   : ${snapshot} (${size} bytes)"
  log "checksum   : ${snapshot}.sha256"
  log ""
  log "RESTORE (only into a node ready for bootstrap — see talos/etcd-restore.sh):"
  log "  talosctl ${TALOS_FLAGS[*]} bootstrap --recover-from=${snapshot}"
  log ""
  log "Copy this snapshot OFF the cluster; a backup on the failed cluster is no backup."
}

# Only execute when run directly; sourcing (e.g. from bats) must not run main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
