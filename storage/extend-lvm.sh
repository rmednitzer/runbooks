#!/usr/bin/env bash
# extend-lvm.sh — extend an LVM logical volume and grow its filesystem.
#
# Why this exists
#   When a VM hits "no space left on device" and the underlying volume
#   group has free extents (or the hypervisor has grown the backing disk
#   and pvresize is required), the operator extends the LV in place and
#   grows the filesystem on top. This script automates the safe sequence:
#   optional pvresize → lvextend WITH the filesystem grown in the SAME
#   operation. It refuses to operate on anything it does not recognise.
#
# Atomicity (H3)
#   The LV grow and the filesystem grow happen in ONE command:
#   `lvextend --resizefs ...`. lvextend drives fsadm, which detects the
#   filesystem type and runs resize2fs/xfs_growfs itself. Doing it in two
#   separate steps (the old behaviour) left a window where a crash
#   between them produced a larger LV with an un-grown filesystem — the
#   operator then had to know to run resize2fs/xfs_growfs by hand. We
#   still pre-check the FS type to fail fast on anything fsadm cannot
#   grow, and on failure we print an explicit recovery note.
#
# NOT idempotent with +SIZE (H3.2)
#   `SIZE=+10G` is ADDITIVE: each run adds another 10G. Re-running this
#   script with a `+SIZE` is NOT a no-op — it extends again. An absolute
#   SIZE (e.g. `100G`) errors on the second run instead ("New size ...
#   not larger"). Prefer an absolute target size, or check `lvs` first.
#   See usage() and the SIZE notes below.
#
# Plain LVs only (H4)
#   `-L` size semantics differ for thin pools, thin volumes, cache
#   (cache/writecache) LVs, and snapshots, where a naive extend can
#   exhaust pool metadata or behave surprisingly. This script inspects
#   `lv_attr` and refuses anything that is not a plain linear/striped LV.
#
# Requirements (bash >= 4; see CLAUDE.md)
#   - LVM2 userland: lvs, vgs, pvs, lvextend (+ pvresize when PV_RESIZE=1)
#   - fsadm + resize2fs (ext2/3/4) or xfs_growfs (xfs) for --resizefs
#   - blkid, findmnt
#   - Must run as root.
#
# Environment variables
#   VG          Volume group name (required).
#   LV          Logical volume name (required).
#   SIZE        lvextend size argument, e.g. +10G, +100%FREE, or an
#               absolute 100G (required). NOTE: a leading '+' is additive
#               and re-running repeats the extension — see above.
#   PV_RESIZE   If 1, run pvresize on every PV in the VG before extending
#               (use after the hypervisor grew an underlying disk).
#   DRY_RUN     If 1, print actions without executing them.
#
# Exit codes
#   0  success; LV and filesystem grown
#   1  runtime error (missing dep, lvextend/fs-grow failed, non-plain LV, …)
#   2  invalid argument (missing required env var, unsupported FS, …)

set -euo pipefail

log() { printf '[extend-lvm] %s\n' "$*"; }
warn() { printf '[extend-lvm] WARN: %s\n' "$*" >&2; }
err() { printf '[extend-lvm] ERR: %s\n' "$*" >&2; }

# Uniform failure reporting. No temp files in this script. (The
# resize-specific recovery hint is printed inline at the call site so it
# can name resize2fs/xfs_growfs and the mountpoint precisely.)
trap 'err "failed at line ${LINENO}"; exit 1' ERR

usage() {
  cat << 'EOF'
Usage: VG=<vg> LV=<lv> SIZE=<size> [PV_RESIZE=1] [DRY_RUN=1] extend-lvm.sh

Extend an LVM logical volume and grow its filesystem in one atomic
lvextend --resizefs operation. Plain linear/striped LVs only.

Environment variables:
  VG          Volume group name (required).
  LV          Logical volume name (required).
  SIZE        lvextend size argument (required). A leading '+' (e.g.
              +10G, +100%FREE) is ADDITIVE — re-running this script
              extends AGAIN, it is not idempotent. An absolute size
              (e.g. 100G) errors on re-run instead. Prefer absolute, or
              check `lvs` first.
  PV_RESIZE   If 1, run pvresize on every PV in the VG first.
  DRY_RUN     If 1, print actions without executing.

Thin pools/volumes, cache LVs, and snapshots are refused (their -L
semantics differ and can exhaust pool metadata); handle those manually.

Examples:
  VG=ubuntu-vg LV=ubuntu-lv SIZE=+10G ./extend-lvm.sh   # additive!
  VG=data      LV=postgres  SIZE=+100%FREE DRY_RUN=1 ./extend-lvm.sh
  VG=ubuntu-vg LV=ubuntu-lv SIZE=200G PV_RESIZE=1 ./extend-lvm.sh
EOF
}

run() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "DRY_RUN: $*"
  else
    log "+ $*"
    "$@"
  fi
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

fs_type_of() {
  local lv_path="$1"
  blkid -o value -s TYPE -- "${lv_path}" 2> /dev/null || true
}

mountpoint_of() {
  local lv_path="$1"
  findmnt -no TARGET --source "${lv_path}" 2> /dev/null || true
}

lv_attr_of() {
  local lv_path="$1"
  # lv_attr is a fixed-width flag string; character 1 is the volume type.
  lvs --noheadings -o lv_attr -- "${lv_path}" 2> /dev/null |
    tr -d '[:space:]' || true
}

