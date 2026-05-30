#!/usr/bin/env bats
# Tests for network/dns-propagation-check.sh
#
# Focus: usage/exit-code contract; NAME required; TIMEOUT/TRIES validation;
# missing dig is a clean dependency error; with a fake `dig`, agreement
# across resolvers exits 0 and a divergent resolver exits 1. The fake dig
# returns a per-resolver answer driven by a small map so we can craft both
# the agree and diverge cases deterministically.

load helpers/common

SCRIPT="network/dns-propagation-check.sh"

# Fake dig: parses "@<resolver>" and the name/type from its args and prints
# an answer. By default every resolver returns the SAME address (agree).
# If DIVERGE_RESOLVER is set, that one resolver returns a different address.
install_fake_dig_agree() {
  make_fake_bin dig '
resolver=""
for a in "$@"; do
  case "$a" in @*) resolver="${a#@}" ;; esac
done
if [[ -n "${DIVERGE_RESOLVER:-}" && "$resolver" == "${DIVERGE_RESOLVER}" ]]; then
  echo "203.0.113.99"
else
  echo "203.0.113.10"
fi'
}

setup() {
  common_setup
  install_fake_dig_agree
}
teardown() { common_teardown; }

@test "dns: --help exits 0 and prints Usage" {
  run_script "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "dns: missing NAME exits 2" {
  run env -u NAME bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"NAME is required"* ]]
}

@test "dns: invalid TIMEOUT exits 2" {
  run env NAME=example.com TIMEOUT=0 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"TIMEOUT must be a positive integer"* ]]
}

@test "dns: missing dig is a clean dependency error (exit 1)" {
  local isodir="${TEST_TMP}/nodig"
  mkdir -p "${isodir}"
  local t real
  for t in bash awk sort; do
    real="$(command -v "${t}" || true)"
    [[ -n "${real}" ]] && ln -sf "${real}" "${isodir}/${t}"
  done
  run env -i PATH="${isodir}" NAME=example.com RESOLVERS="1.1.1.1" \
    bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"required command not found: dig"* ]]
}

@test "dns: all resolvers agree -> exit 0" {
  run env NAME=example.com RESOLVERS="1.1.1.1 8.8.8.8 9.9.9.9" \
    bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"all resolvers agree"* ]]
}

@test "dns: a divergent resolver -> exit 1 and is flagged DIVERGENT" {
  run env NAME=example.com RESOLVERS="1.1.1.1 8.8.8.8 9.9.9.9" \
    DIVERGE_RESOLVER="9.9.9.9" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"DIVERGENT"* ]]
  [[ "${output}" == *"DIVERGE"* ]]
}

@test "dns: passes NAME and RTYPE positionally" {
  run env -u NAME -u RTYPE RESOLVERS="1.1.1.1" \
    bash "${REPO_ROOT}/${SCRIPT}" example.com A
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"name       : example.com"* ]]
  [[ "${output}" == *"type       : A"* ]]
}
