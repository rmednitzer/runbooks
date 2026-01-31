#!/usr/bin/env bash
# ==============================================================================
# Installs a minimal, high-leverage SRE/Platform/Sec toolchain to /usr/local/bin.
#
# Idempotent by default: will not overwrite existing binaries unless FORCE=1.
# Uses GitHub API; set GITHUB_TOKEN to avoid rate limits.
#
# Requires: curl jq tar unzip sha256sum
# Optional (for some archives): xz
# ==============================================================================

set -euo pipefail

# ----- Config -----
DEST_DIR="${DEST_DIR:-/usr/local/bin}"
FORCE="${FORCE:-0}"
DRY_RUN="${DRY_RUN:-0}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
TMP_BASE="${TMP_BASE:-/var/tmp/minimal-sre-lab-installer}"

OS="linux"
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "FATAL: Unsupported arch: $ARCH_RAW" >&2; exit 1 ;;
esac

arch_rx() {
  case "$ARCH" in
    amd64) echo '(amd64|x86_64|x64)' ;;
    arm64) echo '(arm64|aarch64)' ;;
    *) echo '(amd64|x86_64|x64|arm64|aarch64)' ;;
  esac
}

log() { printf "[%s] %s\n" "$(date +'%H:%M:%S')" "$*"; }
err() { printf "[%s] ERROR: %s\n" "$(date +'%H:%M:%S')" "$*" >&2; }

for cmd in curl jq tar unzip sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || { err "Missing dependency: $cmd"; exit 1; }
done

mkdir -p "$TMP_BASE"
chmod 700 "$TMP_BASE" 2>/dev/null || true
TMP_DIR="$(mktemp -d -p "$TMP_BASE" minimal-sre.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

CURL_ARGS=(-fLsS --retry 3 --retry-delay 1 --connect-timeout 10 --proto '=https' --tlsv1.2
  -H "Accept: application/vnd.github+json"
  -H "User-Agent: minimal-sre-lab-installer"
)
[[ -n "$GITHUB_TOKEN" ]] && CURL_ARGS+=(-H "Authorization: Bearer $GITHUB_TOKEN")

need_sudo=0
[[ -w "$DEST_DIR" ]] || need_sudo=1

install_file() {
  local src="$1" dst="$2"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY_RUN: install $src -> $dst"
    return 0
  fi
  chmod +x "$src" 2>/dev/null || true
  if [[ "$need_sudo" -eq 1 ]]; then
    sudo install -m 0755 "$src" "$dst"
  else
    install -m 0755 "$src" "$dst"
  fi
}

download_asset() {
  local url="$1" out="$2"
  curl "${CURL_ARGS[@]}" "$url" -o "$out"
}

extract_archive() {
  local archive="$1" outdir="$2"
  mkdir -p "$outdir"
  case "$archive" in
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$outdir" ;;
    *.tar.xz)       tar -xJf "$archive" -C "$outdir" ;;
    *.zip)          unzip -q "$archive" -d "$outdir" ;;
    *) err "Unknown archive type: $archive"; return 1 ;;
  esac
}

get_release_json() {
  local repo="$1"
  curl -s "${CURL_ARGS[@]}" "https://api.github.com/repos/${repo}/releases/latest"
}

select_asset() {
  # Prints: "<name>\t<url>" (first match)
  local release_json="$1" regex="$2"
  echo "$release_json" | jq -r --arg rx "$regex" '
    .assets[]?
    | select(.name | test($rx; "i"))
    | "\(.name)\t\(.browser_download_url)"
  ' | head -n1
}

select_assets() {
  # Prints multiple lines: "<name>\t<url>"
  local release_json="$1" regex="$2"
  echo "$release_json" | jq -r --arg rx "$regex" '
    .assets[]?
    | select(.name | test($rx; "i"))
    | "\(.name)\t\(.browser_download_url)"
  '
}

