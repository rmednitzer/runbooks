#!/usr/bin/env bats
# Tests for logs/journal-vacuum.sh
#
# Focus: usage/exit-code contract; DRY_RUN prints the planned vacuum and
# never runs the real journalctl --vacuum-*; and the M3 behaviour — warn
# when a vacuum reclaims ~nothing (space stuck in the active file) and
# point at ROTATE. A fake journalctl on PATH simulates disk-usage and
# records vacuum/rotate calls.

load helpers/common

SCRIPT="logs/journal-vacuum.sh"

setup() { common_setup; }
teardown() { common_teardown; }

@test "journal: --help exits 0 and prints Usage" {
  run_script "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "journal: bad KEEP_DAYS exits 2" {
  make_fake_bin journalctl 'exit 0'
  run env KEEP_DAYS=abc bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"KEEP_DAYS"* ]]
}

@test "journal: bad KEEP_SIZE exits 2" {
  make_fake_bin journalctl 'exit 0'
  run env KEEP_SIZE="500megs" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"KEEP_SIZE"* ]]
}

@test "journal: missing journalctl reported by require_cmd (exit 1)" {
  # Isolated PATH without journalctl.
  local isodir="${TEST_TMP}/nojc"
  mkdir -p "${isodir}"
  local t real
  for t in bash df printf cat sed; do
    real="$(command -v "${t}" || true)"
    [[ -n "${real}" ]] && ln -sf "${real}" "${isodir}/${t}"
  done
  run env -i PATH="${isodir}" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"journalctl"* ]]
}

@test "journal: DRY_RUN prints planned vacuum and never runs real vacuum" {
  make_fake_bin journalctl '
case "$1" in
  --disk-usage) echo "Archived and active journals take up 2.0G in the file system."; exit 0 ;;
  *) printf "journalctl %s\n" "$*" >> "'"${CALLS_LOG}"'"; exit 0 ;;
esac'
  make_fake_bin df 'echo df-ok'
  run env DRY_RUN=1 KEEP_DAYS=7 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DRY_RUN: journalctl --vacuum-time=7d"* ]]
  not_called journalctl   # no --vacuum-* / --rotate actually executed
}

@test "journal(M3): warns when vacuum frees ~nothing and suggests ROTATE" {
  # disk-usage returns the SAME 2.0G before and after -> negligible delta.
  make_fake_bin journalctl '
case "$1" in
  --disk-usage) echo "Archived and active journals take up 2.0G in the file system."; exit 0 ;;
  --vacuum-size|--vacuum-time) exit 0 ;;
  --vacuum-size=*|--vacuum-time=*) exit 0 ;;
  --rotate) exit 0 ;;
  *) exit 0 ;;
esac'
  make_fake_bin df 'echo df-ok'
  run env KEEP_SIZE=500M bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"freed almost nothing"* ]]
  [[ "${output}" == *"ACTIVE journal file"* ]]
  [[ "${output}" == *"ROTATE=1"* ]]
}

@test "journal(M3): ROTATE=1 runs --rotate before the vacuum" {
  make_fake_bin journalctl '
case "$1" in
  --disk-usage) echo "Archived and active journals take up 2.0G in the file system."; exit 0 ;;
  *) printf "journalctl %s\n" "$*" >> "'"${CALLS_LOG}"'"; exit 0 ;;
esac'
  make_fake_bin df 'echo df-ok'
  run env ROTATE=1 KEEP_SIZE=500M bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  called_with journalctl "--rotate"
  called_with journalctl "--vacuum-size=500M"
}

@test "journal(journal_bytes): parses a human size to bytes" {
  make_fake_bin journalctl 'echo "Archived and active journals take up 1.5G in the file system."'
  call_func "${SCRIPT}" journal_bytes
  [ "${status}" -eq 0 ]
  # 1.5G == 1610612736 bytes (IEC)
  [ "${output}" = "1610612736" ]
}
