#!/usr/bin/env bats
# Tests for recovery/unlock-account.sh
#
# Focus: usage/exit-code contract, the H5 IP-literal regression cases
# (octal octets like 08.1.1.1, loose IPv6 like ::::), and the M4 unified
# DRY_RUN path (unban routed through run_ok, never calling the real
# fail2ban-client).
#
# The script defines its own `run()` helper and an ERR trap, so we cannot
# `source` it and then use bats' `run`. Instead `call_func` (see
# helpers/common.bash) sources it in a fresh bash with the trap and the
# `run` shadow neutralised, then invokes the target function — keeping
# these unit tests independent of being root.

load helpers/common

SCRIPT="recovery/unlock-account.sh"

setup() { common_setup; }
teardown() { common_teardown; }

@test "unlock: --help exits 0 and prints Usage" {
  run_script "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "unlock: neither TARGET_USER nor IP set exits 2" {
  run env -u TARGET_USER -u IP bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"at least one of"* ]]
}

# --- H5 regression: is_ip_literal (authoritative python3 path) ---

@test "unlock(is_ip_literal): accepts ordinary IPv4/IPv6" {
  call_func "${SCRIPT}" is_ip_literal "192.0.2.10"; [ "${status}" -eq 0 ]
  call_func "${SCRIPT}" is_ip_literal "8.1.1.1"; [ "${status}" -eq 0 ]
  call_func "${SCRIPT}" is_ip_literal "2001:db8::1"; [ "${status}" -eq 0 ]
  call_func "${SCRIPT}" is_ip_literal "::1"; [ "${status}" -eq 0 ]
}

@test "unlock(is_ip_literal): rejects zero-padded octet 08.1.1.1 (H5.1 octal)" {
  call_func "${SCRIPT}" is_ip_literal "08.1.1.1"
  [ "${status}" -ne 0 ]
}

@test "unlock(is_ip_literal): rejects 09.1.1.1 without an octal arithmetic error" {
  call_func "${SCRIPT}" is_ip_literal "09.1.1.1"
  [ "${status}" -ne 0 ]
  [[ "${output}" != *"value too great for base"* ]]
}

@test "unlock(is_ip_literal): rejects out-of-range octet 256.1.1.1" {
  call_func "${SCRIPT}" is_ip_literal "256.1.1.1"
  [ "${status}" -ne 0 ]
}

@test "unlock(is_ip_literal): rejects garbage IPv6 '::::' (H5.2)" {
  call_func "${SCRIPT}" is_ip_literal "::::"
  [ "${status}" -ne 0 ]
}

@test "unlock(is_ip_literal): rejects hostnames, partials, and empties" {
  call_func "${SCRIPT}" is_ip_literal "not-an-ip"; [ "${status}" -ne 0 ]
  call_func "${SCRIPT}" is_ip_literal ""; [ "${status}" -ne 0 ]
  call_func "${SCRIPT}" is_ip_literal "1.2.3"; [ "${status}" -ne 0 ]
}

@test "unlock(is_ip_literal): regex fallback (no python3) still gets H5 cases right" {
  # Isolated PATH with the tools is_ip_literal's fallback needs, but NO
  # python3, so the regex branch is exercised.
  local isodir="${TEST_TMP}/nopy"
  mkdir -p "${isodir}"
  local t real
  for t in bash grep sed cat; do
    real="$(command -v "${t}" || true)"
    [[ -n "${real}" ]] && ln -sf "${real}" "${isodir}/${t}"
  done
  _fb() {
    run env -i PATH="${isodir}" bash -c '
      set +e; source "$1"; trap - ERR; is_ip_literal "$2"
    ' _ "${REPO_ROOT}/${SCRIPT}" "$1"
  }
  _fb "08.1.1.1"; [ "${status}" -ne 0 ]
  _fb "::::"; [ "${status}" -ne 0 ]
  _fb "192.0.2.10"; [ "${status}" -eq 0 ]
  _fb "2001:db8::1"; [ "${status}" -eq 0 ]
}

# --- M4: unified DRY_RUN path through run_ok ---

@test "unlock(unban_ip): DRY_RUN prints planned command and never calls real fail2ban-client" {
  # Fake fail2ban-client: `status` (no jail arg) lists two jails; any
  # other invocation records itself so we can assert it was NOT called
  # under DRY_RUN. The script parses jails from the 'Jail list:' line.
  make_fake_bin fail2ban-client '
if [[ "$1" == "status" && -z "$2" ]]; then
  printf "Status\n|- Jail list:\tsshd, recidive\n"
  exit 0
fi
printf "%s %s\n" "fail2ban-client" "$*" >> "'"${CALLS_LOG}"'"
exit 0'
  run env DRY_RUN=1 bash -c '
    set +e; source "$1"; trap - ERR; unban_ip "192.0.2.10"
  ' _ "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DRY_RUN: fail2ban-client set"* ]]
  [[ "${output}" == *"unbanip 192.0.2.10"* ]]
  # The destructive `set ... unbanip` action must NOT have run under
  # DRY_RUN. (Read-only `status <jail>` calls in the bans summary are
  # fine — we only forbid the mutating one.)
  ! grep -q -- "unbanip" "${CALLS_LOG}"
  ! grep -qE "fail2ban-client set " "${CALLS_LOG}"
}

@test "unlock(run_ok): non-DRY_RUN runs the command and tolerates a non-zero exit" {
  make_recording_bin flaky 3
  run env DRY_RUN=0 bash -c '
    set +e; source "$1"; trap - ERR; run_ok flaky arg1
  ' _ "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"informational"* ]]
  called_with flaky "arg1"
}
