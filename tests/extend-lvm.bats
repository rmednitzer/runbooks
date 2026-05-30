#!/usr/bin/env bats
# Tests for storage/extend-lvm.sh
#
# Focus: usage/exit-code contract; the H4 guard that refuses thin/cache/
# snapshot volumes; and the H3 atomic path — a DRY_RUN run must print a
# single `lvextend --resizefs` and must NEVER invoke the real lvextend or
# a separate resize2fs/xfs_growfs step. Fake LVM binaries on PATH stand in
# for the real tools (the suite runs as root in CI, so the EUID gate is
# satisfied; where it is not, the env-validation tests still run).

load helpers/common

SCRIPT="storage/extend-lvm.sh"

# Install a full set of fake LVM/FS tools describing a plain, mounted ext4
# LV. lv_attr returns a plain-linear attr unless LVS_ATTR overrides it.
install_fakes() {
  make_fake_bin lvs '
case "$*" in
  *lv_attr*) echo "  ${LVS_ATTR:--wi-ao----}" ;;
  *--units*) echo "  LV VG -wi-ao---- 10.00g" ;;
  *)         echo "  present" ;;
esac'
  make_fake_bin vgs 'echo "  VG 1 1 0 wz--n- 50.00g 40.00g"'
  make_fake_bin pvs 'echo "  /dev/sda1"'
  make_fake_bin blkid 'echo "${FAKE_FSTYPE:-ext4}"'
  # When FAKE_UNMOUNTED=1, emit nothing (simulating an unmounted FS).
  make_fake_bin findmnt '[[ "${FAKE_UNMOUNTED:-0}" == 1 ]] && exit 1; echo "/data"'
  make_fake_bin fsadm 'exit 0'
  make_fake_bin df 'echo df-ok'
  make_recording_bin lvextend 0
  make_recording_bin resize2fs 0
  make_recording_bin xfs_growfs 0
  make_recording_bin pvresize 0
}

setup() {
  common_setup
  install_fakes
}
teardown() { common_teardown; }

@test "extend: --help exits 0 and prints Usage" {
  run_script "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "extend: missing VG exits 2" {
  run env -u VG LV=lv SIZE=+10G bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"VG is required"* ]]
}

@test "extend: missing LV exits 2" {
  run env -u LV VG=vg SIZE=+10G bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
}

@test "extend: missing SIZE exits 2" {
  run env -u SIZE VG=vg LV=lv bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"SIZE is required"* ]]
}

@test "extend(H3): DRY_RUN prints atomic lvextend --resizefs and calls NO real tool" {
  run env VG=data LV=app SIZE=+10G DRY_RUN=1 PATH="${PATH}" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DRY_RUN: lvextend --resizefs -L +10G"* ]]
  # No separate fs-grow step, and the real lvextend never ran.
  not_called lvextend
  not_called resize2fs
  not_called xfs_growfs
}

@test "extend(H4): refuses a thin volume (lv_attr type V)" {
  run env VG=data LV=thin SIZE=+10G DRY_RUN=1 LVS_ATTR="Vwi-aotz--" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"plain linear/striped LV"* ]]
  [[ "${output}" == *"thin pools/volumes"* ]]
}

@test "extend(H4): refuses a snapshot (lv_attr type s)" {
  run env VG=data LV=snap SIZE=+10G DRY_RUN=1 LVS_ATTR="swi-a-s---" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not a plain linear/striped LV"* ]]
}

@test "extend(H4): refuses a thin-pool (lv_attr type t)" {
  run env VG=data LV=pool SIZE=+10G DRY_RUN=1 LVS_ATTR="twi-aotz--" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
}

@test "extend: unsupported filesystem exits 2" {
  run env VG=data LV=app SIZE=+10G DRY_RUN=1 FAKE_FSTYPE="reiserfs" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"unsupported filesystem"* ]]
}

@test "extend: xfs not mounted fails fast BEFORE extending (exit 1)" {
  run env VG=data LV=app SIZE=+10G DRY_RUN=1 FAKE_FSTYPE="xfs" FAKE_UNMOUNTED=1 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not mounted"* ]]
  not_called lvextend
}

@test "extend(ensure_plain_lv): accepts plain linear via call_func" {
  make_fake_bin lvs 'echo "  -wi-ao----"'
  call_func "${SCRIPT}" ensure_plain_lv "/dev/data/app"
  [ "${status}" -eq 0 ]
}
