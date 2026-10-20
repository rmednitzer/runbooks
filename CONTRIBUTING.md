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
| `docs/` | README / CLAUDE.md / CHANGELOG / governance docs |
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


## Dependency automation

Renovate policy is owned by this repository in `renovate.json5`. It does not
inherit another project’s policy. Keep update grouping, release-age delays,
major-version review and lock-maintenance behavior explicit here. Built-in
Renovate presets supply standard defaults; repository-specific decisions remain
local. Review policy changes and actual dependency extraction before merging.


## CI run ownership

The PR-validation workflows updated here coalesce first attempts for the same PR.
Manual reruns use separate run-ID/attempt groups, so rerunning an old revision
cannot cancel or replace current-head validation. Non-PR invocations also use
unique run-ID/attempt groups to preserve each revision's evidence.
GitHub does not guarantee chronological ordering of initial attempts: a late event
can still interrupt another initial attempt. Required checks bind to the current
head; a cancelled current-head check needs a successful rerun before merge.
Explicit diagnostic/publication serialization in other workflows remains separate. Reusable
workflows have distinct file prefixes to avoid cancelling a caller or sibling.
Cancelling an obsolete PR run is not a successful check; the current head still
needs all required results. Revision identity and signing gates remain separate.
Publication workflows retain their existing serialization and cache isolation.
Revert this repository's workflow change to restore the earlier scheduling;
no service deployment or application-data migration is involved.

The aggregate polls one paginated check snapshot per iteration. Its repository-owned
Python standard-library helper accepts only the requested revision and GitHub Actions
app, selects the newest check attempt, and refuses failures, malformed data and
unapproved skips. Missing or queued checks remain pending. API failures fail the gate.
Run its synthetic regressions with
`python3 -m unittest discover -s tests -p test_ci_checks.py`.
