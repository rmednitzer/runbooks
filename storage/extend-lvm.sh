#!/usr/bin/env bash
# extend-lvm.sh — extend an LVM logical volume and grow its filesystem.
#
# Why this exists
#   When a VM hits "no space left on device" and the underlying volume
#   group has free extents (or the hypervisor has grown the backing disk
#   and pvresize is required), the operator extends the LV in place and
#   grows the filesystem on top. This script automates the safe sequence:
#   optional pvresize → lvextend → fs-grow, picking resize2fs or
#   xfs_growfs from the live filesystem type. It refuses to operate on
#   anything it does not recognise.
#
# Requirements
#   - LVM2 userland: lvs, vgs, pvs, lvextend, pvresize
#   - resize2fs (ext2/3/4) or xfs_growfs (xfs)
#   - blkid, findmnt
#   - Must run as root.
#
# Environment variables
#   VG          Volume group name (required).
#   LV          Logical volume name (required).
#   SIZE        lvextend size argument, e.g. +10G, +100%FREE (required).
#   PV_RESIZE   If 1, run pvresize on every PV in the VG before extending
#               (use after the hypervisor grew an underlying disk).
#   DRY_RUN     If 1, print actions without executing them.
#
# Exit codes
#   0  success; LV and filesystem grown
#   1  runtime error (missing dep, lvextend or fs-grow failed, …)
#   2  invalid argument (missing required env var, unsupported FS, …)

set -euo pipefail

log() { printf '[extend-lvm] %s\n' "$*"; }
warn() { printf '[extend-lvm] WARN: %s\n' "$*" >&2; }
err() { printf '[extend-lvm] ERR: %s\n' "$*" >&2; }

usage() {
  cat << 'EOF'
Usage: VG=<vg> LV=<lv> SIZE=<size> [PV_RESIZE=1] [DRY_RUN=1] extend-lvm.sh

Extend an LVM logical volume and grow its filesystem in place.

Environment variables:
  VG          Volume group name (required).
  LV          Logical volume name (required).
  SIZE        lvextend size argument, e.g. +10G, +100%FREE (required).
  PV_RESIZE   If 1, run pvresize on every PV in the VG first.
  DRY_RUN     If 1, print actions without executing.

Examples:
  VG=ubuntu-vg LV=ubuntu-lv SIZE=+10G ./extend-lvm.sh
  VG=data      LV=postgres  SIZE=+100%FREE DRY_RUN=1 ./extend-lvm.sh
  VG=ubuntu-vg LV=ubuntu-lv SIZE=+50G PV_RESIZE=1 ./extend-lvm.sh
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

main() {
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
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

  require_cmd lvs lvextend vgs pvs blkid findmnt

  local lv_path="/dev/${VG}/${LV}"
  if ! lvs --noheadings -- "${lv_path}" > /dev/null 2>&1; then
    err "logical volume not found: ${lv_path}"
    exit 1
  fi

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
      err "unsupported filesystem type: ${fs_type}"
      exit 2
      ;;
  esac

  local mp
  mp="$(mountpoint_of "${lv_path}")"

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
    local pv
    while IFS= read -r pv; do
      pv="${pv#"${pv%%[![:space:]]*}"}"
      [[ -z "${pv}" ]] && continue
      run pvresize -- "${pv}"
    done < <(pvs --noheadings -o pv_name --select "vg_name=${VG}")
  fi

  run lvextend -L "${SIZE}" -- "${lv_path}"

  case "${fs_type}" in
    ext2 | ext3 | ext4)
      run resize2fs "${lv_path}"
      ;;
    xfs)
      if [[ -z "${mp}" ]]; then
        err "xfs_growfs requires the filesystem to be mounted; ${lv_path} is not mounted"
        exit 1
      fi
      run xfs_growfs "${mp}"
      ;;
  esac

  log "--- after ---"
  lvs --units g -- "${lv_path}"
  vgs --units g -- "${VG}"
  if [[ -n "${mp}" ]]; then
    df -h -- "${mp}"
  fi
}

main "$@"
