# Changelog

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Seed the catalogue with six high-value operator scripts covering four
  of the five suggested categories in `CLAUDE.md`. Each script is
  self-contained, shellcheck/shfmt-clean, documents the WHY for a 03:00
  operator, validates required environment variables, and supports
  `DRY_RUN=1` and `-h | --help`. Exit codes follow the
  `0`/`1`/`2` (success / runtime error / invalid argument) contract.
  - `storage/extend-lvm.sh` — extend an LVM logical volume and grow
    its filesystem (ext{2,3,4} via resize2fs, xfs via xfs_growfs).
    Optional `PV_RESIZE=1` for the case where the hypervisor grew an
    underlying disk.
  - `storage/disk-usage-triage.sh` — one-page disk-full triage:
    largest directories, large files, journal usage, and (via lsof)
    deleted-but-held-open files that du cannot see.
  - `logs/journal-vacuum.sh` — vacuum the systemd journal by age
    (`KEEP_DAYS`) or by size (`KEEP_SIZE`); reports before/after disk
    usage.
  - `certificates/check-cert-expiry.sh` — TLS spot-check via
    `openssl s_client` with optional STARTTLS, SNI, and a configurable
    `THRESHOLD_DAYS` for non-zero exit.
  - `recovery/unlock-account.sh` — clear fail2ban bans across every
    jail and reset pam_faillock counters for a user. Env var is
    `TARGET_USER` rather than `USER` to avoid the always-set shell
    variable collision.
  - `recovery/aide-acknowledge.sh` — accept the current filesystem
    state as the new AIDE baseline after a sanctioned change; keeps a
    timestamped backup of the previous database for rollback.
- Optimise and rewrite every `.md` file end-to-end for tighter prose,
  consistent voice, and uniform structure across the three companion
  repos: `README.md`, `CLAUDE.md`, `CONTRIBUTING.md`,
  `.github/SECURITY.md`, `.github/PULL_REQUEST_TEMPLATE.md`,
  `.github/copilot-instructions.md`. The placement decision tree, the
  catalogue tree, the script convention list, and the placement-to-
  Ansible promotion rule all stay; the prose around them is shorter and
  more imperative. No policy or workflow change.

## [0.0.0]

- Initial governance scaffolding: `NOTICE`, `.editorconfig`, `.gitignore`,
  `.github/SECURITY.md`, `.pre-commit-config.yaml`, `CHANGELOG.md`,
  `CONTRIBUTING.md`.
- `.github/workflows/lint.yml` running shellcheck, shfmt, EditorConfig,
  and standard hygiene hooks.