verify_sha256_if_possible() {
  # Best-effort verification:
  # 1) Prefer exact per-asset checksum files: <asset>.sha256 or <asset>.sha256sum
  # 2) Else try common checksum bundle assets and grep for the asset line
  #    - skips signatures/certs (*.pem, *.sig, *.asc)
  #    - tries ALL candidates until one matches
  local release_json="$1" asset_name="$2" file="$3"

  local sel checksum_name checksum_url checksum_file expected actual

  _read_expected_hash() {
    local f="$1" a="$2"
    local h

    # If the file contains an entry mentioning the asset, use that.
    h="$(grep -E "([[:space:]]|^)(\\*|)?${a}([[:space:]]|$)" "$f" 2>/dev/null | head -n1 | awk '{print $1}')"
    if [[ -n "$h" ]]; then
      echo "$h"
      return 0
    fi

    # Some bundles list paths; try ends-with match
    h="$(grep -E "([[:space:]]|^).*/${a}([[:space:]]|$)" "$f" 2>/dev/null | head -n1 | awk '{print $1}')"
    if [[ -n "$h" ]]; then
      echo "$h"
      return 0
    fi

    # Otherwise, if first token looks like a sha256, accept it (per-asset checksum files often do this).
    h="$(head -n1 "$f" | awk '{print $1}')"
    if [[ "$h" =~ ^[A-Fa-f0-9]{64}$ ]]; then
      echo "$h"
      return 0
    fi

    return 1
  }

  # 1) Exact per-asset checksum assets (sha256 or sha256sum)
  sel="$(select_asset "$release_json" "^${asset_name//./\\.}\\.(sha256|sha256sum)$" || true)"
  if [[ -n "$sel" ]]; then
    checksum_name="$(cut -f1 <<<"$sel")"
    checksum_url="$(cut -f2 <<<"$sel")"
    checksum_file="${TMP_DIR}/${checksum_name}"
    log "CHECK: checksum asset ${checksum_name}"
    download_asset "$checksum_url" "$checksum_file"

    expected="$(_read_expected_hash "$checksum_file" "$asset_name" || true)"
    [[ -n "$expected" ]] || { err "Could not parse checksum from ${checksum_name}"; return 1; }

    actual="$(sha256sum "$file" | awk '{print $1}')"
    [[ "$expected" == "$actual" ]] || { err "SHA256 mismatch for ${asset_name}"; return 1; }
    log "OK: sha256 verified for ${asset_name}"
    return 0
  fi

  # 2) Bundle checksum assets: skip signature/cert artifacts; try all candidates
  local patterns=(
    "(?i)${OS}.*${ARCH}.*(sha256|sum|checks)"
    "(?i)${ARCH}.*${OS}.*(sha256|sum|checks)"
    "(?i)(sha256sums|SHA256SUMS|checksums).*(txt)?$"
    "(?i)sha256.*(sum|checks).*"
  )

  local any_candidate=0
  for rx in "${patterns[@]}"; do
    while IFS=$'\t' read -r checksum_name checksum_url; do
      [[ -z "${checksum_name:-}" ]] && continue

      # Skip signatures/certs or other non-parseable checksum accompaniments
      if [[ "$checksum_name" =~ \.(pem|sig|asc)$ ]]; then
        continue
      fi

      any_candidate=1
      checksum_file="${TMP_DIR}/${checksum_name}"
      log "CHECK: checksum bundle ${checksum_name}"
      download_asset "$checksum_url" "$checksum_file"

      expected="$(_read_expected_hash "$checksum_file" "$asset_name" || true)"
      if [[ -z "$expected" ]]; then
        # Not the right file for this asset; try next candidate rather than failing immediately.
        continue
      fi

      actual="$(sha256sum "$file" | awk '{print $1}')"
      [[ "$expected" == "$actual" ]] || { err "SHA256 mismatch for ${asset_name} (bundle)"; return 1; }
      log "OK: sha256 verified for ${asset_name} (bundle)"
      return 0
    done < <(select_assets "$release_json" "$rx" || true)
  done

  if [[ "$any_candidate" -eq 1 ]]; then
    err "Checksum assets found but none contained an entry for ${asset_name}"
    return 1
  fi

  log "INFO: No checksum asset/bundle found for ${asset_name}; skipping sha256 verification."
}

install_gh() {
  # install_gh <repo> <bin> <asset_name_regex> <type:binary|archive> [path_in_archive]
  local repo="$1" bin="$2" rx="$3" type="$4" arc_path="${5:-}"
  local target="${DEST_DIR}/${bin}"

  if [[ "$FORCE" -eq 0 && -x "$target" ]]; then
    log "SKIP: ${bin} already exists."
    return 0
  fi

  local rj tag sel asset_name url
  rj="$(get_release_json "$repo")"
  tag="$(echo "$rj" | jq -r '.tag_name // empty')"
  [[ -n "$tag" && "$tag" != "null" ]] || { err "Cannot resolve tag for ${repo} (rate limit/auth?)"; return 1; }

  sel="$(select_asset "$rj" "$rx" || true)"
  [[ -n "$sel" ]] || { err "No asset matched for ${repo} regex=${rx}"; return 1; }
  asset_name="$(cut -f1 <<<"$sel")"
  url="$(cut -f2 <<<"$sel")"

  log "INSTALL: ${bin} @ ${tag}  asset=${asset_name}"
  if [[ "$DRY_RUN" -eq 1 ]]; then return 0; fi

  local dl="${TMP_DIR}/${asset_name}"
  download_asset "$url" "$dl"
  verify_sha256_if_possible "$rj" "$asset_name" "$dl" || return 1

  if [[ "$type" == "binary" ]]; then
    install_file "$dl" "$target"
  else
    local ext="${TMP_DIR}/${bin}_ext"
    mkdir -p "$ext"
    extract_archive "$dl" "$ext"

    local src=""
    if [[ -n "$arc_path" ]]; then
      src="${ext}/${arc_path}"
    else
      src="$(find "$ext" -type f -name "$bin" | head -n1 || true)"
    fi
    [[ -f "$src" ]] || { err "Binary ${bin} not found in archive for ${repo}"; return 1; }
    install_file "$src" "$target"
  fi
}

log "Target install dir: ${DEST_DIR} | arch=${ARCH} | FORCE=${FORCE} | DRY_RUN=${DRY_RUN}"
[[ -n "$GITHUB_TOKEN" ]] || log "TIP: export GITHUB_TOKEN to avoid GitHub API rate limits."

ARX="$(arch_rx)"

# --- Platform / K8s core ---
install_gh "kubernetes-sigs/kind"      "kind"      "^kind-${OS}-${ARCH}$"                     "binary"
install_gh "kubernetes-sigs/kustomize" "kustomize" "^kustomize_v.*_${OS}_${ARCH}\\.tar\\.gz$" "archive"
install_gh "stern/stern"               "stern"     "^stern_.*_${OS}_${ARCH}\\.tar\\.gz$"      "archive"

# kubectx/kubens: source tarball (scripts) is the most reliable
if [[ "$FORCE" -eq 0 && -x "${DEST_DIR}/kubectx" && -x "${DEST_DIR}/kubens" ]]; then
  log "SKIP: kubectx/kubens already exists."
else
  log "INSTALL: kubectx/kubens (source archive)"
  rj="$(get_release_json "ahmetb/kubectx")"
  tag="$(echo "$rj" | jq -r '.tag_name // empty')"
  [[ -n "$tag" && "$tag" != "null" ]] || { err "Cannot resolve tag for ahmetb/kubectx"; exit 1; }

  src_tgz="${TMP_DIR}/kubectx-src.tgz"
  download_asset "https://github.com/ahmetb/kubectx/archive/refs/tags/${tag}.tar.gz" "$src_tgz"

  ext="${TMP_DIR}/kubectx-src"
  mkdir -p "$ext"
  extract_archive "$src_tgz" "$ext"

  base="${ext}/kubectx-${tag#v}"
  [[ -f "${base}/kubectx" && -f "${base}/kubens" ]] || { err "kubectx/kubens not found in source"; exit 1; }
  install_file "${base}/kubectx" "${DEST_DIR}/kubectx"
  install_file "${base}/kubens"  "${DEST_DIR}/kubens"
fi

# --- GitOps (minimal: Flux CLI) ---
install_gh "fluxcd/flux2" "flux" "^flux_.*_${OS}_${ARCH}\\.tar\\.gz$" "archive"

# --- Supply-chain / security minimum ---
# trivy uses Linux-64bit / Linux-ARM64
TRIVY_FLAVOR="Linux-64bit"; [[ "$ARCH" == "arm64" ]] && TRIVY_FLAVOR="Linux-ARM64"
install_gh "aquasecurity/trivy" "trivy" "^trivy_.*_${TRIVY_FLAVOR}\\.tar\\.gz$" "archive"

install_gh "anchore/syft"    "syft"   "^syft_.*_${OS}_${ARCH}\\.tar\\.gz$" "archive"
install_gh "sigstore/cosign" "cosign" "^cosign-${OS}-${ARCH}$"            "binary"
install_gh "getsops/sops"    "sops"   "^sops-.*\\.${OS}\\.${ARCH}$"        "binary"

# age + age-keygen
if [[ "$FORCE" -eq 0 && -x "${DEST_DIR}/age" && -x "${DEST_DIR}/age-keygen" ]]; then
  log "SKIP: age/age-keygen already exists."
else
  install_gh "FiloSottile/age" "age" "^age-.*-${OS}-${ARX}\\.tar\\.(gz|xz)$" "archive" "age/age"

  rj="$(get_release_json "FiloSottile/age")"
  sel="$(select_asset "$rj" "^age-.*-${OS}-${ARX}\\.tar\\.(gz|xz)$" || true)"
  [[ -n "$sel" ]] || { err "No age tarball matched"; exit 1; }
  asset_name="$(cut -f1 <<<"$sel")"; url="$(cut -f2 <<<"$sel")"

  dl="${TMP_DIR}/${asset_name}"
  download_asset "$url" "$dl"
  verify_sha256_if_possible "$rj" "$asset_name" "$dl" || exit 1

  ext="${TMP_DIR}/age2_ext"
  mkdir -p "$ext"
  extract_archive "$dl" "$ext"

  keygen="$(find "$ext" -type f -name age-keygen | head -n1 || true)"
  [[ -n "$keygen" ]] || { err "age-keygen not found in age archive"; exit 1; }
  install_file "$keygen" "${DEST_DIR}/age-keygen"
fi

# --- Policy gate minimum ---
install_gh "open-policy-agent/opa"      "opa"      "^opa_${OS}_${ARCH}_static$" "binary"
CONFTEST_ARCH="x86_64"; [[ "$ARCH" == "arm64" ]] && CONFTEST_ARCH="arm64"
install_gh "open-policy-agent/conftest" "conftest" "^conftest_.*_${OS}_${CONFTEST_ARCH}\\.tar\\.gz$" "archive"

# --- Load test minimum (k6 naming drifts; match broadly) ---
install_gh "grafana/k6" "k6" "^k6-.*-${OS}-${ARX}\\.tar\\.gz$" "archive" || \
install_gh "grafana/k6" "k6" "^k6-.*-${OS}-.*\\.tar\\.gz$"     "archive"

# --- K8s manifest validation / lint (GitHub-only; not in Ubuntu repos) ---
install_gh "yannh/kubeconform" "kubeconform" "^kubeconform-${OS}-${ARCH}\\.tar\\.gz$" "archive"
install_gh "zegl/kube-score"   "kube-score"  "^kube-score_.*_${OS}_${ARCH}\\.tar\\.gz$" "archive"

KUBELINTER_RX="^kube-linter-${OS}$"
[[ "$ARCH" == "arm64" ]] && KUBELINTER_RX="^kube-linter-${OS}_arm64$"
install_gh "stackrox/kube-linter" "kube-linter" "$KUBELINTER_RX" "binary"

# --- Image / OCI layer inspection ---
install_gh "wagoodman/dive" "dive" "^dive_.*_${OS}_${ARCH}\\.tar\\.gz$" "archive"

log "Done."