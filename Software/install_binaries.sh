#!/usr/bin/env bash
# ==============================================================================
# Installs a minimal, high-leverage SRE/Platform/Sec toolchain to /usr/local/bin.
#
# Idempotent by default: will not overwrite existing binaries unless FORCE=1.
# Uses GitHub API; set GITHUB_TOKEN to avoid rate limits.
#
# Requires: curl jq tar unzip sha256sum
# Optional: xz (for .tar.xz archives), parallel (for PARALLEL=1)
#
# Environment:
#   DEST_DIR      Install target dir         (default: /usr/local/bin)
#   FORCE         Overwrite existing binaries (default: 0)
#   DRY_RUN       Print actions, don't execute (default: 0)
#   PARALLEL      Download tools concurrently  (default: 0)
#   GITHUB_TOKEN  GitHub API token for rate limits
#   TMP_BASE      Base temp dir              (default: /var/tmp/minimal-sre-lab-installer)
#   VERSION_LOG   Path for installed-versions manifest (default: ${DEST_DIR}/.sre-toolchain-versions.json)
#   CHECKSUM_POLICY  "strict" = fail on missing checksums; "best-effort" = warn (default)
# ==============================================================================

set -euo pipefail

# ----- Config -----
DEST_DIR="${DEST_DIR:-/usr/local/bin}"
FORCE="${FORCE:-0}"
DRY_RUN="${DRY_RUN:-0}"
PARALLEL="${PARALLEL:-0}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
TMP_BASE="${TMP_BASE:-/var/tmp/minimal-sre-lab-installer}"
CHECKSUM_POLICY="${CHECKSUM_POLICY:-best-effort}"
VERSION_LOG="${VERSION_LOG:-${DEST_DIR}/.sre-toolchain-versions.json}"

OS="linux"
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64)          ARCH="amd64" ;;
  aarch64|arm64)   ARCH="arm64" ;;
  *) echo "FATAL: Unsupported arch: $ARCH_RAW" >&2; exit 1 ;;
esac

arch_rx() {
  case "$ARCH" in
    amd64) echo '(amd64|x86_64|x64)' ;;
    arm64) echo '(arm64|aarch64)' ;;
    *)     echo '(amd64|x86_64|x64|arm64|aarch64)' ;;
  esac
}

log()  { printf "[%s] %s\n" "$(date +'%H:%M:%S')" "$*"; }
warn() { printf "[%s] WARN: %s\n" "$(date +'%H:%M:%S')" "$*" >&2; }
err()  { printf "[%s] ERROR: %s\n" "$(date +'%H:%M:%S')" "$*" >&2; }

# ----- Dependency check -----
MISSING_DEPS=()
for cmd in curl jq tar unzip sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING_DEPS+=("$cmd")
done
if [[ "${#MISSING_DEPS[@]}" -gt 0 ]]; then
  err "Missing dependencies: ${MISSING_DEPS[*]}"
  err "Install with: sudo apt-get install -y ${MISSING_DEPS[*]}"
  exit 1
fi

# ----- Ensure DEST_DIR exists -----
if [[ ! -d "$DEST_DIR" ]]; then
  log "Creating install directory: ${DEST_DIR}"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    sudo mkdir -p "$DEST_DIR" 2>/dev/null || mkdir -p "$DEST_DIR"
  fi
fi

# ----- Temp dir setup -----
mkdir -p "$TMP_BASE"
chmod 700 "$TMP_BASE" 2>/dev/null || true
TMP_DIR="$(mktemp -d -p "$TMP_BASE" minimal-sre.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ----- Curl defaults -----
CURL_ARGS=(
  -fLsS --retry 3 --retry-delay 2 --connect-timeout 10
  --proto '=https' --tlsv1.2
  -H "Accept: application/vnd.github+json"
  -H "User-Agent: minimal-sre-lab-installer/2.0"
)
[[ -n "$GITHUB_TOKEN" ]] && CURL_ARGS+=(-H "Authorization: Bearer $GITHUB_TOKEN")

need_sudo=0
[[ -w "$DEST_DIR" ]] || need_sudo=1

