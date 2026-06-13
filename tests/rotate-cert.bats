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

@test "rotate: non-octal KEY_MODE exits 2" {
  _gen_pair "${TEST_TMP}/c.crt" "${TEST_TMP}/c.key"
  run env CERT_SRC="${TEST_TMP}/c.crt" KEY_SRC="${TEST_TMP}/c.key" \
    CERT_DEST="${TEST_TMP}/d.crt" KEY_DEST="${TEST_TMP}/d.key" \
    KEY_MODE=rwx bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"KEY_MODE must be an octal"* ]]
}

@test "rotate: world-accessible KEY_MODE (0644) is refused exits 2" {
  _gen_pair "${TEST_TMP}/c.crt" "${TEST_TMP}/c.key"
  run env CERT_SRC="${TEST_TMP}/c.crt" KEY_SRC="${TEST_TMP}/c.key" \
    CERT_DEST="${TEST_TMP}/d.crt" KEY_DEST="${TEST_TMP}/d.key" \
    KEY_MODE=0644 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"expose the private key to 'other'"* ]]
}

@test "rotate: other-executable KEY_MODE (0601) is refused exits 2" {
  _gen_pair "${TEST_TMP}/c.crt" "${TEST_TMP}/c.key"
  run env CERT_SRC="${TEST_TMP}/c.crt" KEY_SRC="${TEST_TMP}/c.key" \
    CERT_DEST="${TEST_TMP}/d.crt" KEY_DEST="${TEST_TMP}/d.key" \
    KEY_MODE=0601 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"expose the private key to 'other'"* ]]
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

@test "rotate: already-current destination (cert AND key match) is a no-op" {
  _gen_pair "${TEST_TMP}/a.crt" "${TEST_TMP}/a.key"
  cp "${TEST_TMP}/a.crt" "${TEST_TMP}/dest.crt" # destination already holds both
  cp "${TEST_TMP}/a.key" "${TEST_TMP}/dest.key"
  run env CERT_SRC="${TEST_TMP}/a.crt" KEY_SRC="${TEST_TMP}/a.key" \
    CERT_DEST="${TEST_TMP}/dest.crt" KEY_DEST="${TEST_TMP}/dest.key" \
    SERVICE=nginx bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already current"* ]]
}

@test "rotate: same cert but a STALE key at the destination is NOT skipped" {
  # Codex P2: a leaf-only idempotency check would wrongly report "current" when
  # the installed key no longer matches. dest holds certA but the WRONG key.
  [[ "${EUID}" -eq 0 ]] || skip "needs root to write the destination and chown"
  _gen_pair "${TEST_TMP}/a.crt" "${TEST_TMP}/a.key" a
  _gen_pair "${TEST_TMP}/b.crt" "${TEST_TMP}/b.key" b
  cp "${TEST_TMP}/a.crt" "${TEST_TMP}/dest.crt"
  cp "${TEST_TMP}/b.key" "${TEST_TMP}/dest.key" # stale/mismatched key
  make_recording_bin systemctl 0
  run env CERT_SRC="${TEST_TMP}/a.crt" KEY_SRC="${TEST_TMP}/a.key" \
    CERT_DEST="${TEST_TMP}/dest.crt" KEY_DEST="${TEST_TMP}/dest.key" \
    SERVICE=nginx bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"already current"* ]]
  # the key was repaired to the matching one
  cmp -s "${TEST_TMP}/dest.key" "${TEST_TMP}/a.key"
}

@test "rotate: a cert PEM containing a private key is refused (exit 1)" {
  # Codex P1: a combined cert+key PEM as CERT_SRC must not be written to the
  # world-readable cert path.
  _gen_pair "${TEST_TMP}/a.crt" "${TEST_TMP}/a.key"
  cat "${TEST_TMP}/a.crt" "${TEST_TMP}/a.key" > "${TEST_TMP}/combined.pem"
  run env CERT_SRC="${TEST_TMP}/combined.pem" KEY_SRC="${TEST_TMP}/a.key" \
    CERT_DEST="${TEST_TMP}/dest.crt" KEY_DEST="${TEST_TMP}/dest.key" \
    SERVICE=nginx bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"contains a PRIVATE KEY"* ]]
}

@test "rotate: identical CERT_DEST and KEY_DEST is rejected (exit 2)" {
  _gen_pair "${TEST_TMP}/a.crt" "${TEST_TMP}/a.key"
  run env CERT_SRC="${TEST_TMP}/a.crt" KEY_SRC="${TEST_TMP}/a.key" \
    CERT_DEST="${TEST_TMP}/same.pem" KEY_DEST="${TEST_TMP}/same.pem" \
    SERVICE=nginx bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"must be different"* ]]
}

@test "rotate: a directory destination is rejected (exit 2)" {
  _gen_pair "${TEST_TMP}/a.crt" "${TEST_TMP}/a.key"
  mkdir -p "${TEST_TMP}/adir"
  run env CERT_SRC="${TEST_TMP}/a.crt" KEY_SRC="${TEST_TMP}/a.key" \
    CERT_DEST="${TEST_TMP}/adir" KEY_DEST="${TEST_TMP}/dest.key" \
    SERVICE=nginx bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"is a directory"* ]]
}

@test "rotate: a failed FIRST-TIME install rolls back by removing the new files" {
  # Codex P2: with no prior pair to restore, rollback must delete the new files
  # so the prior absence is restored, not left as failed material.
  [[ "${EUID}" -eq 0 ]] || skip "needs root to write the destination and chown"
  _gen_pair "${TEST_TMP}/new.crt" "${TEST_TMP}/new.key" new
  # destination directory is empty — no existing cert/key
  make_fake_bin systemctl 'exit 1' # reload fails
  run env CERT_SRC="${TEST_TMP}/new.crt" KEY_SRC="${TEST_TMP}/new.key" \
    CERT_DEST="${TEST_TMP}/fresh.crt" KEY_DEST="${TEST_TMP}/fresh.key" \
    SERVICE=nginx bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"rolling back"* ]]
  # prior absence restored — neither file remains
  [ ! -e "${TEST_TMP}/fresh.crt" ]
  [ ! -e "${TEST_TMP}/fresh.key" ]
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
