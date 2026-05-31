#!/usr/bin/env bash
# rotate-cert.sh — safely replace a TLS certificate + private key on a host.
#
# Why this exists
#   Renewing a certificate that ACME automation does not cover (an internal
#   CA, a legacy service, an appliance) is a fiddly, error-prone manual job at
#   the worst possible time — usually minutes before, or just after, expiry.
#   The classic foot-guns are: installing a cert whose key does NOT match (the
#   service then serves a broken handshake), clobbering the only copy of the
#   old pair with no way back, getting file permissions wrong on the private
#   key, or reloading a service whose config no longer parses. This runbook
#   does the safe sequence for you: it VALIDATES the new pair before touching
#   anything, BACKS UP the current pair, installs atomically with correct
#   ownership/mode, optionally tests the service config, RELOADS, and ROLLS
#   BACK automatically if the reload fails. DRY_RUN=1 prints the exact plan.
#
# What it validates BEFORE writing anything
#   - the new cert and key parse, and their public keys MATCH (RSA/EC/Ed25519);
#   - the new cert is within its validity window (refuses an already-expired
#     cert; warns on a not-yet-valid one — clock skew / early staging);
#   - optionally, that the new cert chains to a trusted bundle (CA_BUNDLE).
#   If the destination already holds this exact certificate (same SHA-256
#   fingerprint) it reports "already current" and exits 0 — safe to re-run.
#
# Requirements (bash >= 4 on GNU/Linux; see CLAUDE.md)
#   - openssl (cert/key parsing and the public-key match)
#   - GNU date -d (validity-window arithmetic)
#   - coreutils (mktemp, install, mv, cp); the key is written before the cert
#     and both go in atomically (temp-in-dest-dir + rename on the same fs).
#   Writes under /etc — must run as root unless DRY_RUN=1.
#
# Environment variables
#   CERT_SRC        New leaf certificate, PEM (required).
#   KEY_SRC         New private key, PEM, UNENCRYPTED (required).
#   CERT_DEST       Where the cert is installed (required).
#   KEY_DEST        Where the key is installed (required).
#   CHAIN_SRC       Intermediate/chain PEM; if set, CERT_DEST is written as the
#                   leaf followed by this chain (a "fullchain").
#   CA_BUNDLE       If set, `openssl verify` must succeed against it (with
#                   CHAIN_SRC as untrusted intermediates) or the rotation aborts.
#   SERVICE         systemd unit to `systemctl reload` after install.
#   RELOAD_CMD      Advanced: shell command to reload instead of SERVICE
#                   (run via `bash -c`). Exactly one of SERVICE / RELOAD_CMD
#                   triggers a reload; with neither, the files are installed and
#                   a reminder to reload by hand is printed.
#   RELOAD_TEST_CMD Optional config test run AFTER install, BEFORE reload (e.g.
#                   "nginx -t"); a non-zero exit triggers rollback.
#   VERIFY_ENDPOINT host:port to connect to after reload; the served leaf's
#                   fingerprint is compared to the new cert (mismatch warns).
#   CERT_MODE       Cert file mode (default 0644).
#   KEY_MODE        Key file mode (default 0600).
#   OWNER           Owner for both files (default root).
#   GROUP           Group for both files (default root).
#   CONNECT_TIMEOUT Seconds to bound the VERIFY_ENDPOINT openssl call (default 10).
#   DRY_RUN=1       Validate and print the plan; change nothing.
#
# Exit codes
#   0  rotation applied (or already current, or DRY_RUN plan printed)
#   1  runtime error (validation failed, reload failed → rolled back, …)
#   2  invalid argument / environment

set -euo pipefail

log() { printf '[rotate-cert] %s\n' "$*"; }
warn() { printf '[rotate-cert] WARN: %s\n' "$*" >&2; }
err() { printf '[rotate-cert] ERR: %s\n' "$*" >&2; }

# Temp files created in the destination directories for the atomic install;
# cleaned up on any exit (a successful `mv` consumes them, so cleanup only
# bites on an error path).
TMP_CERT=""
TMP_KEY=""
cleanup() {
  [[ -n "${TMP_CERT}" && -f "${TMP_CERT}" ]] && rm -f -- "${TMP_CERT}"
  [[ -n "${TMP_KEY}" && -f "${TMP_KEY}" ]] && rm -f -- "${TMP_KEY}"
  return 0
}
trap 'cleanup' EXIT
trap 'err "failed at line ${LINENO}"; exit 1' ERR

