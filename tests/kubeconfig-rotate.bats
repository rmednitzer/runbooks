#!/usr/bin/env bats
# Tests for talos/kubeconfig-rotate.sh
#
# Focus: usage/exit-code contract; MERGE validation; DRY_RUN never calls
# talosctl and writes nothing; a real (faked) run writes the kubeconfig and
# backs up a pre-existing one; MERGE=0 passes --force. A fake `talosctl`
# whose `kubeconfig <path>` writes the destination file stands in.

load helpers/common

SCRIPT="talos/kubeconfig-rotate.sh"

# Fake talosctl: `kubeconfig <path>` writes the destination (last arg).
install_fake_talosctl() {
  make_fake_bin talosctl '
printf "talosctl %s\n" "$*" >> "'"${CALLS_LOG}"'"
mode=""
for a in "$@"; do [[ "$a" == "kubeconfig" ]] && mode=kc; done
if [[ "$mode" == kc ]]; then
  # The path is the first non-flag argument after "kubeconfig".
  prev=""
  for a in "$@"; do
    if [[ "$prev" == "kubeconfig" ]]; then printf "FAKE-KUBECONFIG\n" > "$a"; fi
    prev="$a"
  done
fi
exit 0'
}

setup() {
  common_setup
  install_fake_talosctl
}
teardown() { common_teardown; }

@test "kubeconfig: --help exits 0 and prints Usage" {
  run_script "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "kubeconfig: invalid MERGE exits 2" {
  run env MERGE=2 KUBECONFIG_OUT="${TEST_TMP}/kc" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"MERGE must be 0 or 1"* ]]
}

@test "kubeconfig: DRY_RUN prints the command and never calls talosctl" {
  run env KUBECONFIG_OUT="${TEST_TMP}/kc" DRY_RUN=1 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DRY_RUN"* ]]
  [[ "${output}" == *"talosctl"* ]]
  not_called talosctl
  [ ! -e "${TEST_TMP}/kc" ]
}

@test "kubeconfig: real run writes the kubeconfig file" {
  run env KUBECONFIG_OUT="${TEST_TMP}/kc" TALOSCONFIG=/tmp/tc bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ -s "${TEST_TMP}/kc" ]
  called_with talosctl "kubeconfig ${TEST_TMP}/kc"
  called_with talosctl "--talosconfig /tmp/tc"
}

@test "kubeconfig: backs up a pre-existing kubeconfig before overwriting" {
  printf 'OLD-KUBECONFIG\n' > "${TEST_TMP}/kc"
  run env KUBECONFIG_OUT="${TEST_TMP}/kc" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"backing up"* ]]
  local bak
  bak="$(echo "${TEST_TMP}"/kc.bak.*)"
  [ -f "${bak}" ]
  run cat "${bak}"
  [[ "${output}" == "OLD-KUBECONFIG" ]]
}

@test "kubeconfig: MERGE=0 passes --force to talosctl" {
  run env KUBECONFIG_OUT="${TEST_TMP}/kc" MERGE=0 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  called_with talosctl "--force"
}

@test "kubeconfig: MERGE=1 (default) does NOT pass --force" {
  run env KUBECONFIG_OUT="${TEST_TMP}/kc" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  ! called_with talosctl "--force"
}
