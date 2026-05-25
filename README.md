# runbooks

Ad-hoc operator scripts for recurring fleet tasks — disk and filesystem
management, log rotation triage, certificate renewal, manual rollback
helpers, and similar one-off procedures that do not warrant a full
configuration-management role.

Companion repositories: [`infra`](https://github.com/rmednitzer/infra)
(OpenTofu provisioning) and
[`automation`](https://github.com/rmednitzer/automation) (Ansible
configuration and hardening).

## When to add a script here

A script belongs in `runbooks` when:

- It is run manually by an operator in response to a specific event
  (a disk filling up, a certificate near expiry, a stuck cron job)
- It is not idempotent enough to live inside an Ansible role
- It does not provision new infrastructure (that is `infra`'s job)
- It does not enforce baseline configuration (that is `automation`'s job)

If a procedure is run more than a few times across the fleet, consider
promoting it to an Ansible role in `automation` instead.

## When NOT to add a script here

- Infrastructure provisioning → `infra` (OpenTofu)
- System hardening, baseline config, package management → `automation`
  (Ansible roles)
- SRE toolchain installation → `automation/roles/sre_toolchain`

## Layout

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

## Development

```bash
pip install pre-commit && pre-commit install
pre-commit run --all-files
```

CI mirrors the hook set
([`.github/workflows/lint.yml`](./.github/workflows/lint.yml)) and runs
shellcheck, shfmt, EditorConfig, and the standard hygiene hooks. PRs
cannot merge with failing CI.

## Governance

| File | Purpose |
|------|---------|
| [`CLAUDE.md`](./CLAUDE.md) | Script conventions, placement decision tree |
| [`CONTRIBUTING.md`](./CONTRIBUTING.md) | Workflow, branch naming, PR expectations |
| [`CHANGELOG.md`](./CHANGELOG.md) | Keep a Changelog 1.1.0 |
| [`.github/SECURITY.md`](./.github/SECURITY.md) | Vulnerability reporting |
| [`.github/PULL_REQUEST_TEMPLATE.md`](./.github/PULL_REQUEST_TEMPLATE.md) | PR checklist |
| [`LICENSE`](./LICENSE) / [`NOTICE`](./NOTICE) | Apache 2.0 |
