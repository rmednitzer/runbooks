# Scripts

Utility scripts for SRE / Platform / Security toolchain setup and management.

## Contents

| Path | Description |
|------|-------------|
| `Software/install_binaries.sh` | Installs a minimal, high-leverage SRE/Platform/Security toolchain into `/usr/local/bin`. |

## `Software/install_binaries.sh`

Downloads pinned-to-latest release binaries from GitHub, verifies SHA256
checksums where published, installs them idempotently, and writes a JSON
manifest of installed versions.

Installed tools: `kind`, `kustomize`, `stern`, `kubectx`/`kubens`, `flux`,
`trivy`, `syft`, `cosign`, `sops`, `age`/`age-keygen`, `opa`, `conftest`,
`k6`, `kubeconform`, `kube-score`, `kube-linter`, `dive`.

### Usage

```bash
# Show usage and exit (no changes made)
./Software/install_binaries.sh --help

# Preview everything without installing
DRY_RUN=1 ./Software/install_binaries.sh

# Normal install (use a token to avoid GitHub API rate limits)
GITHUB_TOKEN=ghp_xxx ./Software/install_binaries.sh

# Require published checksums for every tool
CHECKSUM_POLICY=strict GITHUB_TOKEN=ghp_xxx ./Software/install_binaries.sh
```

### Configuration

All configuration is via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `DEST_DIR` | `/usr/local/bin` | Install target directory. `sudo` is used automatically if it is not writable. |
| `FORCE` | `0` | `1` overwrites binaries that are already present. |
| `DRY_RUN` | `0` | `1` prints actions without downloading or installing. |
| `PARALLEL` | `0` | Reserved; concurrent downloads are not yet implemented. |
| `GITHUB_TOKEN` | _(unset)_ | GitHub API token. Strongly recommended to avoid 60-req/hr unauthenticated rate limits. |
| `TMP_BASE` | `/var/tmp/minimal-sre-lab-installer` | Base directory for the per-run temp dir. |
| `VERSION_LOG` | `${DEST_DIR}/.sre-toolchain-versions.json` | Path of the installed-versions manifest. |
| `CHECKSUM_POLICY` | `best-effort` | `strict` aborts a tool when no checksum is published; `best-effort` warns and proceeds. |

### Requirements

`curl`, `jq`, `tar`, `unzip`, `sha256sum` (checked at startup). `xz` is
needed only for `.tar.xz` assets; `sudo` only when `DEST_DIR` is not
writable by the current user.

### Exit codes

- `0` — all selected tools installed or already present.
- `1` — one or more tools failed (details printed); or a fatal precondition.
- `2` — invalid command-line argument.

## Conventions

See [`CLAUDE.md`](./CLAUDE.md) and
[`.github/copilot-instructions.md`](./.github/copilot-instructions.md) for
the coding conventions all scripts in this repository follow.

## License

Apache-2.0. See [`LICENSE`](./LICENSE).
