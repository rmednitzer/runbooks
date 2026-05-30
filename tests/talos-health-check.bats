#!/usr/bin/env bats
# Tests for talos/talos-health-check.sh
#
# Focus: usage/exit-code contract; that the read-only script honours the
# TALOSCONFIG/NODES targeting flags it builds; that a healthy `talosctl
# health` yields exit 0 and an unhealthy one yields exit 1; and that
# DMESG_TAIL validation works. A fake `talosctl` on PATH records its calls
# so we can assert the targeting flags and the read-only command set.

load helpers/common

SCRIPT="talos/talos-health-check.sh"

# Fake talosctl: records every invocation, and lets a test force the
# `health` subcommand's exit code via HEALTH_RC (default 0). Everything
# else exits 0 with a trivial line so the triage sections "succeed".
install_fake_talosctl() {
  make_fake_bin talosctl '
printf "talosctl %s\n" "$*" >> "'"${CALLS_LOG}"'"
# Find the subcommand (first non-flag, non-flag-value token). Good enough
# for these tests: health is always the literal "health".
for a in "$@"; do
  if [[ "$a" == "health" ]]; then
    exit "${HEALTH_RC:-0}"
  fi
done
echo "ok"
exit 0'
}

setup() {
  common_setup
  install_fake_talosctl
}
teardown() { common_teardown; }

@test "health: --help exits 0 and prints Usage" {
  run_script "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "health: missing talosctl exits 1" {
  # Isolated PATH with only bash/coreutils symlinks, no talosctl.
  local isodir="${TEST_TMP}/notalos"
  mkdir -p "${isodir}"
  local t real
  for t in bash tail; do
    real="$(command -v "${t}" || true)"
    [[ -n "${real}" ]] && ln -sf "${real}" "${isodir}/${t}"
  done
  run env -i PATH="${isodir}" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"required command not found: talosctl"* ]]
}

@test "health: non-integer DMESG_TAIL exits 2" {
  run env DMESG_TAIL=abc bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"DMESG_TAIL must be a non-negative integer"* ]]
}

@test "health: healthy cluster exits 0 and runs the read-only sections" {
  run env HEALTH_RC=0 NODES=10.0.0.2 DMESG_TAIL=0 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"reported the cluster HEALTHY"* ]]
  # The expected read-only command set ran (no mutating verbs anywhere).
  called_with talosctl "version"
  called_with talosctl "get members"
  called_with talosctl "health --server=false"
  called_with talosctl "etcd members"
  called_with talosctl "services"
}

@test "health: unhealthy cluster exits 1" {
  run env HEALTH_RC=1 NODES=10.0.0.2 DMESG_TAIL=0 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"reported the cluster UNHEALTHY"* ]]
}

@test "health: forwards TALOSCONFIG and NODES as talosctl flags" {
  run env TALOSCONFIG=/tmp/tc NODES=10.0.0.2 ENDPOINTS=10.0.0.2 DMESG_TAIL=0 \
    bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  called_with talosctl "--talosconfig /tmp/tc"
  called_with talosctl "--nodes 10.0.0.2"
  called_with talosctl "--endpoints 10.0.0.2"
}

@test "health: a failing telemetry section never aborts the run (still exits on health verdict)" {
  # talosctl that fails everything EXCEPT health (which is healthy). The
  # triage sections must be tolerated and the run still concludes HEALTHY.
  make_fake_bin talosctl '
printf "talosctl %s\n" "$*" >> "'"${CALLS_LOG}"'"
for a in "$@"; do [[ "$a" == "health" ]] && exit 0; done
echo "boom" >&2
exit 7'
  run env NODES=10.0.0.2 DMESG_TAIL=0 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"reported the cluster HEALTHY"* ]]
  [[ "${output}" == *"continuing triage"* ]]
}
