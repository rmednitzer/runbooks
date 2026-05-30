#!/usr/bin/env bats
# Tests for storage/disk-usage-triage.sh
#
# Focus: usage/exit-code contract, and the M2 df-parsing fix — mountpoints
# with spaces must be handled, and non-ext/xfs/btrfs local filesystems
# (zfs/f2fs/bcachefs) must NOT be silently dropped. Read-only script, so a
# fake df drives the mount-selection logic.

load helpers/common

SCRIPT="storage/disk-usage-triage.sh"

# Fake df that, for the `--output=pcent,target` form, emits a fixture with
# a spaced mountpoint and an f2fs mount; for the plain `-h` form, prints a
# placeholder. du/find/lsof/journalctl are harmless stubs.
install_fakes() {
  make_fake_bin df '
want=0
for a in "$@"; do [[ "$a" == "--output=pcent,target" ]] && want=1; done
if [[ "$want" == 1 ]]; then
  echo "Use% Mounted on"
  echo " 12% /"
  echo " 91% /mnt/data pool"
  echo " 88% /srv/f2fs"
  echo "  3% /boot"
else
  echo "df -h placeholder"
fi'
  make_fake_bin du 'echo "  4.0K  /x"'
  make_fake_bin find 'exit 0'
  make_fake_bin lsof 'exit 0'
  make_fake_bin journalctl 'echo "0B"'
  make_fake_bin findmnt 'exit 0'
}

setup() {
  common_setup
  install_fakes
}
teardown() { common_teardown; }

@test "triage: --help exits 0 and prints Usage" {
  run_script "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "triage: non-integer THRESHOLD exits 2" {
  run env THRESHOLD=abc bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
}

@test "triage: THRESHOLD over 100 exits 2" {
  run env THRESHOLD=150 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"0..100"* ]]
}

@test "triage: non-integer TOP_N exits 2" {
  run env TOP_N=x bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
}

@test "triage: MOUNT that is not a mountpoint exits 2" {
  make_fake_bin findmnt 'exit 1' # findmnt --target fails -> not a mountpoint
  run env MOUNT="/no/such/mount" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"not a mountpoint"* ]]
}

@test "triage(M2): selects a mountpoint that contains a space" {
  run env THRESHOLD=80 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"/mnt/data pool"* ]]
}

@test "triage(M2): does NOT drop a non-ext/xfs/btrfs FS (f2fs)" {
  run env THRESHOLD=80 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"/srv/f2fs"* ]]
}

@test "triage(M2): excludes filesystems below threshold" {
  run env THRESHOLD=80 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  # / (12%) and /boot (3%) are below 80 and must not be scanned.
  [[ "${output}" != *"Mountpoint: /boot"* ]]
}

@test "triage(L2): announces ionice/nice prefix when available" {
  make_fake_bin ionice 'exec "$@"'
  make_fake_bin nice 'exec "$@"'
  run env THRESHOLD=80 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"du walk niced via:"* ]]
}
