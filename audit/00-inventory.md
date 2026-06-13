# Phase 0 — Recon and inventory (`runbooks`)

Audit pass: `audit/2026-06-13-full-pass`. Read-only phase. Branch base:
`82f2922` ("ci: replace abandoned pre-commit/action with direct pre-commit
invocation", #26).

Every figure below was produced by a command run in this session. Items not
verifiable this session are tagged `[UNVERIFIED]`.

## Component map

Ad-hoc operator shell scripts (bash >= 4, GNU/Linux). No build system, no
compiled artifact. The "build" is shellcheck + shfmt; the "tests" are a bats
suite of PATH-shimmed fakes (the real `talosctl`/`lvextend`/etc. are never
invoked).

```
runbooks/
├── storage/        extend-lvm.sh, disk-usage-triage.sh
├── certificates/   check-cert-expiry.sh, rotate-cert.sh
├── logs/           journal-vacuum.sh
├── recovery/       unlock-account.sh, aide-acknowledge.sh
├── network/        dns-propagation-check.sh, port-reachability.sh, conntrack-triage.sh
├── talos/          talos-health-check, etcd-snapshot, etcd-restore,
│                   upgrade-node, kubeconfig-rotate, reset-node
├── secops/         ai-triage.sh   (LOCAL inference, read-only)
└── tests/          17 *.bats + helpers/common.bash
```

## File inventory

| Metric | Value |
|--------|-------|
| Tracked files | 57 |
| Shell scripts (`*.sh`) | 17 |
| bats tests (`*.bats`) | 17 (1:1 with scripts) + `tests/helpers/common.bash` |
| `.md` files | 8 |
| In-code TODO/FIXME markers | 0 |

## Dependency / toolchain graph

No package manifest (pure bash). Tool versions are pinned in
`.pre-commit-config.yaml` and `.github/workflows/lint.yml`:

| Tool | Pin | Role |
|------|-----|------|
| pre-commit-hooks | `v6.0.0` | hygiene (yaml/json/eof/whitespace/private-key) |
| gitleaks | `v8.30.1` (hook) + image digest `sha256:c00b…bb7f` (CI) | secret scan |
| shellcheck-py | `v0.11.0.1` | `shellcheck -x --enable=all` |
| pre-commit-shfmt | `v3.13.1-1` | `shfmt -i 2 -ci -sr -d` |
| editorconfig-checker | `3.6.1` | EditorConfig enforcement |
| bats-core | `v1.13.0` (SHA-verified in CI) | behaviour tests |

Renovate (`renovate.json5`) keeps the pins fresh. Runtime dependencies are
per-script and validated at startup with `command -v` (e.g. `talosctl`,
`openssl`, `dig`, `lvextend`, `journalctl`).

## CI configuration

`.github/workflows/lint.yml`, `permissions: contents: read`, `concurrency`
with `cancel-in-progress`. Three jobs:

| Job | What it runs |
|-----|--------------|
| `pre-commit` | `pre-commit run --all-files` (shellcheck + shfmt + hygiene), invoked directly (the abandoned `pre-commit/action` wrapper was dropped in #26) |
| `bats` | bats-core v1.13.0 (SHA-pinned and verified), `sudo bats tests/` |
| `secret-scan` | gitleaks `dir` over the full working tree, image pinned by digest |

All `uses:` are SHA-pinned with version comments. No CodeQL (shell-only repo).

## Toolchain available in this environment

| Tool | Version | Note |
|------|---------|------|
| shellcheck | 0.9.0 | CI pins 0.11.0.1; both pass clean here |
| shfmt | 3.13.x | matches pin family |
| bats | 1.13.0 | installed this session (the pinned version) |
| gitleaks | dev build (`detect`) | CI uses v8.30.1 (`dir`) |
| python3 | 3.11.15 | used by `ai-triage.sh` (stdlib only) |
