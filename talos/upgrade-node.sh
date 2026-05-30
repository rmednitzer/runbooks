#!/usr/bin/env bash
# upgrade-node.sh — upgrade ONE Talos node to a target installer image.
#
# Why this exists
#   Talos is an immutable OS: you do not `apt upgrade` a node (there is no
#   SSH, shell, or package manager). You replace the whole system image by
#   pointing the node at a new installer image with `talosctl upgrade
#   --nodes <n> --image <ref>`. The node pulls the image, writes the new
#   Talos to disk, and reboots into it. This script wraps that for ONE node
#   at a time, with a pre-flight health gate so you don't upgrade onto an
#   already-sick cluster, and DRY_RUN so you can preview the exact call.
#
# One node at a time (why this script refuses a node list)
#   Talos itself guards control-plane upgrades by checking etcd quorum and
#   only letting one control-plane node upgrade at a time, and the node
#   cordons+drains itself in Kubernetes before applying. But the safe
#   RUNBOOK is still strictly serial: upgrade one node, wait for the
#   cluster to return to healthy (talos/talos-health-check.sh), then do the
#   next. This script enforces a single NODES value so an operator at 03:00
#   cannot accidentally fan a near-simultaneous upgrade across the fleet.
#
# The image reference and its integrity (IMAGE)
#   IMAGE is a full installer image ref, e.g.
#     ghcr.io/siderolabs/installer:v1.9.5
#   For supply-chain integrity, prefer pinning by DIGEST rather than a
#   mutable tag, e.g.
#     ghcr.io/siderolabs/installer@sha256:<64-hex>
#   The container runtime verifies the layer digests on pull, so a
#   digest-pinned ref is the checksum: the node will refuse an image whose
#   content does not match the digest. The Talos VERSION you are moving to
#   is encoded in the image tag/digest — match it to a real Talos release.
#   This script validates the ref SHAPE (registry/repo + tag or @sha256
#   digest) and WARNS when you pass a mutable tag instead of a digest.
#
# --stage (STAGE)
#   `talosctl upgrade` has NO --preserve flag: Talos preserves the EPHEMERAL
#   partition (pod data, images) across an upgrade by default. --stage writes
#   the upgrade to disk and applies it on the NEXT reboot instead of
#   immediately — useful when the node cannot cleanly drain right now.
#
# Requirements (bash >= 4 on GNU/Linux; see CLAUDE.md)
#   - talosctl on PATH, valid talosconfig (default or TALOSCONFIG).
#   - Network reachability to the node and to the image registry FROM the
#     node (the node pulls the image, not this host).
#   Targets bash >= 4 + GNU coreutils (CLAUDE.md platform note).
#
# Environment variables
#   NODES         The SINGLE node to upgrade (talosctl --nodes; required).
#   IMAGE         Installer image reference (required), e.g.
#                 ghcr.io/siderolabs/installer:v1.9.5 or a @sha256 digest.
#   TALOSCONFIG   Path to talosconfig (talosctl --talosconfig).
#   ENDPOINTS     Endpoint addresses (talosctl --endpoints). Optional.
#   CONTEXT       talosconfig context name. Optional.
#   STAGE         If 1, pass --stage (apply on next reboot, not now).
#   SKIP_HEALTH   If 1, skip the pre-flight `talosctl health` gate (use
#                 only when the cluster is known-degraded on purpose).
#   DRY_RUN       If 1, print the exact upgrade command and exit.
#
# Exit codes
#   0  upgrade command accepted (or DRY_RUN completed)
#   1  runtime error (pre-flight health failed, talosctl upgrade failed, …)
#   2  invalid argument (NODES/IMAGE unset, multiple nodes, bad image ref)

set -euo pipefail

log() { printf '[talos-upgrade] %s\n' "$*"; }
warn() { printf '[talos-upgrade] WARN: %s\n' "$*" >&2; }
err() { printf '[talos-upgrade] ERR: %s\n' "$*" >&2; }

# Uniform failure reporting. No temp files created by this script.
trap 'err "failed at line ${LINENO}"; exit 1' ERR