# Refuse anything that is not a plain linear/striped LV (H4). The first
# lv_attr character encodes the volume type:
#   -  linear/striped (allowed)
#   t  thin pool       C  cache pool   c  (under-)cache
#   V  thin volume     s/S snapshot/merging snapshot   m/M (raid) metadata
#   o  origin with snapshots   p,r,R,... other special types
# Only '-' is the plain case we know `lvextend -L --resizefs` handles
# safely; everything else needs manual, type-aware handling.
ensure_plain_lv() {
  local lv_path="$1" attr type_char
  attr="$(lv_attr_of "${lv_path}")"
  if [[ -z "${attr}" ]]; then
    err "could not read lv_attr for ${lv_path}"
    exit 1
  fi
  type_char="${attr:0:1}"
  if [[ "${type_char}" != "-" ]]; then
    err "refusing: ${lv_path} is not a plain linear/striped LV (lv_attr='${attr}', type='${type_char}')"
    err "plain LVs only; thin pools/volumes, caches, and snapshots need manual handling"
    exit 1
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

  if [[ -z "${VG:-}" ]]; then
    err "VG is required (use --help for usage)"
    exit 2
  fi
  if [[ -z "${LV:-}" ]]; then
    err "LV is required (use --help for usage)"
    exit 2
  fi
  if [[ -z "${SIZE:-}" ]]; then
    err "SIZE is required (use --help for usage)"
    exit 2
  fi

  if [[ "${EUID}" -ne 0 ]]; then
    err "must run as root"
    exit 1
  fi

  # fsadm is what lvextend --resizefs shells out to; require it up front.
  require_cmd lvs lvextend vgs pvs blkid findmnt fsadm

  local lv_path="/dev/${VG}/${LV}"
  # set -e intentionally disabled for this existence test.
  # shellcheck disable=SC2310
  if ! lvs --noheadings -- "${lv_path}" > /dev/null 2>&1; then
    err "logical volume not found: ${lv_path}"
    exit 1
  fi

  # H4: bail out on thin/cache/snapshot volumes before touching anything.
  ensure_plain_lv "${lv_path}"

  # Pre-check the FS type to fail fast on anything fsadm cannot grow.
  # lvextend --resizefs (via fsadm) actually performs the grow.
  local fs_type
  fs_type="$(fs_type_of "${lv_path}")"
  case "${fs_type}" in
    ext2 | ext3 | ext4)
      require_cmd resize2fs
      ;;
    xfs)
      require_cmd xfs_growfs
      ;;
    "")
      err "could not determine filesystem on ${lv_path}"
      exit 1
      ;;
    *)
      err "unsupported filesystem type: ${fs_type} (fsadm cannot grow it here)"
      exit 2
      ;;
  esac

  local mp
  mp="$(mountpoint_of "${lv_path}")"

  # xfs can only be grown while mounted; fail fast BEFORE extending the LV
  # so we never leave a larger LV with an un-grown xfs.
  if [[ "${fs_type}" == "xfs" && -z "${mp}" ]]; then
    err "xfs grows only while mounted; ${lv_path} is not mounted — mount it first"
    exit 1
  fi

  log "LV         : ${lv_path}"
  log "filesystem : ${fs_type}"
  log "mountpoint : ${mp:-<not mounted>}"
  log "--- before ---"
  lvs --units g -- "${lv_path}"
  vgs --units g -- "${VG}"
  if [[ -n "${mp}" ]]; then
    df -h -- "${mp}"
  fi

  if [[ "${PV_RESIZE:-0}" == "1" ]]; then
    require_cmd pvresize
    local pv pvs_out
    local -a pv_list
    pvs_out="$(pvs --noheadings -o pv_name --select "vg_name=${VG}")"
    mapfile -t pv_list <<< "${pvs_out}"
    for pv in "${pv_list[@]}"; do
      pv="${pv#"${pv%%[![:space:]]*}"}"
      [[ -z "${pv}" ]] && continue
      run pvresize -- "${pv}"
    done
  fi

  # H3: ONE atomic operation — lvextend grows the LV and, via --resizefs
  # (fsadm), grows the filesystem in the same step. No window where the
  # LV is larger than its filesystem. If this fails, the LV may or may
  # not have grown; print a precise manual-recovery hint either way.
  # `run` honours DRY_RUN. The ERR trap would normally fire on failure,
  # so we guard the call to print the recovery note first.
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    run lvextend --resizefs -L "${SIZE}" -- "${lv_path}"
  else
    log "+ lvextend --resizefs -L ${SIZE} -- ${lv_path}"
    if ! lvextend --resizefs -L "${SIZE}" -- "${lv_path}"; then
      err "lvextend --resizefs failed"
      if [[ "${fs_type}" == "xfs" ]]; then
        err "RECOVERY: if the LV grew but the FS did not, run: xfs_growfs ${mp}"
      else
        err "RECOVERY: if the LV grew but the FS did not, run: resize2fs ${lv_path}"
      fi
      exit 1
    fi
  fi

  log "--- after ---"
  lvs --units g -- "${lv_path}"
  vgs --units g -- "${VG}"
  if [[ -n "${mp}" ]]; then
    df -h -- "${mp}"
  fi
}

# Only execute when run directly; sourcing (e.g. from bats) must not run main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
