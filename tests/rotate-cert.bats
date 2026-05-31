#!/usr/bin/env bats
# Tests for certificates/rotate-cert.sh
#
# Focus: the safety contract — refuse a cert/key pair whose public keys do not
# match; DRY_RUN changes nothing; an already-installed cert is a no-op; a real
# rotation installs atomically with a 0600 key and reloads; and a FAILED reload
# rolls back to the previous cert. Real openssl generates the pairs (matching
# and mismatched), so the validation logic runs for real; only `systemctl` is
# shimmed. The cert validity-window paths (expired / not-yet-valid) are not
# unit-tested here: OpenSSL 3.0 `req` cannot backdate a cert (no -not_before/
# -not_after), and the arithmetic is straightforward.

load helpers/common

SCRIPT="certificates/rotate-cert.sh"

# Generate a matching self-signed cert ($1) + key ($2); CN defaults to the
# third arg or "test". Uses the real openssl (not shimmed in these tests).
_gen_pair() {
  local cert="$1" key="$2" cn="${3:-test}"
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${key}" -out "${cert}" -days 365 \
    -subj "/CN=${cn}" > /dev/null 2>&1
}

_fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 2> /dev/null | sed -n 's/^.*=//p'; }

setup() { common_setup; }
teardown() { common_teardown; }

@test "rotate: --help exits 0 and prints Usage" {
  run_script "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "rotate: -h exits 0" {
  run_script "${SCRIPT}" -h
  [ "${status}" -eq 0 ]
}

@test "rotate: missing CERT_SRC exits 2" {
  run env -u CERT_SRC -u KEY_SRC -u CERT_DEST -u KEY_DEST bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"CERT_SRC is required"* ]]
}

@test "rotate: both SERVICE and RELOAD_CMD set exits 2" {
  _gen_pair "${TEST_TMP}/c.crt" "${TEST_TMP}/c.key"
  run env CERT_SRC="${TEST_TMP}/c.crt" KEY_SRC="${TEST_TMP}/c.key" \
    CERT_DEST="${TEST_TMP}/d.crt" KEY_DEST="${TEST_TMP}/d.key" \
    SERVICE=nginx RELOAD_CMD="true" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"only one of SERVICE or RELOAD_CMD"* ]]
}

@test "rotate: unreadable CERT_SRC exits 2" {
  run env CERT_SRC="${TEST_TMP}/nope.crt" KEY_SRC="${TEST_TMP}/nope.key" \
    CERT_DEST="${TEST_TMP}/d.crt" KEY_DEST="${TEST_TMP}/d.key" \
    bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"not readable"* ]]
}

@test "rotate: mismatched cert/key is refused (exit 1)" {
  # certA belongs to keyA; pass keyB instead -> public keys differ -> refuse.
  _gen_pair "${TEST_TMP}/a.crt" "${TEST_TMP}/a.key" a
  _gen_pair "${TEST_TMP}/b.crt" "${TEST_TMP}/b.key" b
  run env CERT_SRC="${TEST_TMP}/a.crt" KEY_SRC="${TEST_TMP}/b.key" \
    CERT_DEST="${TEST_TMP}/d.crt" KEY_DEST="${TEST_TMP}/d.key" \
    SERVICE=nginx bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"do NOT match"* ]]
}

@test "rotate: DRY_RUN validates a matching pair and changes nothing" {
  _gen_pair "${TEST_TMP}/a.crt" "${TEST_TMP}/a.key"
  run env DRY_RUN=1 CERT_SRC="${TEST_TMP}/a.crt" KEY_SRC="${TEST_TMP}/a.key" \
    CERT_DEST="${TEST_TMP}/dest.crt" KEY_DEST="${TEST_TMP}/dest.key" \
    SERVICE=nginx bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"public keys match"* ]]
  [[ "${output}" == *"DRY_RUN=1"* ]]
  # nothing installed
  [ ! -e "${TEST_TMP}/dest.crt" ]
  [ ! -e "${TEST_TMP}/dest.key" ]
}

@test "rotate: already-current destination is a no-op (exit 0)" {
  _gen_pair "${TEST_TMP}/a.crt" "${TEST_TMP}/a.key"
  cp "${TEST_TMP}/a.crt" "${TEST_TMP}/dest.crt" # destination already holds it
  run env CERT_SRC="${TEST_TMP}/a.crt" KEY_SRC="${TEST_TMP}/a.key" \
    CERT_DEST="${TEST_TMP}/dest.crt" KEY_DEST="${TEST_TMP}/dest.key" \
    SERVICE=nginx bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already current"* ]]
}

@test "rotate: installs atomically with a 0600 key and reloads" {
  [[ "${EUID}" -eq 0 ]] || skip "needs root to write the destination and chown"
  _gen_pair "${TEST_TMP}/new.crt" "${TEST_TMP}/new.key" new
  # Pre-existing old pair at the destination so the backup path is exercised.
  _gen_pair "${TEST_TMP}/dest.crt" "${TEST_TMP}/dest.key" old
  make_recording_bin systemctl 0
  run env CERT_SRC="${TEST_TMP}/new.crt" KEY_SRC="${TEST_TMP}/new.key" \
    CERT_DEST="${TEST_TMP}/dest.crt" KEY_DEST="${TEST_TMP}/dest.key" \
    SERVICE=nginx bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"OK: certificate rotated"* ]]
  # destination now holds the NEW cert
  [ "$(_fp "${TEST_TMP}/dest.crt")" = "$(_fp "${TEST_TMP}/new.crt")" ]
  # key installed at 0600
  [ "$(stat -c '%a' "${TEST_TMP}/dest.key")" = "600" ]
  # reload happened, and a timestamped backup was kept
  called_with systemctl "reload nginx"
  ls "${TEST_TMP}"/dest.crt.*.bak > /dev/null 2>&1
}

@test "rotate: a failing reload rolls back to the previous cert (exit 1)" {
  [[ "${EUID}" -eq 0 ]] || skip "needs root to write the destination and chown"
  _gen_pair "${TEST_TMP}/new.crt" "${TEST_TMP}/new.key" new
  _gen_pair "${TEST_TMP}/dest.crt" "${TEST_TMP}/dest.key" old
  local old_fp
  old_fp="$(_fp "${TEST_TMP}/dest.crt")"
  make_fake_bin systemctl 'exit 1' # reload (and the rollback reload) fail
  run env CERT_SRC="${TEST_TMP}/new.crt" KEY_SRC="${TEST_TMP}/new.key" \
    CERT_DEST="${TEST_TMP}/dest.crt" KEY_DEST="${TEST_TMP}/dest.key" \
    SERVICE=nginx bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"rolling back"* ]]
  # destination restored to the OLD cert
  [ "$(_fp "${TEST_TMP}/dest.crt")" = "${old_fp}" ]
}
