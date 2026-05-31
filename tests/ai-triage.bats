#!/usr/bin/env bats
# Tests for secops/ai-triage.sh
#
# Focus: usage/exit-code contract; SOURCE / MAX_LINES validation; missing
# journalctl is a clean dependency error; the host source gathers signals and
# (DRY_RUN) prints the prompt without contacting any endpoint; the siem source
# is a stub (exit 1); with no endpoint the gathered signals still print; and a
# PATH-shimmed fake `python3` exercises both the triage-success and
# inference-unavailable paths — the real model is never called.

load helpers/common

SCRIPT="secops/ai-triage.sh"

# Fake journalctl: a UFW drop line for the kernel (-k) query, a warning-level
# line otherwise. Lets the host gather run deterministically with no real journal.
install_fake_journalctl() {
  make_fake_bin journalctl '
for a in "$@"; do
  case "$a" in
    -k) echo "kernel: [UFW BLOCK] IN=eth0 SRC=10.0.0.9 DPT=22"; exit 0 ;;
    *) ;;
  esac
done
echo "May 31 02:00 host sshd[1]: Failed password for root from 10.0.0.9 port 22"'
}

setup() {
  common_setup
  install_fake_journalctl
  make_fake_bin hostname 'echo testhost'
}
teardown() { common_teardown; }

@test "ai-triage: --help exits 0 and prints Usage" {
  run_script "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "ai-triage: unexpected argument exits 2" {
  run_script "${SCRIPT}" bogusarg
  [ "${status}" -eq 2 ]
}

@test "ai-triage: invalid SOURCE exits 2" {
  run env SOURCE=bogus bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"SOURCE must be"* ]]
}

@test "ai-triage: invalid MAX_LINES exits 2" {
  run env MAX_LINES=0 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"MAX_LINES must be a positive integer"* ]]
}

@test "ai-triage: missing journalctl is a clean dependency error (exit 2)" {
  local isodir="${TEST_TMP}/nojournal"
  mkdir -p "${isodir}"
  # bash + python3 + mktemp to reach the journalctl check, and rm for the
  # EXIT cleanup trap; journalctl is deliberately absent.
  local t real
  for t in bash python3 mktemp rm; do
    real="$(command -v "${t}" || true)"
    [[ -n "${real}" ]] && ln -sf "${real}" "${isodir}/${t}"
  done
  run env -i PATH="${isodir}" SOURCE=host bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"journalctl is required"* ]]
}

@test "ai-triage: SOURCE=siem is a stub (exit 1)" {
  run env SOURCE=siem bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"siem"* ]]
}

@test "ai-triage: DRY_RUN gathers signals and prints the prompt, no endpoint contacted" {
  run env DRY_RUN=1 SOURCE=host OLLAMA_ENDPOINT=http://127.0.0.1:11434 \
    bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"=== Gathered signals ==="* ]]
  [[ "${output}" == *"[UFW BLOCK]"* ]]
  [[ "${output}" == *"=== Prompt (DRY_RUN"* ]]
  [[ "${output}" == *"not contacted"* ]]
  # The model triage section must NOT appear in a dry run.
  [[ "${output}" != *"=== AI triage"* ]]
}

@test "ai-triage: no endpoint still prints gathered signals (exit 0)" {
  run env -u OLLAMA_ENDPOINT SOURCE=host bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"=== Gathered signals ==="* ]]
  [[ "${output}" == *"OLLAMA_ENDPOINT is unset"* ]]
}

@test "ai-triage: triage success path (fake python3 emits a verdict)" {
  make_fake_bin python3 'cat << "MSG"
Assessment: medium — repeated SSH auth failures for root from 10.0.0.9.
Next: verify 10.0.0.9 and confirm root SSH login is disabled.
MSG'
  run env SOURCE=host OLLAMA_ENDPOINT=http://127.0.0.1:11434 \
    bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"=== AI triage (local inference"* ]]
  [[ "${output}" == *"Assessment: medium"* ]]
}

@test "ai-triage: inference-unavailable path degrades to raw signals (exit 0)" {
  make_fake_bin python3 'echo URLError >&2; exit 3'
  run env SOURCE=host OLLAMA_ENDPOINT=http://127.0.0.1:11434 \
    bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"=== Gathered signals ==="* ]]
  [[ "${output}" == *"local inference unavailable"* ]]
}

@test "ai-triage: a failing collector is surfaced, not silently '(none)'" {
  # ausearch present but denied: the section must show the failure, not "(none)".
  make_fake_bin ausearch 'echo "Error opening audit log: Permission denied" >&2; exit 1'
  run env SOURCE=host DRY_RUN=1 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"collector exited"* ]]
  [[ "${output}" == *"Permission denied"* ]]
}
