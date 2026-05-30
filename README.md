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

Behaviour is covered by a [bats](https://github.com/bats-core/bats-core)
suite under [`tests/`](./tests/): each script's `-h`/`--help`, argument
validation, and `DRY_RUN` paths (against PATH-shimmed fake binaries, so a
destructive tool is never invoked), plus unit tests for the extracted
validators. With `bats-core` and [`just`](https://github.com/casey/just)
installed:

```bash
just test    # bats tests/
just lint    # shellcheck -x
just fmt     # shfmt -i 2 -ci -sr -d
just check   # all three
```

CI ([`.github/workflows/lint.yml`](./.github/workflows/lint.yml)) mirrors
this — shellcheck, shfmt, EditorConfig, hygiene (via pre-commit) and the
bats suite. PRs cannot merge with failing CI.

## Governance

| File | Purpose |
|------|---------|
| [`CLAUDE.md`](./CLAUDE.md) | Script conventions, placement decision tree |
| [`CONTRIBUTING.md`](./CONTRIBUTING.md) | Branch naming, local loop, PR expectations |
| [`CHANGELOG.md`](./CHANGELOG.md) | Keep a Changelog 1.1.0 |
| [`CODE_OF_CONDUCT.md`](./CODE_OF_CONDUCT.md) | Contributor Covenant 2.1 |
| [`.github/SECURITY.md`](./.github/SECURITY.md) | Vulnerability reporting |
| [`.github/CODEOWNERS`](./.github/CODEOWNERS) | Automatic reviewer assignment |
| [`.github/dependabot.yml`](./.github/dependabot.yml) | Weekly GitHub Actions update PRs |
| [`.github/ISSUE_TEMPLATE/`](./.github/ISSUE_TEMPLATE/) | Bug / feature / documentation forms |
| [`.github/PULL_REQUEST_TEMPLATE.md`](./.github/PULL_REQUEST_TEMPLATE.md) | PR checklist |
| [`LICENSE`](./LICENSE) / [`NOTICE`](./NOTICE) | Apache 2.0 |
