# Shared bats helpers for the runbooks suite.
#
# Loaded by every *.bats file via `load helpers/common`. Provides:
#   - REPO_ROOT / SCRIPT_DIR path discovery
#   - a per-test PATH shim directory (BATS_TMP/bin) for fake binaries
#   - make_fake_bin / make_recording_bin to stub external tools
#   - assert helpers kept tiny (no bats-assert dependency, to stay
#     self-contained like the scripts themselves)
#
# Conventions mirrored from the scripts: bash >= 4, quote everything.

# Resolve the repository root from this file's location (tests/helpers/).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# Per-test scratch + a PATH shim that fake binaries are written into.
common_setup() {
  TEST_TMP="$(mktemp -d)"
  FAKE_BIN="${TEST_TMP}/bin"
  mkdir -p "${FAKE_BIN}"
  # Record-of-calls file that recording stubs append to.
  CALLS_LOG="${TEST_TMP}/calls.log"
  : > "${CALLS_LOG}"
  # Prepend the shim so fakes win over real tools.
  PATH="${FAKE_BIN}:${PATH}"
  export PATH TEST_TMP FAKE_BIN CALLS_LOG
}

common_teardown() {
  [[ -n "${TEST_TMP:-}" && -d "${TEST_TMP}" ]] && rm -rf "${TEST_TMP}"
  return 0
}

# make_fake_bin <name> <body...>
# Write an executable shim <name> on the shim PATH whose body is the
# remaining arguments (a shell snippet). Always starts with a bash shebang.
make_fake_bin() {
  local name="$1"
  shift
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$*"
  } > "${FAKE_BIN}/${name}"
  chmod +x "${FAKE_BIN}/${name}"
}

# make_recording_bin <name> [exit_code]
# Write a shim that appends "<name> <args>" to CALLS_LOG and exits with
# exit_code (default 0). Use to assert a destructive tool was/ was not
# invoked, and with what arguments.
make_recording_bin() {
  local name="$1"
  local rc="${2:-0}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s %%s\\n" "%s" "$*" >> "%s"\n' "${name}" "${CALLS_LOG}"
    printf 'exit %s\n' "${rc}"
  } > "${FAKE_BIN}/${name}"
  chmod +x "${FAKE_BIN}/${name}"
}

# called_with <name> <substring>
# Succeeds if a recorded invocation OF <name> contains <substring>. Each
# fake binary records "<name> <args>", so restrict the substring search to
# lines that start with "<name> " — otherwise the name on one line and the
# argument on a different command's line would falsely match.
called_with() {
  local name="$1" needle="$2"
  awk -v n="${name}" 'index($0, n " ") == 1' "${CALLS_LOG}" |
    grep -qF -- "${needle}"
}

# not_called <name>
# Succeeds if <name> never recorded a call.
not_called() {
  local name="$1"
  ! grep -qE "^${name} " "${CALLS_LOG}"
}

# run_script <relpath> — run a repo script under `run` with bash.
run_script() {
  local rel="$1"
  shift
  run bash "${REPO_ROOT}/${rel}" "$@"
}

# call_func <relpath> <func> [args...]
# Source a script (which guards `main` behind BASH_SOURCE) in a fresh
# bash, neutralise its inherited `set -e`/ERR trap and its own `run`
# shadow, invoke <func> with the given args, and exit with the function's
# status. Use with bats `run` to unit-test extracted helpers without the
# script's ERR trap firing on an expected non-zero return.
call_func() {
  local rel="$1" func="$2"
  shift 2
  run bash -c '
    set +e
    source "$1"
    trap - ERR
    "$2" "${@:3}"
  ' _ "${REPO_ROOT}/${rel}" "${func}" "$@"
}
