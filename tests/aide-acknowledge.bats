#!/usr/bin/env bats
# Tests for recovery/aide-acknowledge.sh
#
# Focus: usage/exit-code contract; H1 — derive the real new-DB path from
# aide.conf (file: prefix, @@{DBDIR}, gzip_dbout's .gz); M5 — capture the
# check and print a parsed summary; H2 — atomic same-dir promote with a
# backup, plus rollback if the promote fails mid-way. A fake `aide` on
# PATH stands in for the real tool. The suite runs as root, satisfying
# the EUID gate.

load helpers/common

SCRIPT="recovery/aide-acknowledge.sh"

# Build a temp aide tree + Debian-style aide.conf (DBDIR macro, file:
# prefix, gzip_dbout). Sets CONF / DBDIR for the test body.
setup_aide_tree() {
  DBDIR="${TEST_TMP}/var/lib/aide"
  mkdir -p "${DBDIR}"
  CONF="${TEST_TMP}/aide.conf"
  {
    echo "@@define DBDIR ${DBDIR}"
    echo "gzip_dbout=yes"
    echo "database_in=file:@@{DBDIR}/aide.db"
    echo "database_out=file:@@{DBDIR}/aide.db.new"
  } > "${CONF}"
  printf 'OLD-BASELINE\n' > "${DBDIR}/aide.db"
  export CONF DBDIR
}

# Fake aide: --check prints an AIDE summary (exit 1 = differences);
# --update writes aide.db.new.gz (simulating gzip_dbout=yes).
install_fake_aide() {
  make_fake_bin aide '
conf=""; mode=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) conf="$2"; shift 2 ;;
    --check) mode=check; shift ;;
    --update) mode=update; shift ;;
    *) shift ;;
  esac
done
dbdir="$(sed -n "s/^@@define DBDIR //p" "$conf")"
if [[ "$mode" == check ]]; then
  printf "AIDE found differences!\nSummary:\n  Added entries:  3\n  Removed entries:  1\n  Changed entries:  7\n"
  exit 1
elif [[ "$mode" == update ]]; then
  printf "NEW-BASELINE\n" | gzip > "$dbdir/aide.db.new.gz"
  exit 0
fi'
}

setup() {
  common_setup
  setup_aide_tree
  install_fake_aide
}
teardown() { common_teardown; }

@test "aide: --help exits 0 and prints Usage" {
  run_script "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage:"* ]]
}

@test "aide: missing aide.conf exits 1" {
  run env AIDE_CONF="/no/such/aide.conf" bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"aide.conf not found"* ]]
}

@test "aide(M5): DRY_RUN runs --check, prints a parsed summary, skips update" {
  run env AIDE_CONF="${CONF}" DRY_RUN=1 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"summary    : added=3 removed=1 changed=7"* ]]
  [[ "${output}" == *"DRY_RUN: skipping"* ]]
  # Live DB untouched.
  run cat "${DBDIR}/aide.db"
  [[ "${output}" == "OLD-BASELINE" ]]
}

@test "aide(H1): derives DB paths from aide.conf and promotes the .gz file" {
  run env AIDE_CONF="${CONF}" FORCE=1 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"aide.db.new.gz"* ]]
  [[ "${output}" == *"done. new baseline"* ]]
  # The live DB now holds the new (gzip) baseline.
  run zcat "${DBDIR}/aide.db"
  [[ "${output}" == "NEW-BASELINE" ]]
  # The produced .new.gz was consumed by the rename.
  [ ! -e "${DBDIR}/aide.db.new.gz" ]
}

@test "aide(H2): keeps a timestamped backup of the previous baseline" {
  run env AIDE_CONF="${CONF}" FORCE=1 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 0 ]
  local bak
  bak="$(echo "${DBDIR}"/aide.db.bak.*)"
  [ -f "${bak}" ]
  run cat "${bak}"
  [[ "${output}" == "OLD-BASELINE" ]]
}

@test "aide(H2): refuses a cross-directory promote (non-atomic)" {
  # Point AIDE_DB_NEW into a different directory than the live DB.
  local other="${TEST_TMP}/other"
  mkdir -p "${other}"
  run env AIDE_CONF="${CONF}" AIDE_DB_NEW="${other}/aide.db.new" FORCE=1 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"different directories"* ]]
}

@test "aide(H2): rolls back the live DB when the promote fails mid-way" {
  # A fake `mv` that truncates the live target then fails, simulating an
  # ENOSPC/cross-fs failure after the backup is taken.
  make_fake_bin mv '
src="${@: -2:1}"; dst="${@: -1:1}"
if [[ "$src" == *aide.db.new* ]]; then
  : > "$dst"            # clobber the live DB, as a half-done mv would
  echo "mv: simulated ENOSPC" >&2
  exit 1
fi
exec /bin/mv "$@"'
  run env AIDE_CONF="${CONF}" FORCE=1 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  # The EXIT trap must have restored the original baseline.
  run cat "${DBDIR}/aide.db"
  [[ "${output}" == "OLD-BASELINE" ]]
}

@test "aide(H1): errors clearly when --update produces no expected DB" {
  # Fake aide whose --update writes nothing.
  make_fake_bin aide '
mode=""
for a in "$@"; do [[ "$a" == "--check" ]] && mode=check; [[ "$a" == "--update" ]] && mode=update; done
if [[ "$mode" == check ]]; then echo "Added entries: 1"; exit 1; fi
exit 0'
  run env AIDE_CONF="${CONF}" FORCE=1 bash "${REPO_ROOT}/${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"expected new database not produced"* ]]
}
