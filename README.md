# runbooks

Ad-hoc operator scripts for recurring fleet tasks — disk and filesystem
management, log rotation triage, certificate renewal, manual rollback
helpers, and similar one-off procedures that do not warrant a full
configuration-management role.

This repository was previously named `scripts`. Companion repositories:
`infra` (OpenTofu provisioning) and `automation` (Ansible configuration
and hardening).

## When to add a script here

A script belongs in `runbooks` when:

- It is run manually by an operator in response to a specific event
  (a disk filling up, a certificate near expiry, a stuck cron job)
- It is not idempotent enough to live inside an Ansible role
- It does not provision new infrastructure (that is `infra`'s job)
- It does not enforce baseline configuration (that is `automation`'s job)

If a procedure is run more than a few times across the fleet, consider
promoting it to an Ansible role in the `automation` repository instead.

## When NOT to add a script here

- Infrastructure provisioning → `infra` (OpenTofu)
- System hardening, baseline config, package management → `automation`
  (Ansible roles)
- SRE toolchain installation → `automation/roles/sre_toolchain`
  (replaces the former `scripts/Software/install_binaries.sh`)

## Layout (proposed)

```
runbooks/
├── README.md
├── CLAUDE.md
├── LICENSE
├── storage/        # LVM extends, filesystem resizes, disk checks
├── certificates/   # TLS cert inspection, renewal triggers
├── logs/           # log rotation triage, journal vacuums
├── network/        # ad-hoc DNS / firewall / routing checks
└── recovery/       # manual rollback helpers, breakglass scripts
```

Add new top-level directories as the catalogue grows. Each script lives
under one category and is named for its action
(e.g. `storage/extend-lvm.sh`, `certificates/renew-letsencrypt.sh`).

## Conventions

All shell scripts in this repository follow the conventions in
[`CLAUDE.md`](./CLAUDE.md):

- `#!/usr/bin/env bash` with `set -euo pipefail`
- Idempotent and safe to re-run where the procedure allows it
- Configuration via environment variables with sensible defaults
- Dependencies validated at startup with `command -v`
- `DRY_RUN=1` support where applicable
- No hardcoded secrets; HTTPS for any downloads; verify checksums

## Local development

```bash
pip install pre-commit
pre-commit install
pre-commit run --all-files
```

CI mirrors the local hooks (`bash -n`, `shellcheck`, `shfmt -d`,
`pre-commit run --all-files`). See
[`.github/workflows/lint.yml`](.github/workflows/lint.yml).

## Governance

- [`CONTRIBUTING.md`](./CONTRIBUTING.md) — branch naming, the local loop,
  PR expectations, placement rules.
- [`CHANGELOG.md`](./CHANGELOG.md) — Keep-a-Changelog 1.1.0 format.
- [`.github/SECURITY.md`](./.github/SECURITY.md) — vulnerability reporting.
- [`CLAUDE.md`](./CLAUDE.md) — AI-authoring contract and shell-script
  conventions.

## License

Apache-2.0. See [`LICENSE`](./LICENSE) and [`NOTICE`](./NOTICE).