# ----- Version tracking -----
declare -A INSTALLED_VERSIONS=()

# ----- Counters -----
INSTALL_OK=0
INSTALL_SKIP=0
INSTALL_FAIL=0

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
    *.zip)          unzip -oq "$archive" -d "$outdir" ;;
    *) err "Unknown archive type: $archive"; return 1 ;;
  esac
}

get_release_json() {
  local repo="$1"
  local rj
  rj="$(curl -s "${CURL_ARGS[@]}" "https://api.github.com/repos/${repo}/releases/latest")"
  # Detect rate limiting early
  if echo "$rj" | jq -e '.message // empty' | grep -qi "rate limit" 2>/dev/null; then
    err "GitHub API rate limit hit. Set GITHUB_TOKEN to authenticate."
    return 1
  fi
  echo "$rj"
}

select_asset() {
  local release_json="$1" regex="$2"
  echo "$release_json" | jq -r --arg rx "$regex" '
    .assets[]?
    | select(.name | test($rx; "i"))
    | "\(.name)\t\(.browser_download_url)"
  ' | head -n1
}

select_assets() {
  local release_json="$1" regex="$2"
  echo "$release_json" | jq -r --arg rx "$regex" '
    .assets[]?
    | select(.name | test($rx; "i"))
    | "\(.name)\t\(.browser_download_url)"
  '
}

verify_sha256() {
  # Returns 0 on verified, 1 on mismatch, 2 on no-checksum-available.
  # Callers decide policy based on CHECKSUM_POLICY.
  local release_json="$1" asset_name="$2" file="$3"

  local sel checksum_name checksum_url checksum_file expected actual

  _read_expected_hash() {
    local f="$1" a="$2"
    local h

    # Entry mentioning the asset by name
    h="$(grep -E "([[:space:]]|^)(\\*|)?${a}([[:space:]]|$)" "$f" 2>/dev/null | head -n1 | awk '{print $1}')"
    if [[ -n "$h" && "$h" =~ ^[A-Fa-f0-9]{64}$ ]]; then echo "$h"; return 0; fi

    # Path-based match
    h="$(grep -E "([[:space:]]|^).*/${a}([[:space:]]|$)" "$f" 2>/dev/null | head -n1 | awk '{print $1}')"
    if [[ -n "$h" && "$h" =~ ^[A-Fa-f0-9]{64}$ ]]; then echo "$h"; return 0; fi

    # Sole hash in a per-asset checksum file
    h="$(head -n1 "$f" | awk '{print $1}')"
    if [[ "$h" =~ ^[A-Fa-f0-9]{64}$ ]]; then echo "$h"; return 0; fi

    return 1
  }

  # 1) Exact per-asset checksum: <asset>.sha256 or <asset>.sha256sum
  sel="$(select_asset "$release_json" "^${asset_name//./\\.}\\.(sha256|sha256sum)$" || true)"
  if [[ -n "$sel" ]]; then
    checksum_name="$(cut -f1 <<<"$sel")"
    checksum_url="$(cut -f2 <<<"$sel")"
    checksum_file="${TMP_DIR}/${checksum_name}"
    log "  CHECK: per-asset checksum ${checksum_name}"
    download_asset "$checksum_url" "$checksum_file"

    expected="$(_read_expected_hash "$checksum_file" "$asset_name" || true)"
    [[ -n "$expected" ]] || { err "Could not parse hash from ${checksum_name}"; return 1; }

    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [[ "$expected" != "$actual" ]]; then
      err "SHA256 MISMATCH: ${asset_name} expected=${expected} actual=${actual}"
      return 1
    fi
    log "  OK: sha256 verified (per-asset)"
    return 0
  fi

  # 2) Bundle checksum assets
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
      # Skip signatures/certs
      [[ "$checksum_name" =~ \.(pem|sig|asc|cert)$ ]] && continue

      any_candidate=1
      checksum_file="${TMP_DIR}/${checksum_name}"
      log "  CHECK: bundle ${checksum_name}"
      download_asset "$checksum_url" "$checksum_file"

      expected="$(_read_expected_hash "$checksum_file" "$asset_name" || true)"
      [[ -n "$expected" ]] || continue   # not the right bundle

      actual="$(sha256sum "$file" | awk '{print $1}')"
      if [[ "$expected" != "$actual" ]]; then
        err "SHA256 MISMATCH: ${asset_name} (bundle ${checksum_name}) expected=${expected} actual=${actual}"
        return 1
      fi
      log "  OK: sha256 verified (bundle)"
      return 0
    done < <(select_assets "$release_json" "$rx" || true)
  done

  if [[ "$any_candidate" -eq 1 ]]; then
    warn "Checksum bundles found but none contained entry for ${asset_name}"
  else
    warn "No checksum asset found for ${asset_name}"
  fi
  return 2  # no-checksum-available (distinct from mismatch)
}

_handle_checksum_result() {
  local rc="$1" asset_name="$2"
  case "$rc" in
    0) return 0 ;;
    1) err "Checksum verification FAILED for ${asset_name}. Aborting this tool."; return 1 ;;
    2)
      if [[ "$CHECKSUM_POLICY" == "strict" ]]; then
        err "STRICT: No checksum available for ${asset_name}. Aborting."; return 1
      fi
      log "  INFO: Proceeding without checksum (best-effort policy)"
      return 0
      ;;
  esac
}

