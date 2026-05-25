# Security Policy

Security fixes apply to the current `main` branch only.

## In scope

- Hardcoded secrets in scripts
- Privileged scripts without `DRY_RUN` support or explicit confirmation
- Unverified downloads (HTTP, no checksum, no signature)
- Command injection (unquoted expansions; `eval` on untrusted input)
- Privilege escalation without scoping or auditing

## Reporting

Use [GitHub private vulnerability reporting](https://github.com/rmednitzer/runbooks/security/advisories/new).
Include the affected script path and line numbers, reproduction steps,
and an impact assessment.

We acknowledge within 5 business days and provide a remediation timeline
within 14 days.
