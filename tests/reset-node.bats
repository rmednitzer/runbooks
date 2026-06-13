#!/usr/bin/env bats
# Tests for talos/reset-node.sh
#
# Focus (EXTREME-danger script): usage/exit-code contract; NODES required +
# single-node enforced; WIPE_MODE / GRACEFUL / REBOOT validation;
# SYSTEM_LABELS overrides WIPE_MODE; DRY_RUN prints the reset command and
# NEVER calls talosctl; FORCE=1 bypasses BOTH confirmations and issues the
# real `reset` with the right --graceful/--reboot/--wipe-mode flags. A fake
# `talosctl` records calls so we can prove the command and non-invocation.

load helpers/common

SCRIPT="talos/reset-node.sh"

install_fake_talosctl() {
  make_recording_bin talosctl 0
}

setup() {
  common_setup
  install_fake_talosctl
}
teardown() { common_teardown; }

@test "reset: --help exits 0 and prints the EXTREME DANGER usage" {
  run_script "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
  [[ "${output}" == *"EXTREME DANGER"* ]]
}

@test "reset: missing NODES exits 2" {
  run env -u NODES bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"NODES is required"* ]]
}

@test "reset: multiple NODES exits 2" {
  run env NODES="10.0.0.2,10.0.0.3" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"one node at a time"* ]]
}

@test "reset: space-separated NODES exits 2" {
  run env NODES="10.0.0.2 10.0.0.3" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"one node at a time"* ]]
}

@test "reset: invalid WIPE_MODE exits 2" {
  run env NODES=10.0.0.9 WIPE_MODE=bogus DRY_RUN=1 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"WIPE_MODE must be"* ]]
}

@test "reset: invalid GRACEFUL exits 2" {
  run env NODES=10.0.0.9 GRACEFUL=maybe DRY_RUN=1 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"GRACEFUL must be 0 or 1"* ]]
}

@test "reset(safety): DRY_RUN prints the reset command and NEVER calls talosctl" {
  run env NODES=10.0.0.9 WIPE_MODE=all DRY_RUN=1 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"reset --graceful=true --reboot=true --wipe-mode all"* ]]
  [[ "${output}" == *"Nothing was sent to the cluster"* ]]
  not_called talosctl
}

@test "reset: SYSTEM_LABELS overrides WIPE_MODE (uses --system-labels-to-wipe)" {
  run env NODES=10.0.0.2 SYSTEM_LABELS=EPHEMERAL GRACEFUL=0 DRY_RUN=1 \
    bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--system-labels-to-wipe EPHEMERAL"* ]]
  [[ "${output}" == *"--graceful=false"* ]]
  [[ "${output}" != *"--wipe-mode"* ]]
}

@test "reset: FORCE=1 bypasses both confirmations and issues the real reset" {
  run env NODES=10.0.0.9 WIPE_MODE=all TALOSCONFIG=/tmp/tc FORCE=1 \
    bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  called_with talosctl "reset"
  called_with talosctl "--wipe-mode all"
  called_with talosctl "--graceful=true"
  called_with talosctl "--reboot=true"
  called_with talosctl "--nodes 10.0.0.9"
  called_with talosctl "--talosconfig /tmp/tc"
}

@test "reset: REBOOT=0 reflects in the reset flags" {
  run env NODES=10.0.0.9 REBOOT=0 FORCE=1 \
    bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  called_with talosctl "--reboot=false"
}

@test "reset(safety): without a controlling tty it refuses (no confirmation possible) and never resets" {
  # The confirmations read from /dev/tty so a non-interactive run cannot be
  # tricked into proceeding. Under bats there is no usable tty, so
  # confirm_typed errors out and the destructive reset never runs. FORCE=1
  # is the only non-interactive way through — covered above.
  run env NODES=10.0.0.9 WIPE_MODE=all bash "${REPO_ROOT}/${SCRIPT}" < /dev/null
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"no controlling tty"* ]]
  not_called talosctl
}
