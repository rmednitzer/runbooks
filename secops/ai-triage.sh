#!/usr/bin/env bash
# ai-triage.sh — AI-assisted security-signal triage via LOCAL inference.
#
# Why this exists
#   At 02:00 a host has scattered security signals — auditd auth/account
#   events, fail2ban bans, ufw drops, warning-and-above journal lines — and
#   turning them into "what happened, how bad, what next" is slow manual
#   correlation. This runbook gathers the recent signals and asks a model to
#   triage them into a one-page summary (assessment + severity, correlated
#   events, benign-vs-suspicious reasoning, and concrete next steps for the
#   on-call operator). It is READ-ONLY: it reads logs and queries the model;
#   it changes nothing.
#
# Data sovereignty (why LOCAL inference)
#   The signals are sent to a LOCAL Ollama endpoint (the `ollama` role in
#   automation), so security data never leaves the estate for a third-party
#   AI API — the same POL-004 / GDPR Art 25 stance as the rest of the fleet.
#   Run `DRY_RUN=1` to print exactly what WOULD be sent, and review it, before
#   contacting any endpoint.
#
# Sources (pluggable via SOURCE)
#   host  (default) — local signals on the host this runs on: auditd
#                     (ausearch), fail2ban-client, ufw/kernel drops, journald.
#   siem            — aggregated cross-host alerts from the SIEM. PLANNED /
#                     STUB: prints the intended wiring and exits non-zero.
#
# Requirements (bash >= 4 on GNU/Linux; see CLAUDE.md)
#   - python3 (stdlib only) for the JSON request/response to Ollama.
#   - journalctl (systemd) for the journal/kernel sources.
#   - Optional, used when present: ausearch (auditd), fail2ban-client, ufw.
#   Missing optional tools are noted in the output, not fatal.
#
# Environment variables
#   OLLAMA_ENDPOINT  Local inference base URL, e.g. http://127.0.0.1:11434.
#                    Required to produce a triage; without it the gathered
#                    signals are still printed.
#   OLLAMA_MODEL     Model tag (default: llama3.1:8b).
#   SOURCE           host | siem (default: host).
#   SINCE            Journal/auditd lookback window (default: "1 hour ago").
#   MAX_LINES        Cap of lines kept per source (default: 80).
#   AI_TIMEOUT       Model request timeout, seconds (default: 120).
#   DRY_RUN=1        Gather and print the prompt; do NOT contact the endpoint.
#
# Exit codes
#   0  triage produced, or signals gathered (model absent / DRY_RUN)
#   1  runtime error, or SOURCE=siem (stub) requested
#   2  invalid argument / environment

set -euo pipefail

log() { printf '[ai-triage] %s\n' "$*"; }
warn() { printf '[ai-triage] WARN: %s\n' "$*" >&2; }
err() { printf '[ai-triage] ERR: %s\n' "$*" >&2; }

OLLAMA_ENDPOINT="${OLLAMA_ENDPOINT:-}"
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.1:8b}"
SOURCE="${SOURCE:-host}"
SINCE="${SINCE:-1 hour ago}"
MAX_LINES="${MAX_LINES:-80}"
AI_TIMEOUT="${AI_TIMEOUT:-120}"
DRY_RUN="${DRY_RUN:-0}"
WORK=""

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  cat << 'EOF'

Usage:
  OLLAMA_ENDPOINT=http://127.0.0.1:11434 secops/ai-triage.sh
  DRY_RUN=1 secops/ai-triage.sh                 # show what would be sent
  SINCE="6 hours ago" MAX_LINES=150 secops/ai-triage.sh
EOF
}

cleanup() {
  if [[ -n "${WORK}" && -d "${WORK}" ]]; then
    rm -rf "${WORK}"
  fi
}

# Append a titled section to the signals file; record "(none)" when empty.
add_section() {
  local title="$1" body="$2"
  {
    printf -- '--- %s ---\n' "${title}"
    if [[ -n "${body}" ]]; then
      printf '%s\n\n' "${body}"
    else
      printf '(none)\n\n'
    fi
  } >> "${WORK}/signals.txt"
}

