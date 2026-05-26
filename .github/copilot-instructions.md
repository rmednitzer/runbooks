# Copilot Instructions — `runbooks`

Ad-hoc operator shell scripts for recurring fleet tasks (LVM extension,
certificate renewal, log triage, manual recovery). Companion repos:
`infra` (OpenTofu), `automation` (Ansible). Full conventions and the
placement decision tree live in `CLAUDE.md` — defer to it.

## Script shape

- `#!/usr/bin/env bash` with `set -euo pipefail`
- Idempotent when the procedure allows; documented otherwise
- Configuration via environment variables with sensible defaults
- Header comment block: purpose, requirements, environment variables
- POSIX where portable; document bash-only constructs

## Code style

- `log` / `warn` / `err` helpers, never raw `echo`
- Quote every variable expansion (`"${VAR}"`, not `$VAR`)
- `local` for function-scoped variables
- Validate dependencies early with `command -v`
- Lowercase-underscore variable and function names
- Group related functions together with comment separators

## Security

- Never hardcode secrets, credentials, or tokens
- Validate and sanitize external input
- HTTPS downloads only; SHA256-verify every fetched artifact
- Never `eval` untrusted input

## Testing

- `DRY_RUN=1` mode where the script performs destructive operations
- `-h | --help` prints usage and exits 0
