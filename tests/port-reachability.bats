#!/usr/bin/env bats
# Tests for network/port-reachability.sh
#
# Focus: usage/exit-code contract; HOST/PORT required; port + TIMEOUT +
# METHOD validation; the METHOD=nc path drives a fake `nc` so we can assert
# reachable (exit 0) and unreachable (exit 1) without real sockets; a
# multi-port spec is parsed; and the validators are unit-tested. We force
# METHOD=nc in most cases so the probe is fully controlled by the fake nc.

load helpers/common

SCRIPT="network/port-reachability.sh"

# Fake nc: exits 0 (reachable) unless the port is in UNREACH_PORTS (a
# space-separated list), in which case it exits 1 (refused/filtered). The
# port is nc's last argument.
install_fake_nc() {
  make_fake_bin nc '
port="${@: -1}"
for u in ${UNREACH_PORTS:-}; do
  [[ "$port" == "$u" ]] && exit 1
done
exit 0'
}

setup() {
  common_setup
  install_fake_nc
}
teardown() { common_teardown; }

@test "port: --help exits 0 and prints Usage" {
  run_script "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "port: missing HOST exits 2" {
  run env -u HOST -u PORT bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"HOST is required"* ]]
}

@test "port: missing PORT exits 2" {
  run env -u PORT HOST=example.com bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"PORT is required"* ]]
}

@test "port: out-of-range port exits 2" {
  run env HOST=example.com PORT=70000 METHOD=nc bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"port must be 1..65535"* ]]
}

@test "port: invalid TIMEOUT exits 2" {
  run env HOST=example.com PORT=443 TIMEOUT=0 METHOD=nc bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"TIMEOUT must be a positive integer"* ]]
}

@test "port: invalid METHOD exits 2" {
  run env HOST=example.com PORT=443 METHOD=telnet bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"METHOD must be auto|devtcp|nc"* ]]
}

@test "port(nc): reachable target exits 0" {
  run env HOST=db.internal PORT=5432 METHOD=nc bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"5432  REACHABLE"* ]]
  [[ "${output}" == *"all targets reachable"* ]]
}

@test "port(nc): unreachable target exits 1" {
  run env HOST=db.internal PORT=5432 METHOD=nc UNREACH_PORTS="5432" \
    bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"5432  UNREACHABLE"* ]]
}

@test "port(nc): multi-port spec — one unreachable makes the run exit 1" {
  run env HOST=10.0.0.5 PORT="22,80,443" METHOD=nc UNREACH_PORTS="80" \
    bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"22  REACHABLE"* ]]
  [[ "${output}" == *"80  UNREACHABLE"* ]]
  [[ "${output}" == *"443  REACHABLE"* ]]
}

@test "port: METHOD=nc but nc absent is a clean dependency error" {
  # Isolated PATH with timeout + bash but NO nc.
  local isodir="${TEST_TMP}/nonc"
  mkdir -p "${isodir}"
  local t real
  for t in bash timeout; do
    real="$(command -v "${t}" || true)"
    [[ -n "${real}" ]] && ln -sf "${real}" "${isodir}/${t}"
  done
  run env -i PATH="${isodir}" HOST=x PORT=443 METHOD=nc \
    bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"required command not found: nc"* ]]
}

@test "port: passes HOST and PORT positionally" {
  run env -u HOST -u PORT METHOD=nc bash "${REPO_ROOT}/${SCRIPT}" api.example.com 443
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"host       : api.example.com"* ]]
}
