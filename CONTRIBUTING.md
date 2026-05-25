# Contributing to runbooks

This repository hosts ad-hoc operator shell scripts for fleet tasks that
don't fit cleanly into [`infra`](https://github.com/rmednitzer/infra)
(OpenTofu provisioning) or
[`automation`](https://github.com/rmednitzer/automation) (Ansible roles).
[`CLAUDE.md`](./CLAUDE.md) is the source of truth for script conventions
and the placement decision tree; this file covers workflow only.

## Branch naming

| Prefix | Use |
|--------|-----|
| `feature/` | New scripts |
| `fix/` | Corrections to existing scripts |
| `docs/` | README / CLAUDE.md / category README changes |
| `chore/` | CI / tooling / lint updates |

## Local loop

```bash
pip install pre-commit && pre-commit install
pre-commit run --all-files
```

CI mirrors the hook set
([`.github/workflows/lint.yml`](./.github/workflows/lint.yml)). PRs
cannot merge with failing CI.

## Pull request expectations

1. One script (or one cohesive change set) per PR.
2. Add an `[Unreleased]` entry in [`CHANGELOG.md`](./CHANGELOG.md).
3. Imperative commit subject (`Add storage/extend-lvm.sh`).
4. Reference the operational event or runbook scenario that motivated
   the script.

Suspected vulnerabilities: see
[`.github/SECURITY.md`](./.github/SECURITY.md) — never open a public
issue.

By contributing, you agree your contribution is licensed under
[Apache License 2.0](./LICENSE).