# Run a best-effort, read-only collector. Emits its (capped) stdout; if the
# command exits non-zero, appends a VISIBLE note with the reason — so a
# permission error is surfaced to the operator and the model, never silently
# rendered as "(none)" (which would invite a false-negative triage).
collect() {
  local out rc err_txt
  set +e
  out="$("$@" 2> "${WORK}/collect.err" | tail -n "${MAX_LINES}")"
  rc=$?
  set -e
  printf '%s' "${out}"
  if [[ "${rc}" -ne 0 ]]; then
    err_txt="$(head -n 2 "${WORK}/collect.err" 2> /dev/null | tr '\n' ' ')"
    printf '\n[collector exited %s%s]' "${rc}" "${err_txt:+: ${err_txt}}"
  fi
}

gather_host() {
  local audit_out bans ufw_out journal_out ts_date ts_time mtypes when
  mtypes="USER_LOGIN,USER_AUTH,USER_ACCT,ADD_USER,DEL_USER,USER_CHAUTHTOK,ADD_GROUP,ANOM_ABEND,AVC"
  # ausearch -ts takes SEPARATE [date] [time] arguments; a single
  # "MM/DD/YYYY HH:MM:SS" string is parsed as time-only (the date is dropped).
  # Derive both and pass them separately; fall back to the "recent" keyword if
  # `date -d` can't parse SINCE (e.g. a uutils-date quirk on 26.04).
  ts_date="$(date -d "${SINCE}" '+%m/%d/%Y' 2> /dev/null)" || ts_date=""
  ts_time="$(date -d "${SINCE}" '+%H:%M:%S' 2> /dev/null)" || ts_time=""

  if command -v ausearch > /dev/null 2>&1; then
    if [[ -n "${ts_date}" && -n "${ts_time}" ]]; then
      when="${ts_date} ${ts_time}"
      audit_out="$(collect ausearch -i -ts "${ts_date}" "${ts_time}" -m "${mtypes}")"
    else
      when="recent"
      audit_out="$(collect ausearch -i -ts recent -m "${mtypes}")"
    fi
    add_section "auditd auth/account events (since ${when})" "${audit_out}"
  else
    add_section "auditd auth/account events" "(ausearch not installed)"
  fi

  if command -v fail2ban-client > /dev/null 2>&1; then
    bans="$(fail2ban-client banned 2> /dev/null)" || bans="$(fail2ban-client status 2> /dev/null)" || bans=""
    add_section "fail2ban bans" "${bans}"
  else
    add_section "fail2ban bans" "(fail2ban-client not installed)"
  fi

  ufw_out="$(journalctl -k --since "${SINCE}" --no-pager -q 2> /dev/null | grep -F '[UFW ' | tail -n "${MAX_LINES}")" || ufw_out=""
  add_section "ufw / kernel firewall drops (since ${SINCE})" "${ufw_out}"

  journal_out="$(collect journalctl --since "${SINCE}" -p warning --no-pager -q)"
  add_section "journal: warning and above (since ${SINCE})" "${journal_out}"
}

gather_siem() {
  err "SOURCE=siem is a planned stub, not yet implemented."
  cat >&2 << 'EOF'
[ai-triage] The SIEM path will query aggregated alerts (Wazuh manager API /
[ai-triage] Vector-shipped store) using, e.g., WAZUH_API_URL + a vaulted token,
[ai-triage] then triage them with the same local-inference call. Until then use
[ai-triage] the default host-side source (unset SOURCE or set SOURCE=host).
EOF
  exit 1
}

build_prompt() {
  local host
  host="$(hostname 2> /dev/null)" || host="(unknown)"
  {
    printf 'You are a security operations analyst. Below are recent security '
    printf 'signals from host %s (window: %s). Produce a concise triage:\n' "${host}" "${SINCE}"
    printf '1. One-line overall assessment with a severity (info/low/medium/high).\n'
    printf '2. The notable events, grouped and correlated.\n'
    printf '3. Likely benign vs. suspicious, with brief reasoning.\n'
    printf '4. Concrete next steps for the on-call operator.\n'
    printf 'Be specific to the data below; do NOT invent events. If the signals '
    printf 'are sparse, say so plainly.\n\n'
    printf '=== SIGNALS ===\n'
    cat "${WORK}/signals.txt"
  } > "${WORK}/prompt.txt"
}

