#!/usr/bin/env bats
# Tests for talos/etcd-restore.sh
#
# Focus (this is the most destructive Talos script, so its guards get the
# most scrutiny): usage/exit-code contract; SNAPSHOT and NODES required;
# >1 node refused (split-brain guard); DRY_RUN prints the bootstrap command
# and NEVER calls talosctl; a corrupt snapshot (bad checksum sidecar) is
# refused; FORCE=1 runs the real `bootstrap --recover-from=` and passes the
# --recover-skip-hash-check flag only when asked. A fake `talosctl` records
# its calls so we can prove the exact command and non-invocation in DRY_RUN.

load helpers/common

SCRIPT="talos/etcd-restore.sh"

# A snapshot file plus a VALID matching checksum sidecar.
make_good_snapshot() {
  SNAP="${TEST_TMP}/db.snapshot"
  printf 'FAKE-SNAPSHOT\n' > "${SNAP}"
  (cd "${TEST_TMP}" && sha256sum "db.snapshot" > "db.snapshot.sha256")
  export SNAP
}

install_fake_talosctl() {
  make_recording_bin talosctl 0
}

setup() {
  common_setup
  install_fake_talosctl
  make_good_snapshot
}
teardown() { common_teardown; }

@test "restore: --help exits 0 and prints the DANGER usage" {
  run_script "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
  [[ "${output}" == *"DANGER"* ]]
}

@test "restore: missing SNAPSHOT exits 2" {
  run env -u SNAPSHOT NODES=10.0.0.2 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"SNAPSHOT is required"* ]]
}

@test "restore: missing NODES exits 2" {
  run env -u NODES SNAPSHOT="${SNAP}" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"NODES is required"* ]]
}

@test "restore: multiple NODES refused (split-brain guard) exits 2" {
  run env SNAPSHOT="${SNAP}" NODES="10.0.0.2,10.0.0.3" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"splits brain"* ]]
}

@test "restore: space-separated NODES refused (split-brain guard) exits 2" {
  run env SNAPSHOT="${SNAP}" NODES="10.0.0.2 10.0.0.3" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"splits brain"* ]]
}

@test "restore: missing snapshot file exits 1" {
  run env SNAPSHOT="${TEST_TMP}/nope.snapshot" NODES=10.0.0.2 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"snapshot file not found"* ]]
}

@test "restore(safety): DRY_RUN prints the bootstrap command and NEVER calls talosctl" {
  run env SNAPSHOT="${SNAP}" NODES=10.0.0.2 DRY_RUN=1 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"bootstrap --recover-from=${SNAP}"* ]]
  [[ "${output}" == *"Nothing was sent to the cluster"* ]]
  not_called talosctl
}

@test "restore(safety): refuses a corrupt snapshot (checksum mismatch) exits 1" {
  # Tamper with the snapshot AFTER the sidecar was written.
  printf 'TAMPERED\n' >> "${SNAP}"
  run env SNAPSHOT="${SNAP}" NODES=10.0.0.2 FORCE=1 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"checksum FAILED"* ]]
  # The destructive bootstrap must NOT have run.
  not_called talosctl
}

@test "restore: FORCE=1 runs the real bootstrap --recover-from with the node flag" {
  run env SNAPSHOT="${SNAP}" NODES=10.0.0.2 TALOSCONFIG=/tmp/tc FORCE=1 \
    bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  called_with talosctl "bootstrap"
  called_with talosctl "--recover-from=${SNAP}"
  called_with talosctl "--nodes 10.0.0.2"
  called_with talosctl "--talosconfig /tmp/tc"
  # Default: hash check is ON, so the skip flag must be ABSENT.
  ! called_with talosctl "--recover-skip-hash-check"
}

@test "restore: SKIP_HASH_CHECK=1 adds --recover-skip-hash-check" {
  run env SNAPSHOT="${SNAP}" NODES=10.0.0.2 SKIP_HASH_CHECK=1 FORCE=1 \
    bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  called_with talosctl "--recover-skip-hash-check"
}

@test "restore: a missing checksum sidecar warns but still proceeds under FORCE" {
  rm -f "${SNAP}.sha256"
  run env SNAPSHOT="${SNAP}" NODES=10.0.0.2 FORCE=1 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"cannot verify snapshot integrity"* ]]
  called_with talosctl "bootstrap"
}
