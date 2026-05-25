# Security Policy

## Supported Versions

Security fixes apply to the current `main` branch only. Prior commits are not
backported.

## Security Scope

The `runbooks` repository hosts operator shell scripts. In-scope security
concerns:

- **Hardcoded secrets** — credentials, tokens, or keys committed to a script
- **Unsafe defaults** — privileged scripts without `DRY_RUN` support or
  visible confirmation
- **Unverified downloads** — fetching binaries over HTTP, or without checksum
  or signature verification
- **Command injection** — unquoted variable expansions, or untrusted input
  passed to `eval` / unbounded `exec`
- **Privilege escalation** — scripts that elevate privilege without scoping
  or auditing the elevation

## Reporting a Vulnerability

Use [GitHub's private vulnerability reporting](https://github.com/rmednitzer/runbooks/security/advisories/new)
to report issues. Include:

- Affected script path and line numbers
- Reproduction steps (host distro, invocation, observed behavior)
- Assessment of impact (privilege gained, hosts affected, data exposure)

We acknowledge reports within 5 business days and provide a remediation
timeline within 14 days. Critical issues are prioritized; we will coordinate
disclosure timing with the reporter.

## Defensive Practices

Operator scripts in this repository follow conventions documented in
[`../CLAUDE.md`](../CLAUDE.md), including `set -euo pipefail`, quoted variable
expansions, dependency validation at startup, and `DRY_RUN=1` support for any
state-mutating procedure. CI runs `bash -n`, `shellcheck --severity=warning`,
and `shfmt -d` on every push and pull request.