run_model() {
  PROMPT_FILE="${WORK}/prompt.txt" \
    OLLAMA_ENDPOINT="${OLLAMA_ENDPOINT}" \
    OLLAMA_MODEL="${OLLAMA_MODEL}" \
    AI_TIMEOUT="${AI_TIMEOUT}" \
    python3 - << 'PY'
import json
import os
import sys
import urllib.error
import urllib.request

endpoint = os.environ["OLLAMA_ENDPOINT"].rstrip("/")
model = os.environ.get("OLLAMA_MODEL", "llama3.1:8b")
try:
    timeout = int(os.environ.get("AI_TIMEOUT", "120"))
except ValueError:
    timeout = 120
with open(os.environ["PROMPT_FILE"], encoding="utf-8") as handle:
    prompt = handle.read()

payload = json.dumps(
    {"model": model, "prompt": prompt, "stream": False, "options": {"temperature": 0}}
).encode("utf-8")
request = urllib.request.Request(
    endpoint + "/api/generate", data=payload, headers={"Content-Type": "application/json"}
)
try:
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = json.loads(response.read())
except (urllib.error.URLError, OSError, ValueError, TimeoutError) as exc:
    sys.stderr.write("%s\n" % exc.__class__.__name__)
    sys.exit(3)

text = (body.get("response") or "").strip()
if not text:
    sys.stderr.write("empty response\n")
    sys.exit(3)
print(text)
PY
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
    "") ;;
    *)
      err "unexpected argument: ${1}"
      usage >&2
      exit 2
      ;;
  esac

  case "${SOURCE}" in
    host | siem) ;;
    *)
      err "SOURCE must be 'host' or 'siem' (got '${SOURCE}')."
      exit 2
      ;;
  esac

  if ! [[ "${MAX_LINES}" =~ ^[1-9][0-9]*$ ]]; then
    err "MAX_LINES must be a positive integer (got '${MAX_LINES}')."
    exit 2
  fi

  if ! command -v python3 > /dev/null 2>&1; then
    err "python3 is required (for the JSON request to the local endpoint)."
    exit 2
  fi

  WORK="$(mktemp -d)"
  : > "${WORK}/signals.txt"

  # Audit/journal reads need privilege; flag partial data up front (and in the
  # prompt) so a quiet result from an unprivileged run isn't read as "all clear".
  if [[ "${EUID}" -ne 0 ]]; then
    warn "running as non-root (uid ${EUID}); auditd/journal/ufw reads may be incomplete."
    printf 'NOTE: gathered as non-root (uid %s) — some sources may be incomplete; treat a quiet result with caution.\n\n' "${EUID}" >> "${WORK}/signals.txt"
  fi

  case "${SOURCE}" in
    siem) gather_siem ;;
    host)
      if ! command -v journalctl > /dev/null 2>&1; then
        err "journalctl is required for the host source."
        exit 2
      fi
      gather_host
      ;;
    *) ;;
  esac

  local host
  host="$(hostname 2> /dev/null)" || host="?"
  log "Security signal triage for ${host} (source: ${SOURCE}, since: ${SINCE})"
  printf '\n=== Gathered signals ===\n'
  cat "${WORK}/signals.txt"

  build_prompt

  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '\n=== Prompt (DRY_RUN — not sent) ===\n'
    cat "${WORK}/prompt.txt"
    log "DRY_RUN=1: prompt printed; the local endpoint was not contacted."
    return 0
  fi

  if [[ -z "${OLLAMA_ENDPOINT}" ]]; then
    warn "OLLAMA_ENDPOINT is unset; showing gathered signals only (no triage)."
    warn "Set OLLAMA_ENDPOINT to a local inference endpoint to enable triage."
    return 0
  fi

  printf '\n=== AI triage (local inference: %s) ===\n' "${OLLAMA_MODEL}"
  local rc=0
  set +e
  run_model > "${WORK}/triage.txt" 2> "${WORK}/triage.err"
  rc=$?
  set -e
  if [[ "${rc}" -eq 0 ]]; then
    cat "${WORK}/triage.txt"
  else
    local errmsg
    errmsg="$(tr -d '\n' < "${WORK}/triage.err")" || errmsg="error"
    warn "local inference unavailable (${errmsg}); showing raw signals only."
  fi
  return 0
}

# Source-guard so the bats suite can source this file to unit-test helpers
# without executing main or installing traps (CLAUDE.md convention).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap 'err "failed at line ${LINENO}"; exit 1' ERR
  trap cleanup EXIT
  main "$@"
fi