install_gh() {
  # install_gh <repo> <bin_name_or_csv> <asset_regex> <type:binary|archive> [paths_in_archive_csv]
  #
  # bin_name_or_csv:       single binary name OR comma-separated list (e.g. "age,age-keygen")
  # paths_in_archive_csv:  matching comma-separated archive paths (e.g. "age/age,age/age-keygen")
  #
  local repo="$1" bins_csv="$2" rx="$3" type="$4" arc_paths_csv="${5:-}"

  IFS=',' read -ra BINS <<< "$bins_csv"
  IFS=',' read -ra ARC_PATHS <<< "${arc_paths_csv:-}"

  local primary="${BINS[0]}"
  local target="${DEST_DIR}/${primary}"

  # Skip check: only check primary binary (all binaries come from same archive)
  if [[ "$FORCE" -eq 0 && -x "$target" ]]; then
    local all_present=1
    for b in "${BINS[@]}"; do
      [[ -x "${DEST_DIR}/${b}" ]] || { all_present=0; break; }
    done
    if [[ "$all_present" -eq 1 ]]; then
      log "SKIP: ${bins_csv} already present."
      (( INSTALL_SKIP++ )) || true
      return 0
    fi
  fi

  local rj tag sel asset_name url
  rj="$(get_release_json "$repo")" || { (( INSTALL_FAIL++ )) || true; return 1; }
  tag="$(echo "$rj" | jq -r '.tag_name // empty')"
  if [[ -z "$tag" || "$tag" == "null" ]]; then
    err "Cannot resolve tag for ${repo} (rate limit/auth/empty release?)"
    (( INSTALL_FAIL++ )) || true
    return 1
  fi

  sel="$(select_asset "$rj" "$rx" || true)"
  if [[ -z "$sel" ]]; then
    err "No asset matched for ${repo} regex=${rx}"
    (( INSTALL_FAIL++ )) || true
    return 1
  fi
  asset_name="$(cut -f1 <<<"$sel")"
  url="$(cut -f2 <<<"$sel")"

  log "INSTALL: ${bins_csv} @ ${tag}  asset=${asset_name}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    for b in "${BINS[@]}"; do INSTALLED_VERSIONS["$b"]="$tag"; done
    return 0
  fi

  local dl="${TMP_DIR}/${asset_name}"
  download_asset "$url" "$dl"

  local vrc=0
  verify_sha256 "$rj" "$asset_name" "$dl" || vrc=$?
  _handle_checksum_result "$vrc" "$asset_name" || { (( INSTALL_FAIL++ )) || true; return 1; }

  if [[ "$type" == "binary" ]]; then
    install_file "$dl" "$target"
  else
    local ext="${TMP_DIR}/${primary}_ext"
    mkdir -p "$ext"
    extract_archive "$dl" "$ext"

    local i=0
    for b in "${BINS[@]}"; do
      local src=""
      if [[ -n "${ARC_PATHS[$i]:-}" ]]; then
        src="${ext}/${ARC_PATHS[$i]}"
      else
        src="$(find "$ext" -type f -name "$b" | head -n1 || true)"
      fi
      if [[ ! -f "$src" ]]; then
        err "Binary ${b} not found in archive for ${repo}"
        (( INSTALL_FAIL++ )) || true
        return 1
      fi
      install_file "$src" "${DEST_DIR}/${b}"
      (( i++ )) || true
    done
  fi

  for b in "${BINS[@]}"; do INSTALLED_VERSIONS["$b"]="$tag"; done
  (( INSTALL_OK++ )) || true
}

