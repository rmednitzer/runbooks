# runbooks

Ad-hoc operator shell scripts for fleet tasks that don't fit
configuration management or infrastructure-as-code — disk and filesystem
work, certificate renewal triggers, log triage, manual rollback,
breakglass.

Companion repositories:
[`infra`](https://github.com/rmednitzer/infra) (OpenTofu provisioning),
[`automation`](https://github.com/rmednitzer/automation) (Ansible
hardening + SRE toolchain installer).

## Placement

A script belongs here when it is run manually in response to a specific
event, is not idempotent enough for an Ansible role, does not provision
new infrastructure, and does not enforce baseline configuration. Once a
procedure recurs across many hosts, promote it to an Ansible role in
`automation` rather than scaling horizontally here.

The catalogue layout and full script conventions live in
[`CLAUDE.md`](./CLAUDE.md) — single source of truth.

## Development

```bash
pip install pre-commit && pre-commit install
pre-commit run --all-files
```

CI ([`.github/workflows/lint.yml`](./.github/workflows/lint.yml)) mirrors
the hook set — shellcheck, shfmt, EditorConfig, hygiene. PRs cannot merge
with failing CI.

## Governance

| File | Purpose |
|------|---------|
| [`CLAUDE.md`](./CLAUDE.md) | Script conventions, placement decision tree |
| [`CONTRIBUTING.md`](./CONTRIBUTING.md) | Branch naming, local loop, PR expectations |
| [`CHANGELOG.md`](./CHANGELOG.md) | Keep a Changelog 1.1.0 |
| [`.github/SECURITY.md`](./.github/SECURITY.md) | Vulnerability reporting |
| [`.github/PULL_REQUEST_TEMPLATE.md`](./.github/PULL_REQUEST_TEMPLATE.md) | PR checklist |
| [`LICENSE`](./LICENSE) / [`NOTICE`](./NOTICE) | Apache 2.0 |