usage() {
  cat << 'EOF'
Usage: NODES=<node> IMAGE=<installer-ref> [TALOSCONFIG=...] [ENDPOINTS=...] \
       [CONTEXT=...] [STAGE=1] [SKIP_HEALTH=1] [DRY_RUN=1] \
       upgrade-node.sh

Upgrade ONE Talos node to a target installer image via `talosctl upgrade`.
Talos is immutable — there is no apt/SSH; you swap the whole system image.
Pre-flight `talosctl health` runs first unless SKIP_HEALTH=1.

Environment variables:
  NODES         The SINGLE node to upgrade (required; one node only).
  IMAGE         Installer image ref (required), e.g.
                ghcr.io/siderolabs/installer:v1.9.5 or a @sha256 digest.
                Prefer a @sha256 DIGEST for supply-chain integrity.
  TALOSCONFIG   Path to talosconfig (talosctl --talosconfig).
  ENDPOINTS     Endpoint addresses (talosctl --endpoints). Optional.
  CONTEXT       talosconfig context name. Optional.
  STAGE         If 1, pass --stage (apply on next reboot).
  SKIP_HEALTH   If 1, skip the pre-flight health gate.
  DRY_RUN       If 1, print the upgrade command and exit.

Do ONE node, wait for talos/talos-health-check.sh to go green, then the
next. Examples:
  NODES=10.0.0.2 IMAGE=ghcr.io/siderolabs/installer:v1.9.5 DRY_RUN=1 \
    ./upgrade-node.sh
  NODES=10.0.0.2 IMAGE=ghcr.io/siderolabs/installer@sha256:abc... \
    STAGE=1 ./upgrade-node.sh
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

# Validate the installer image reference SHAPE. Accept either:
#   <registry>/<repo>:<tag>            (mutable — warn)
#   <registry>/<repo>@sha256:<64 hex>  (digest-pinned — preferred)
# This is a shape check, not a registry lookup; it catches typos and empty
# refs before they reach talosctl. Returns 0 valid / non-zero invalid, and
# sets IMAGE_IS_DIGEST=1 when the ref is digest-pinned.
IMAGE_IS_DIGEST=0
validate_image_ref() {
  local ref="$1"
  IMAGE_IS_DIGEST=0
  [[ -z "${ref}" ]] && return 1
  # Must contain a repository path (at least one '/') and no whitespace.
  [[ "${ref}" == *[[:space:]]* ]] && return 1
  [[ "${ref}" == */* ]] || return 1
  if [[ "${ref}" =~ @sha256:[0-9a-f]{64}$ ]]; then
    IMAGE_IS_DIGEST=1
    return 0
  fi
  # Tag form: a ':' after the last '/', non-empty tag, no further '/'.
  local last="${ref##*/}"
  if [[ "${last}" == *:* ]]; then
    local tag="${last##*:}"
    [[ -n "${tag}" ]] && return 0
  fi
  return 1
}

# Common talosctl targeting flags.
TALOS_FLAGS=()
build_talos_flags() {
  TALOS_FLAGS=()
  [[ -n "${TALOSCONFIG:-}" ]] && TALOS_FLAGS+=(--talosconfig "${TALOSCONFIG}")
  [[ -n "${CONTEXT:-}" ]] && TALOS_FLAGS+=(--context "${CONTEXT}")
  [[ -n "${ENDPOINTS:-}" ]] && TALOS_FLAGS+=(--endpoints "${ENDPOINTS}")
  [[ -n "${NODES:-}" ]] && TALOS_FLAGS+=(--nodes "${NODES}")
  return 0
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
    *) ;;
  esac

  if [[ -z "${NODES:-}" ]]; then
    err "NODES is required: the SINGLE node to upgrade"
    exit 2
  fi
  if [[ "${NODES}" == *,* ]]; then
    err "NODES must be a SINGLE node — upgrade one at a time (got: ${NODES})"
    exit 2
  fi
  if [[ -z "${IMAGE:-}" ]]; then
    err "IMAGE is required: the installer image reference"
    exit 2
  fi
  # set -e intentionally disabled for this branch test.
  # shellcheck disable=SC2310
  if ! validate_image_ref "${IMAGE}"; then
    err "IMAGE does not look like a valid installer ref: ${IMAGE}"
    err "expected <registry>/<repo>:<tag> or <registry>/<repo>@sha256:<64hex>"
    exit 2
  fi

  require_cmd talosctl
  build_talos_flags

  if [[ "${IMAGE_IS_DIGEST}" -ne 1 ]]; then
    warn "IMAGE uses a mutable tag, not a @sha256 digest."
    warn "prefer a digest-pinned ref so the pull is content-verified."
  fi

  # Assemble the upgrade flags.
  local -a upgrade_args=(upgrade --image "${IMAGE}")
  # `talosctl upgrade` has no --preserve flag: Talos preserves the EPHEMERAL
  # partition (pod data, images) across an upgrade by default. Use --stage to
  # apply on the next reboot instead of immediately.
  if [[ "${STAGE:-0}" == "1" ]]; then
    upgrade_args+=(--stage)
  fi

  local digest_label="NO"
  [[ "${IMAGE_IS_DIGEST}" -eq 1 ]] && digest_label="yes"

  log "node       : ${NODES}  (upgrading ONE node)"
  log "image      : ${IMAGE}"
  log "digest-pin : ${digest_label}"
  log "stage      : ${STAGE:-0}"
  log "command    : talosctl ${TALOS_FLAGS[*]} ${upgrade_args[*]}"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "DRY_RUN: the command above would run. Nothing was sent to the cluster."
    exit 0
  fi

  # Pre-flight: refuse to upgrade onto an already-unhealthy cluster (a new
  # disruption on top of an existing fault is how a node-replacement turns
  # into an outage). --server=false runs the checks client-side.
  if [[ "${SKIP_HEALTH:-0}" != "1" ]]; then
    log "pre-flight: talosctl health --server=false"
    # set -e intentionally disabled for this branch test.
    # shellcheck disable=SC2310
    if ! talosctl "${TALOS_FLAGS[@]}" health --server=false; then
      err "pre-flight health check FAILED — cluster is not healthy"
      err "fix the cluster first, or set SKIP_HEALTH=1 to override deliberately"
      exit 1
    fi
    log "pre-flight: cluster healthy, proceeding"
  else
    warn "SKIP_HEALTH=1: skipping the pre-flight health gate"
  fi

  log "+ talosctl ${upgrade_args[*]}"
  # shellcheck disable=SC2310
  if ! talosctl "${TALOS_FLAGS[@]}" "${upgrade_args[@]}"; then
    err "talosctl upgrade failed"
    err "the node may be mid-upgrade or rebooting; check talos/talos-health-check.sh"
    exit 1
  fi

  log ""
  log "upgrade command accepted for ${NODES}."
  log "the node cordons+drains, writes the new image, and reboots."
  log "WAIT for the cluster to return healthy before the next node:"
  log "  talos/talos-health-check.sh"
}

# Only execute when run directly; sourcing (e.g. from bats) must not run main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