# Special handler for kubectx/kubens (source archive, not binary release)
install_kubectx() {
  local target_ctx="${DEST_DIR}/kubectx"
  local target_ns="${DEST_DIR}/kubens"

  if [[ "$FORCE" -eq 0 && -x "$target_ctx" && -x "$target_ns" ]]; then
    log "SKIP: kubectx/kubens already present."
    (( INSTALL_SKIP++ )) || true
    return 0
  fi

  local rj tag src_tgz ext base
  rj="$(get_release_json "ahmetb/kubectx")" || { (( INSTALL_FAIL++ )) || true; return 1; }
  tag="$(echo "$rj" | jq -r '.tag_name // empty')"
  if [[ -z "$tag" || "$tag" == "null" ]]; then
    err "Cannot resolve tag for ahmetb/kubectx"
    (( INSTALL_FAIL++ )) || true
    return 1
  fi

  log "INSTALL: kubectx/kubens @ ${tag} (source)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    INSTALLED_VERSIONS["kubectx"]="$tag"
    INSTALLED_VERSIONS["kubens"]="$tag"
    return 0
  fi

  src_tgz="${TMP_DIR}/kubectx-src.tgz"
  download_asset "https://github.com/ahmetb/kubectx/archive/refs/tags/${tag}.tar.gz" "$src_tgz"
  # Source tarballs from GitHub don't have release checksums; verify tag is from API.

  ext="${TMP_DIR}/kubectx-src"
  mkdir -p "$ext"
  extract_archive "$src_tgz" "$ext"

  base="${ext}/kubectx-${tag#v}"
  if [[ ! -f "${base}/kubectx" || ! -f "${base}/kubens" ]]; then
    err "kubectx/kubens scripts not found in source archive"
    (( INSTALL_FAIL++ )) || true
    return 1
  fi
  install_file "${base}/kubectx" "$target_ctx"
  install_file "${base}/kubens"  "$target_ns"

  INSTALLED_VERSIONS["kubectx"]="$tag"
  INSTALLED_VERSIONS["kubens"]="$tag"
  (( INSTALL_OK++ )) || true
}

write_version_manifest() {
  if [[ "$DRY_RUN" -eq 1 ]]; then return 0; fi
  if [[ "${#INSTALLED_VERSIONS[@]}" -eq 0 ]]; then return 0; fi

  local tmpf="${TMP_DIR}/versions.json"
  {
    echo "{"
    echo "  \"generated\": \"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\","
    echo "  \"arch\": \"${ARCH}\","
    echo "  \"os\": \"${OS}\","
    echo "  \"checksum_policy\": \"${CHECKSUM_POLICY}\","
    echo "  \"tools\": {"
    local first=1
    for bin in $(echo "${!INSTALLED_VERSIONS[@]}" | tr ' ' '\n' | sort); do
      [[ "$first" -eq 1 ]] && first=0 || echo ","
      printf '    "%s": "%s"' "$bin" "${INSTALLED_VERSIONS[$bin]}"
    done
    echo ""
    echo "  }"
    echo "}"
  } > "$tmpf"

  if [[ "$need_sudo" -eq 1 ]]; then
    sudo cp "$tmpf" "$VERSION_LOG"
  else
    cp "$tmpf" "$VERSION_LOG"
  fi
  log "Version manifest written to ${VERSION_LOG}"
}

# ==============================================================================
# Tool definitions
# ==============================================================================

