#!/usr/bin/env bats
# Tests for certificates/check-cert-expiry.sh
#
# Focus: argument/usage contract, dependency checks, and that the openssl
# pipeline is wrapped in timeout(1) with NO bogus -connect_timeout option
# (the C1 regression). A recording openssl/timeout stub proves the planned
# command shape without touching the network.

load helpers/common

SCRIPT="certificates/check-cert-expiry.sh"

setup() { common_setup; }
teardown() { common_teardown; }

@test "cert: --help exits 0 and prints Usage" {
  run_script "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "cert: -h exits 0" {
  run_script "${SCRIPT}" -h
  [ "${status}" -eq 0 ]
}

@test "cert: missing HOST exits 2" {
  run env -u HOST bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"HOST is required"* ]]
}

@test "cert: non-numeric PORT exits 2" {
  run env HOST=example.com PORT=abc bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"PORT must be"* ]]
}

@test "cert: out-of-range PORT exits 2" {
  run env HOST=example.com PORT=70000 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
}

@test "cert: CONNECT_TIMEOUT=0 is rejected (timeout 0 means no timeout)" {
  run env HOST=example.com CONNECT_TIMEOUT=0 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"CONNECT_TIMEOUT"* ]]
}

@test "cert: bad THRESHOLD_DAYS exits 2" {
  run env HOST=example.com THRESHOLD_DAYS=-5 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 2 ]
}

@test "cert: missing timeout binary is reported by require_cmd" {
  # Build an isolated PATH dir that has bash + openssl + date + the basic
  # coreutils the script needs, but deliberately NOT `timeout`, so
  # require_cmd fails on it. Symlink real tools so the script otherwise
  # runs normally up to the dependency check.
  local isodir="${TEST_TMP}/isolated"
  mkdir -p "${isodir}"
  local t
  for t in bash openssl date sed cat printf rm mktemp env; do
    local real
    real="$(command -v "${t}" || true)"
    [[ -n "${real}" ]] && ln -sf "${real}" "${isodir}/${t}"
  done
  run env -i HOST=example.com PATH="${isodir}" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"timeout"* ]]
}

@test "cert: wraps openssl in timeout and passes NO -connect_timeout (C1)" {
  # Recording timeout: logs its args (which include the openssl command),
  # then runs a stub openssl that emits a PEM, so the pipeline proceeds.
  cat > "${FAKE_BIN}/timeout" <<EOF
#!/usr/bin/env bash
printf 'timeout %s\n' "\$*" >> "${CALLS_LOG}"
# drop the leading duration arg, exec the rest (our fake openssl)
shift
exec "\$@"
EOF
  chmod +x "${FAKE_BIN}/timeout"

  # Fake openssl: first call is s_client (ignore, emit nothing on stdout
  # for the connection but the script pipes into `openssl x509 -outform
  # PEM`). Emit a valid self-signed PEM for x509 to parse.
  local pem="${TEST_TMP}/leaf.pem"
  _make_self_signed_pem "${pem}"
  cat > "${FAKE_BIN}/openssl" <<EOF
#!/usr/bin/env bash
case "\$1" in
  s_client) cat "${pem}" ;;
  x509)     /usr/bin/openssl "\$@" ;;
  *)        /usr/bin/openssl "\$@" ;;
esac
EOF
  chmod +x "${FAKE_BIN}/openssl"

  run env HOST=example.com PORT=443 THRESHOLD_DAYS=1 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  # timeout was invoked wrapping openssl s_client
  grep -q "timeout 10 openssl s_client" "${CALLS_LOG}"
  # and the forbidden option never appears anywhere in the planned cmd
  ! grep -q -- "-connect_timeout" "${CALLS_LOG}"
  [[ "${output}" == *"days_left"* ]]
}

# Generate a short-lived self-signed leaf PEM for the x509 parser to read.
_make_self_signed_pem() {
  local out="$1"
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /dev/null -out "${out}" -days 365 \
    -subj "/CN=example.com" > /dev/null 2>&1
}
