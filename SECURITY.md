# Security policy: runbooks

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/rmednitzer/runbooks/security/advisories/new).
Do not post exploit payloads, secrets, personal data or sensitive operational
details in public issues. If private reporting is unavailable, use an existing
maintainer security contact where published; otherwise request a private channel
with a minimal, non-sensitive issue. Do not assume an invented email address works.

Include the affected revision/version and paths, prerequisites and trust boundary,
expected versus actual behavior, a minimal sanitized reproduction, impact and any
workaround. Use synthetic data. A dependency issue affecting this project is in
scope: coordinate upstream as appropriate without delaying notification here.
This policy does not authorize testing third-party or live deployments, service
disruption, credential use, persistence or access to other people's data.

Existing response targets are retained below as maintainer goals, not guaranteed
service levels. Coordinate disclosure and advisory timing with the maintainer;
urgent active exploitation or credential exposure should be identified immediately.

## Contributor security requirements

Follow [AGENTS.md](AGENTS.md) for secure coding, dependency/CI integrity, verification,
STPA and threat-analysis requirements. Preserve deployment trust boundaries and
document exceptions, residual risk and recovery. Never suppress a security finding
merely to pass CI. For fixes, capture a reproducer, add a meaningful regression,
check adjacent paths, assess affected versions and coordinate remediation/advisories.
Code review and CI do not prove deployed configuration or legal compliance.

## Support and response targets

Only main receives security fixes. Existing targets: acknowledgement within
5 business days and a remediation timeline within 14 days.

## Scope and operational boundaries

Report injection, secret leakage, incorrect privilege scope, unsafe downloads,
ineffective DRY_RUN/confirmation, wrong-target selection, incomplete recovery or
misleading success after partial effects. These scripts may alter live disks,
accounts, certificates and clusters; code review is not authorization to run them.

Validate target, dependencies and prerequisites; use safe quoting, strict error
handling, checksummed/signed downloads and restricted temporary files. Preserve
script-specific typed confirmations, single-node restrictions and dry-run guards.
Tests use fake binaries and disposable fixtures, not real destructive commands.
Talos operations use talosctl from the operator host with verified mTLS identity.
Check postconditions and reconcile ambiguous timeouts before retrying.
