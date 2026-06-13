#!/usr/bin/env bats
# Tests for talos/etcd-snapshot.sh
#
# Focus: usage/exit-code contract; NODES is required and must be a single
# node; DRY_RUN never calls the real talosctl and writes nothing; a real
# (faked) run writes a verified snapshot + checksum and prints the restore
# pointer; an empty snapshot is treated as failure. A fake `talosctl` whose
# `etcd snapshot` writes a file stands in for the real tool.

load helpers/common

SCRIPT="talos/etcd-snapshot.sh"

# Fake talosctl: `etcd snapshot <path>` writes some bytes to <path> (the
# last argument). Records calls so we can assert flags / non-invocation.
install_fake_talosctl() {
  make_fake_bin talosctl '
printf "talosctl %s\n" "$*" >> "'"${CALLS_LOG}"'"
mode=""
for a in "$@"; do [[ "$a" == "snapshot" ]] && mode=snapshot; done
if [[ "$mode" == snapshot ]]; then
  out="${@: -1}"
  printf "FAKE-ETCD-SNAPSHOT-DATA\n" > "$out"
fi
exit 0'
}

setup() {
  common_setup
  install_fake_talosctl
}
teardown() { common_teardown; }

@test "snapshot: --help exits 0 and prints Usage" {
  run_script "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "snapshot: missing NODES exits 2" {
  run env -u NODES bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"NODES is required"* ]]
}

@test "snapshot: multiple NODES exits 2" {
  run env NODES="10.0.0.2,10.0.0.3" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"SINGLE control-plane node"* ]]
}

@test "snapshot: space-separated NODES exits 2" {
  run env NODES="10.0.0.2 10.0.0.3" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"SINGLE control-plane node"* ]]
}

@test "snapshot: DRY_RUN prints the planned command and never calls talosctl" {
  run env NODES=10.0.0.2 BACKUP_DIR="${TEST_TMP}/bk" DRY_RUN=1 \
    bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DRY_RUN: talosctl"* ]]
  [[ "${output}" == *"etcd snapshot"* ]]
  not_called talosctl
  # Nothing was written.
  [ ! -d "${TEST_TMP}/bk" ]
}

@test "snapshot: real run writes a verified snapshot + checksum and a restore pointer" {
  run env NODES=10.0.0.2 BACKUP_DIR="${TEST_TMP}/bk" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"verified"* ]]
  [[ "${output}" == *"bootstrap --recover-from="* ]]
  # talosctl was actually invoked with the snapshot subcommand + node flag.
  called_with talosctl "etcd snapshot"
  called_with talosctl "--nodes 10.0.0.2"
  # A snapshot file and a .sha256 sidecar now exist and the checksum matches.
  local snap
  snap="$(echo "${TEST_TMP}"/bk/etcd-10.0.0.2-*.snapshot)"
  [ -s "${snap}" ]
  [ -f "${snap}.sha256" ]
  # The sidecar records a basename, so verify from the snapshot's directory.
  run bash -c "cd \"$(dirname "${snap}")\" && sha256sum -c --status \"$(basename "${snap}").sha256\""
  [ "${status}" -eq 0 ]
}

@test "snapshot: empty snapshot file is treated as failure (exit 1)" {
  # talosctl that "succeeds" but writes a zero-byte file.
  make_fake_bin talosctl '
for a in "$@"; do [[ "$a" == "snapshot" ]] && : > "${@: -1}"; done
exit 0'
  run env NODES=10.0.0.2 BACKUP_DIR="${TEST_TMP}/bk" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"empty"* ]]
}

@test "snapshot: talosctl failure exits 1" {
  make_fake_bin talosctl 'exit 3'
  run env NODES=10.0.0.2 BACKUP_DIR="${TEST_TMP}/bk" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"talosctl etcd snapshot failed"* ]]
}