usage() {
  cat << 'EOF'
Usage:
  CERT_SRC=new.crt KEY_SRC=new.key CERT_DEST=/etc/ssl/certs/svc.crt \
    KEY_DEST=/etc/ssl/private/svc.key SERVICE=nginx rotate-cert.sh

Safely replace a TLS certificate + private key: validate the new pair (public
keys must match; cert must be in its validity window), back up the current
pair, install atomically with correct ownership/mode, optionally test the
service config, reload, and roll back automatically if the reload fails.

Key environment variables (full list in the script header):
  CERT_SRC, KEY_SRC      New cert and (unencrypted) key, PEM (required).
  CERT_DEST, KEY_DEST    Install destinations (required).
  CHAIN_SRC              Append this chain after the leaf (fullchain).
  CA_BUNDLE              Require `openssl verify` against this bundle.
  SERVICE / RELOAD_CMD   How to reload the consumer after install.
  RELOAD_TEST_CMD        Config test before reload (rollback on failure).
  VERIFY_ENDPOINT        host:port to confirm the new cert is being served.
  CERT_MODE/KEY_MODE/OWNER/GROUP   File perms (default 0644/0600/root/root).
  DRY_RUN=1              Validate and print the plan; change nothing.

Examples:
  DRY_RUN=1 CERT_SRC=new.crt KEY_SRC=new.key \
    CERT_DEST=/etc/ssl/certs/svc.crt KEY_DEST=/etc/ssl/private/svc.key \
    SERVICE=nginx ./rotate-cert.sh
  CERT_SRC=fullchain.pem KEY_SRC=privkey.pem CHAIN_SRC=chain.pem \
    CERT_DEST=/etc/haproxy/svc.pem KEY_DEST=/etc/haproxy/svc.key \
    RELOAD_CMD='systemctl reload haproxy' VERIFY_ENDPOINT=localhost:443 \
    ./rotate-cert.sh
EOF
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" > /dev/null 2>&1; then
      err "required command not found: ${cmd}"
      exit 1
    fi
  done
}

