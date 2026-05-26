# Security Policy

Security fixes apply to the current `main` branch only.

## In scope

- Hardcoded secrets, credentials, or tokens in scripts
- Privileged scripts without `DRY_RUN` support or explicit confirmation
- Unverified downloads — HTTP, no checksum, no signature
- Command injection — unquoted expansions, `eval` on untrusted input
- Privilege escalation without scoping or auditing

## Reporting

[GitHub private vulnerability reporting](https://github.com/rmednitzer/runbooks/security/advisories/new).
Include the affected script path, line numbers, reproduction steps, and
an impact assessment.

Acknowledgement within 5 business days; remediation timeline within 14
days.

## Best practices for contributors

- Never commit secrets, credentials, or private keys; check `git diff`
  before each commit.
- Quote every variable expansion (`"${VAR}"`); never `eval` untrusted
  input.
- Validate every dependency at startup with `command -v`.
- Fetch binaries over HTTPS and verify the SHA256 (or signature) before
  using them.
- Support `DRY_RUN=1` on any script that performs destructive
  operations; print intent before acting.
