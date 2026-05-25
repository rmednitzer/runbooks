# Contributing to runbooks

Thank you for considering a contribution. This repository hosts ad-hoc
operator shell scripts for fleet tasks that don't fit cleanly into
[`infra`](https://github.com/rmednitzer/infra) (OpenTofu provisioning) or
[`automation`](https://github.com/rmednitzer/automation) (Ansible roles).

Before authoring a script, re-read [`CLAUDE.md`](./CLAUDE.md). The
"What belongs here" section is binding.

## Branch naming

- `feature/<short-description>` for new scripts
- `fix/<short-description>` for corrections to existing scripts
- `docs/<short-description>` for README / CLAUDE.md / category README changes
- `chore/<short-description>` for CI / tooling / lint updates

## Local development loop

```bash
# Install pre-commit once
pip install pre-commit
pre-commit install

# Run all hooks locally before pushing
pre-commit run --all-files

# Smoke-test your script in dry-run mode
DRY_RUN=1 ./category/your-script.sh --help
```

CI runs the same checks (`bash -n`, `shellcheck --severity=warning`,
`shfmt -d`, `pre-commit run --all-files`). PRs cannot merge with failing CI.

## Script conventions

The full set is in [`CLAUDE.md`](./CLAUDE.md) and the
[Copilot guide](./.github/copilot-instructions.md). Non-negotiables:

- `#!/usr/bin/env bash` with `set -euo pipefail`
- Help block printed by `-h | --help`, exit code 0
- Idempotent where the procedure allows it; document the constraint when
  it does not
- `DRY_RUN=1` support for any script that mutates state
- No hardcoded secrets; HTTPS-only for downloads; checksum-verify any binary
  fetched from the internet
- Quote every variable expansion: `"${VAR}"` not `$VAR`
- `command -v` dependency checks at startup
- Exit codes: `0` success, `1` runtime error, `2` invalid argument

## Pull request expectations

Each PR should:

1. Add or update **one** script (or one cohesive change set).
2. Update [`CHANGELOG.md`](./CHANGELOG.md) under `[Unreleased]`.
3. Pass `pre-commit run --all-files` locally.
4. Use a clear, imperative commit subject (`Add storage/extend-lvm.sh`,
   `Fix logs/journal-vacuum.sh exit code`).
5. Reference the operational event or runbook scenario that motivated the
   script.

## Repository placement decision tree

A change belongs in `runbooks` only when **all** are true:

- It is run manually by an operator in response to a specific event.
- It is not idempotent enough to live inside an Ansible role.
- It does not provision new infrastructure (otherwise `infra`).
- It does not install fleet-wide baseline software (otherwise `automation`).

When in doubt, propose placement in the PR description — the reviewer will
confirm or redirect.

## Security-sensitive PRs

Scripts that touch authentication, network policy, or recovery should be
flagged in the PR description. The reviewer will verify the dry-run output
before merge. For suspected vulnerabilities, never open a public issue —
see [`.github/SECURITY.md`](./.github/SECURITY.md).

## License

By contributing, you agree your contribution is licensed under
[Apache License 2.0](./LICENSE).
