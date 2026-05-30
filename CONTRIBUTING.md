# Contributing to `runbooks`

Ad-hoc operator shell scripts that don't fit
[`infra`](https://github.com/rmednitzer/infra) (OpenTofu provisioning)
or [`automation`](https://github.com/rmednitzer/automation) (Ansible
roles). Script conventions and the placement decision tree live in
[`CLAUDE.md`](./CLAUDE.md) — single source of truth. This file is
workflow only.

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
pre-commit run --all-files     # shellcheck, shfmt, EditorConfig, hygiene
just test                      # bats tests/ (needs bats-core + just)
```

Every script carries bats coverage under [`tests/`](./tests/) for its
`-h`/`--help`, argument validation, and `DRY_RUN` behaviour (fake
binaries on `PATH` assert the real tool is never called). Add or update
tests alongside any script change. CI
([`.github/workflows/lint.yml`](./.github/workflows/lint.yml)) runs both
the hook set and the bats suite; PRs cannot merge with failing CI.

## Pull request expectations

1. One script (or one cohesive change set) per PR.
2. `[Unreleased]` entry in [`CHANGELOG.md`](./CHANGELOG.md).
3. Imperative commit subject — `Add storage/extend-lvm.sh`.
4. Reference the operational event or runbook scenario that motivated
   the script.

Suspected vulnerabilities — see
[`.github/SECURITY.md`](./.github/SECURITY.md); never open a public
issue.

By contributing, you agree your contribution is licensed under
[Apache License 2.0](./LICENSE).
