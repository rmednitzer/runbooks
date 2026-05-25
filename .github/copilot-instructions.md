# Copilot Instructions

`runbooks` holds ad-hoc operator shell scripts for recurring fleet tasks
(LVM extensions, certificate renewals, log triage, manual recovery).
Companion repositories: `infra` (OpenTofu) and `automation` (Ansible).

## General Guidelines

- All scripts must use `#!/usr/bin/env bash` and `set -euo pipefail`.
- Scripts should be idempotent by default — safe to re-run without side
  effects.
- Use environment variables for configuration with sensible defaults.
- Prefer portable POSIX-compatible constructs where possible; document
  any bash-specific features.
- Include a header comment block describing purpose, requirements, and
  environment variables.

## Code Style

- Use `log()` helper functions for user-facing output instead of raw
  `echo`.
- Quote all variable expansions: `"${VAR}"` not `$VAR`.
- Use `local` for function-scoped variables.
- Validate required dependencies early (e.g., `command -v curl` checks).
- Use lowercase with underscores for variable and function names.
- Group related functions together with comment separators.

## Security

- Never hardcode secrets or tokens.
- Validate and sanitize any external input.
- Use `sha256sum` or equivalent for verifying downloaded artifacts.
- Prefer HTTPS for all downloads.

## Testing

- Scripts should support a `DRY_RUN` mode that prints actions without
  executing them.
- Include `--help` or usage output where appropriate.
