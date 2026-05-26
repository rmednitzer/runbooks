# runbooks

Ad-hoc operator scripts for recurring fleet tasks — disk and filesystem
management, log rotation triage, certificate renewal, manual rollback
helpers, and similar one-off procedures that do not warrant a full
configuration-management role.

Companion repositories: [`infra`](https://github.com/rmednitzer/infra)
(OpenTofu provisioning) and
[`automation`](https://github.com/rmednitzer/automation) (Ansible
configuration and hardening).

## Placement

A script belongs in `runbooks` when it is run manually by an operator in
response to a specific event (a disk filling up, a certificate near expiry,
a stuck cron job), is not idempotent enough to live inside an Ansible role,
and neither provisions new infrastructure (`infra`'s job) nor enforces
baseline configuration (`automation`'s job — including the SRE toolchain
installer at `automation/roles/sre_toolchain`). If a procedure recurs across
many hosts, promote it to an Ansible role in `automation` instead.

The catalogue layout and full script conventions live in
[`CLAUDE.md`](./CLAUDE.md) — the single source of truth.

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