# SHA-256 fingerprint of a PEM certificate file (lowercase hex, no colons).
cert_fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 2> /dev/null |
    sed -n 's/^.*=//p' | tr -d ':' | tr '[:upper:]' '[:lower:]'
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

  local cert_src="${CERT_SRC:-}" key_src="${KEY_SRC:-}"
  local cert_dest="${CERT_DEST:-}" key_dest="${KEY_DEST:-}"
  local chain_src="${CHAIN_SRC:-}" ca_bundle="${CA_BUNDLE:-}"
  local service="${SERVICE:-}" reload_cmd="${RELOAD_CMD:-}"
  local reload_test_cmd="${RELOAD_TEST_CMD:-}" verify_endpoint="${VERIFY_ENDPOINT:-}"
  local cert_mode="${CERT_MODE:-0644}" key_mode="${KEY_MODE:-0600}"
  local owner="${OWNER:-root}" group="${GROUP:-root}"
  local timeout_s="${CONNECT_TIMEOUT:-10}"
  local dry_run="${DRY_RUN:-0}"

  local v
  for v in CERT_SRC KEY_SRC CERT_DEST KEY_DEST; do
    # ${!v:-} (not ${!v}) so an UNSET required var is reported cleanly rather
    # than tripping `set -u` (which would fire the ERR trap and exit 1).
    if [[ -z "${!v:-}" ]]; then
      err "${v} is required (use --help for usage)"
      exit 2
    fi
  done
  if [[ -n "${service}" && -n "${reload_cmd}" ]]; then
    err "set only one of SERVICE or RELOAD_CMD, not both"
    exit 2
  fi

  require_cmd openssl date mktemp install mv cp
  if [[ ! -r "${cert_src}" ]]; then
    err "CERT_SRC not readable: ${cert_src}"
    exit 2
  fi
  if [[ ! -r "${key_src}" ]]; then
    err "KEY_SRC not readable: ${key_src}"
    exit 2
  fi
  if [[ -n "${chain_src}" && ! -r "${chain_src}" ]]; then
    err "CHAIN_SRC not readable: ${chain_src}"
    exit 2
  fi

  # --- Validate the new pair BEFORE touching the live files -----------------

  # Cert and key must parse.
  if ! openssl x509 -in "${cert_src}" -noout > /dev/null 2>&1; then
    err "CERT_SRC is not a valid PEM certificate: ${cert_src}"
    exit 1
  fi
  # `openssl pkey -pubout` derives the public key and works for RSA/EC/Ed25519,
  # unlike the RSA-only `-modulus`. A failure here usually means the key is
  # encrypted (this runbook needs the unencrypted key a service would load).
  local key_pub
  if ! key_pub="$(openssl pkey -in "${key_src}" -pubout 2> /dev/null)"; then
    err "KEY_SRC is not a readable unencrypted private key: ${key_src}"
    exit 1
  fi
  local cert_pub
  cert_pub="$(openssl x509 -in "${cert_src}" -noout -pubkey 2> /dev/null || true)"
  if [[ -z "${cert_pub}" || "${cert_pub}" != "${key_pub}" ]]; then
    err "CERT_SRC and KEY_SRC do NOT match (public keys differ) — refusing to install a broken pair"
    exit 1
  fi
  log "pair check : cert and key public keys match"

  # Validity window. Refuse an already-expired cert; warn (don't refuse) on a
  # not-yet-valid one so an operator staging ahead of a cutover can still see
  # the plan and decide.
  local not_before not_after now_epoch nb_epoch na_epoch
  not_before="$(openssl x509 -in "${cert_src}" -noout -startdate 2> /dev/null | sed -n 's/^notBefore=//p')"
  not_after="$(openssl x509 -in "${cert_src}" -noout -enddate 2> /dev/null | sed -n 's/^notAfter=//p')"
  now_epoch="$(date +%s)"
  if [[ -n "${not_after}" ]] && na_epoch="$(date -d "${not_after}" +%s 2> /dev/null)"; then
    if ((now_epoch > na_epoch)); then
      err "new certificate is ALREADY EXPIRED (notAfter ${not_after}) — refusing"
      exit 1
    fi
  fi
  if [[ -n "${not_before}" ]] && nb_epoch="$(date -d "${not_before}" +%s 2> /dev/null)"; then
    if ((now_epoch < nb_epoch)); then
      warn "new certificate is NOT YET VALID (notBefore ${not_before}); check clock skew / staging"
    fi
  fi
  log "validity   : notBefore=${not_before:-?}  notAfter=${not_after:-?}"

  # Optional chain verification.
  if [[ -n "${ca_bundle}" ]]; then
    if [[ ! -r "${ca_bundle}" ]]; then
      err "CA_BUNDLE not readable: ${ca_bundle}"
      exit 2
    fi
    local verify_args=(-CAfile "${ca_bundle}")
    [[ -n "${chain_src}" ]] && verify_args+=(-untrusted "${chain_src}")
    if ! openssl verify "${verify_args[@]}" "${cert_src}" > /dev/null 2>&1; then
      err "new certificate does NOT verify against CA_BUNDLE=${ca_bundle} — refusing"
      exit 1
    fi
    log "chain      : verifies against ${ca_bundle}"
  fi

  # Idempotency: if the destination already holds this exact cert, do nothing.
  if [[ -f "${cert_dest}" ]]; then
    local new_fp cur_fp
    new_fp="$(cert_fingerprint "${cert_src}")"
    cur_fp="$(cert_fingerprint "${cert_dest}")"
    if [[ -n "${new_fp}" && "${new_fp}" == "${cur_fp}" ]]; then
      log "already current: ${cert_dest} already holds this certificate (sha256 ${new_fp:0:16}…)"
      exit 0
    fi
  fi

  # --- Decide how the reload will happen ------------------------------------
  local reload_desc="(none — reload the service by hand)"
  if [[ -n "${service}" ]]; then
    reload_desc="systemctl reload ${service}"
  elif [[ -n "${reload_cmd}" ]]; then
    reload_desc="${reload_cmd}"
  fi

  log "plan:"
  log "  cert  ${cert_src}${chain_src:+ (+ chain ${chain_src})} -> ${cert_dest}  (${owner}:${group} ${cert_mode})"
  log "  key   ${key_src} -> ${key_dest}  (${owner}:${group} ${key_mode})"
  [[ -n "${reload_test_cmd}" ]] && log "  test  ${reload_test_cmd}"
  log "  reload ${reload_desc}"
  [[ -n "${verify_endpoint}" ]] && log "  verify served cert at ${verify_endpoint}"

  if [[ "${dry_run}" == "1" ]]; then
    log "DRY_RUN=1: validated only; nothing was changed."
    exit 0
  fi

  if [[ "${EUID}" -ne 0 ]]; then
    err "must run as root to write ${cert_dest} / ${key_dest} (or use DRY_RUN=1)"
    exit 2
  fi

  local cert_dir key_dir
  cert_dir="$(dirname -- "${cert_dest}")"
  key_dir="$(dirname -- "${key_dest}")"
  if [[ ! -d "${cert_dir}" ]]; then
    err "destination directory does not exist: ${cert_dir}"
    exit 2
  fi
  if [[ ! -d "${key_dir}" ]]; then
    err "destination directory does not exist: ${key_dir}"
    exit 2
  fi

  # --- Back up the current pair (timestamped) -------------------------------
  local ts backup_cert="" backup_key=""
  ts="$(date +%Y%m%d-%H%M%S)"
  if [[ -f "${cert_dest}" ]]; then
    backup_cert="${cert_dest}.${ts}.bak"
    cp -a -- "${cert_dest}" "${backup_cert}"
    log "backed up ${cert_dest} -> ${backup_cert}"
  fi
  if [[ -f "${key_dest}" ]]; then
    backup_key="${key_dest}.${ts}.bak"
    cp -a -- "${key_dest}" "${backup_key}"
    log "backed up ${key_dest} -> ${backup_key}"
  fi

  # Restore the backups over the live files and (best-effort) reload. Used on
  # any failure after the new files are in place.
  rollback() {
    warn "rolling back to the previous certificate/key"
    if [[ -n "${backup_cert}" ]]; then
      mv -f -- "${backup_cert}" "${cert_dest}" 2> /dev/null || true
    fi
    if [[ -n "${backup_key}" ]]; then
      mv -f -- "${backup_key}" "${key_dest}" 2> /dev/null || true
    fi
    if [[ -n "${service}" ]]; then
      systemctl reload "${service}" 2> /dev/null || systemctl restart "${service}" 2> /dev/null || true
    elif [[ -n "${reload_cmd}" ]]; then
      bash -c "${reload_cmd}" 2> /dev/null || true
    fi
  }

  # --- Atomic install -------------------------------------------------------
  # Write to a temp file in the SAME directory, set ownership/mode, then rename
  # (atomic on the same filesystem) so a reader never sees a half-written file.
  TMP_KEY="$(mktemp "${key_dir}/.rotate-cert-key.XXXXXX")"
  cat -- "${key_src}" > "${TMP_KEY}"
  chmod "${key_mode}" "${TMP_KEY}"
  chown "${owner}:${group}" "${TMP_KEY}"

  TMP_CERT="$(mktemp "${cert_dir}/.rotate-cert-crt.XXXXXX")"
  if [[ -n "${chain_src}" ]]; then
    cat -- "${cert_src}" "${chain_src}" > "${TMP_CERT}"
  else
    cat -- "${cert_src}" > "${TMP_CERT}"
  fi
  chmod "${cert_mode}" "${TMP_CERT}"
  chown "${owner}:${group}" "${TMP_CERT}"

  # Install the key first, then the cert. `mv` consumes the temp files.
  mv -f -- "${TMP_KEY}" "${key_dest}"
  TMP_KEY=""
  mv -f -- "${TMP_CERT}" "${cert_dest}"
  TMP_CERT=""
  log "installed new certificate and key"

  # --- Optional pre-reload config test --------------------------------------
  if [[ -n "${reload_test_cmd}" ]]; then
    log "config test: ${reload_test_cmd}"
    if ! bash -c "${reload_test_cmd}"; then
      err "config test failed; rolling back"
      rollback
      exit 1
    fi
  fi

  # --- Reload (with rollback on failure) ------------------------------------
  if [[ -n "${service}" ]]; then
    if ! systemctl reload "${service}"; then
      err "systemctl reload ${service} failed; rolling back"
      rollback
      exit 1
    fi
    log "reloaded ${service}"
  elif [[ -n "${reload_cmd}" ]]; then
    if ! bash -c "${reload_cmd}"; then
      err "reload command failed; rolling back"
      rollback
      exit 1
    fi
    log "reload command succeeded"
  else
    warn "no SERVICE / RELOAD_CMD given — reload the consuming service by hand to pick up the new cert"
  fi

  # --- Optional: confirm the new cert is actually being served --------------
  if [[ -n "${verify_endpoint}" ]]; then
    if ! [[ "${timeout_s}" =~ ^[0-9]+$ ]] || ((timeout_s < 1)); then
      warn "CONNECT_TIMEOUT invalid (${timeout_s}); skipping served-cert verification"
    elif ! command -v timeout > /dev/null 2>&1; then
      warn "coreutils timeout not found; skipping served-cert verification"
    else
      local served_fp new_fp host_port
      host_port="${verify_endpoint}"
      new_fp="$(cert_fingerprint "${cert_src}")"
      # set -e off: a failed probe is a warning, not a fatal error — the cert
      # is already installed and reloaded successfully at this point.
      # shellcheck disable=SC2312
      served_fp="$(timeout "${timeout_s}" openssl s_client -connect "${host_port}" \
        -servername "${host_port%%:*}" < /dev/null 2> /dev/null |
        openssl x509 -noout -fingerprint -sha256 2> /dev/null |
        sed -n 's/^.*=//p' | tr -d ':' | tr '[:upper:]' '[:lower:]')" || served_fp=""
      if [[ -z "${served_fp}" ]]; then
        warn "could not read the served certificate at ${host_port} to verify"
      elif [[ "${served_fp}" == "${new_fp}" ]]; then
        log "verified: ${host_port} is serving the new certificate"
      else
        warn "served cert at ${host_port} does NOT match the new cert" \
          "(served ${served_fp:0:16}…, expected ${new_fp:0:16}…) — the service may need a full restart"
      fi
    fi
  fi

  log "OK: certificate rotated"
}

# Only execute when run directly; sourcing (e.g. from bats) must not run main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
