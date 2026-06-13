#!/usr/bin/env bats
# Tests for talos/upgrade-node.sh
#
# Focus: usage/exit-code contract; NODES + IMAGE required and single-node
# enforced; the image-ref SHAPE validator (accepts tag and @sha256 digest,
# rejects junk, warns on a mutable tag); DRY_RUN never calls talosctl; the
# pre-flight `talosctl health` gate blocks an upgrade onto an unhealthy
# cluster (and SKIP_HEALTH overrides); --stage is forwarded (no --preserve).
# A fake `talosctl` records calls and can fail `health` on demand.

load helpers/common

SCRIPT="talos/upgrade-node.sh"

# Fake talosctl: records calls; `health` exits HEALTH_RC (default 0),
# `upgrade` exits UPGRADE_RC (default 0).
install_fake_talosctl() {
  make_fake_bin talosctl '
printf "talosctl %s\n" "$*" >> "'"${CALLS_LOG}"'"
for a in "$@"; do
  [[ "$a" == "health" ]] && exit "${HEALTH_RC:-0}"
  [[ "$a" == "upgrade" ]] && exit "${UPGRADE_RC:-0}"
done
exit 0'
}

GOOD_IMAGE="ghcr.io/siderolabs/installer:v1.9.5"
DIGEST_IMAGE="ghcr.io/siderolabs/installer@sha256:$(printf 'a%.0s' {1..64})"

setup() {
  common_setup
  install_fake_talosctl
}
teardown() { common_teardown; }

@test "upgrade: --help exits 0 and prints Usage" {
  run_script "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "upgrade: missing NODES exits 2" {
  run env -u NODES IMAGE="${GOOD_IMAGE}" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"NODES is required"* ]]
}

@test "upgrade: multiple NODES exits 2 (one node at a time)" {
  run env NODES="10.0.0.2,10.0.0.3" IMAGE="${GOOD_IMAGE}" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"one at a time"* ]]
}

@test "upgrade: space-separated NODES exits 2 (one node at a time)" {
  run env NODES="10.0.0.2 10.0.0.3" IMAGE="${GOOD_IMAGE}" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"one at a time"* ]]
}

@test "upgrade: missing IMAGE exits 2" {
  run env -u IMAGE NODES=10.0.0.2 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"IMAGE is required"* ]]
}

@test "upgrade: bogus IMAGE ref exits 2" {
  run env NODES=10.0.0.2 IMAGE="not a ref" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"does not look like a valid installer ref"* ]]
}

@test "upgrade(validate_image_ref): accepts tag and digest, rejects junk" {
  call_func "${SCRIPT}" validate_image_ref "ghcr.io/siderolabs/installer:v1.9.5"
  [ "${status}" -eq 0 ]
  call_func "${SCRIPT}" validate_image_ref "${DIGEST_IMAGE}"
  [ "${status}" -eq 0 ]
  call_func "${SCRIPT}" validate_image_ref "noslash:tag"
  [ "${status}" -ne 0 ]
  call_func "${SCRIPT}" validate_image_ref "ghcr.io/repo"
  [ "${status}" -ne 0 ]
  call_func "${SCRIPT}" validate_image_ref ""
  [ "${status}" -ne 0 ]
}

@test "upgrade: DRY_RUN prints the command, warns on mutable tag, never calls talosctl" {
  run env NODES=10.0.0.2 IMAGE="${GOOD_IMAGE}" DRY_RUN=1 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"upgrade --image ${GOOD_IMAGE}"* ]]
  [[ "${output}" == *"mutable tag"* ]]
  not_called talosctl
}

@test "upgrade: a digest-pinned IMAGE does not warn about mutability" {
  run env NODES=10.0.0.2 IMAGE="${DIGEST_IMAGE}" DRY_RUN=1 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"mutable tag"* ]]
  [[ "${output}" == *"digest-pin : yes"* ]]
}

@test "upgrade: pre-flight health failure blocks the upgrade (exit 1)" {
  run env NODES=10.0.0.2 IMAGE="${GOOD_IMAGE}" HEALTH_RC=1 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"pre-flight health check FAILED"* ]]
  # health ran, but the destructive upgrade must NOT have.
  called_with talosctl "health"
  ! called_with talosctl "upgrade"
}

@test "upgrade: healthy pre-flight proceeds and forwards --stage" {
  run env NODES=10.0.0.2 IMAGE="${GOOD_IMAGE}" HEALTH_RC=0 STAGE=1 \
    bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  called_with talosctl "upgrade"
  called_with talosctl "--stage"
  # talosctl upgrade has no --preserve flag; ensure we never emit it.
  not_called_with talosctl "--preserve"
}

@test "upgrade: SKIP_HEALTH=1 bypasses the gate and still upgrades" {
  run env NODES=10.0.0.2 IMAGE="${GOOD_IMAGE}" SKIP_HEALTH=1 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  ! called_with talosctl "health"
  called_with talosctl "upgrade --image ${GOOD_IMAGE}"
}