run_installs() {
  local ARX
  ARX="$(arch_rx)"

  log "Target: ${DEST_DIR} | arch=${ARCH} | FORCE=${FORCE} | DRY_RUN=${DRY_RUN} | CHECKSUM_POLICY=${CHECKSUM_POLICY}"
  [[ -n "$GITHUB_TOKEN" ]] || warn "GITHUB_TOKEN not set — you may hit API rate limits."

  # --- Platform / K8s core ---
  install_gh "kubernetes-sigs/kind"      "kind"      "^kind-${OS}-${ARCH}$"                     "binary"
  install_gh "kubernetes-sigs/kustomize" "kustomize" "^kustomize_v.*_${OS}_${ARCH}\\.tar\\.gz$" "archive"
  install_gh "stern/stern"               "stern"     "^stern_.*_${OS}_${ARCH}\\.tar\\.gz$"      "archive"

  install_kubectx

  # --- GitOps ---
  install_gh "fluxcd/flux2" "flux" "^flux_.*_${OS}_${ARCH}\\.tar\\.gz$" "archive"

  # --- Supply-chain / security ---
  local TRIVY_FLAVOR="Linux-64bit"
  [[ "$ARCH" == "arm64" ]] && TRIVY_FLAVOR="Linux-ARM64"
  install_gh "aquasecurity/trivy" "trivy" "^trivy_.*_${TRIVY_FLAVOR}\\.tar\\.gz$" "archive"

  install_gh "anchore/syft"    "syft"   "^syft_.*_${OS}_${ARCH}\\.tar\\.gz$" "archive"
  install_gh "sigstore/cosign" "cosign" "^cosign-${OS}-${ARCH}$"             "binary"
  install_gh "getsops/sops"    "sops"   "^sops-.*\\.${OS}\\.${ARCH}$"        "binary"

  # age + age-keygen: single download, two binaries
  install_gh "FiloSottile/age" "age,age-keygen" \
    "^age-.*-${OS}-${ARX}\\.tar\\.(gz|xz)$" "archive" "age/age,age/age-keygen"

  # --- Policy gate ---
  install_gh "open-policy-agent/opa" "opa" "^opa_${OS}_${ARCH}_static$" "binary"

  local CONFTEST_ARCH="x86_64"
  [[ "$ARCH" == "arm64" ]] && CONFTEST_ARCH="arm64"
  install_gh "open-policy-agent/conftest" "conftest" \
    "^conftest_.*_${OS}_${CONFTEST_ARCH}\\.tar\\.gz$" "archive"

  # --- Load testing (k6 asset naming varies across releases) ---
  install_gh "grafana/k6" "k6" "^k6-.*-${OS}-${ARX}\\.tar\\.gz$" "archive" || \
    install_gh "grafana/k6" "k6" "^k6-.*${OS}.*${ARX}.*\\.tar\\.gz$" "archive" || \
    warn "k6: no matching asset found for ${OS}/${ARCH}"

  # --- K8s manifest validation / lint ---
  install_gh "yannh/kubeconform" "kubeconform" \
    "^kubeconform-${OS}-${ARCH}\\.tar\\.gz$" "archive"
  install_gh "zegl/kube-score" "kube-score" \
    "^kube-score_.*_${OS}_${ARCH}\\.tar\\.gz$" "archive"

  local KUBELINTER_RX="^kube-linter-${OS}$"
  [[ "$ARCH" == "arm64" ]] && KUBELINTER_RX="^kube-linter-${OS}_arm64$"
  install_gh "stackrox/kube-linter" "kube-linter" "$KUBELINTER_RX" "binary"

  # --- Image / OCI inspection ---
  install_gh "wagoodman/dive" "dive" "^dive_.*_${OS}_${ARCH}\\.tar\\.gz$" "archive"
}

# ==============================================================================
# Main
# ==============================================================================

run_installs
write_version_manifest

log "Summary: installed=${INSTALL_OK} skipped=${INSTALL_SKIP} failed=${INSTALL_FAIL}"
if [[ "$INSTALL_FAIL" -gt 0 ]]; then
  err "Some tools failed to install. Review output above."
  exit 1
fi
log "Done."
