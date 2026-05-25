# CLAUDE.md — AI Assistant Guide for runbooks

## Project Overview

`runbooks` holds ad-hoc operator shell scripts for recurring fleet tasks
that do not belong in configuration management or infrastructure-as-code.
Examples: LVM extension, filesystem resize, certificate renewal triggers,
log rotation triage, manual rollback helpers.

Companion repositories:

- `infra` — OpenTofu infrastructure provisioning
- `automation` — Ansible roles for fleet hardening, configuration
  management, and the SRE toolchain installer
  (`automation/roles/sre_toolchain`)

## What belongs here

A script is a fit for this repository when **all** are true:

- It is run manually by an operator in response to a specific event
- It is not naturally idempotent across the fleet (otherwise: Ansible)
- It does not provision new infrastructure (otherwise: OpenTofu)
- It does not install fleet-wide baseline software (otherwise: Ansible)

When a script becomes routine across many hosts, promote it to an
Ansible role in `automation` rather than scaling it horizontally here.

## Repository Structure

```
runbooks/
├── CLAUDE.md       # This file
├── README.md       # Operator-facing entry point
├── LICENSE         # Apache-2.0
├── storage/        # LVM, filesystem, disk
├── certificates/   # TLS / PKI helpers
├── logs/           # Log rotation triage, journal vacuums
├── network/        # Ad-hoc DNS / firewall / routing checks
└── recovery/       # Manual rollback, breakglass scripts
```

Add new categories as the catalogue grows. Avoid catch-all dumping
grounds (`misc/`, `utils/`); pick the smallest specific category instead.

## Script Conventions

- Shebang: `#!/usr/bin/env bash`
- Safety: `set -euo pipefail`
- Idempotency: re-run safety where the procedure allows it; document
  when it does not in the script's usage block
- Configuration: environment variables with sensible defaults; document
  every variable in a `usage()` function
- Logging: helper functions (`log`, `warn`, `err`) — not raw `echo`
- Quoting: always quote variable expansions (`"${VAR}"`)
- Scope: use `local` for function-scoped variables
- Dependencies: validate at startup with `command -v`
- Dry-run: support `DRY_RUN=1` where applicable
- Help: `-h | --help` prints a usage block and exits 0 cleanly
- Exit codes: `0` success, `1` runtime error, `2` invalid argument
- Secrets: never hardcoded; use HTTPS for downloads; verify checksums
  for binaries fetched from the internet

## Important Notes for AI Assistants

- Default to *adding* a script here only when none of the companion
  repositories is a better fit. When in doubt, propose the placement to
  the user before writing.
- Keep each script self-contained — no shared helper libraries unless
  the catalogue clearly demands one (defer that decision).
- Document **why** the procedure exists at the top of the script, not
  just **what** it does. The reader is an operator at 03:00 who has
  never seen this script before.
- Never commit secrets, credentials, or API tokens. Validate via
  `git diff` before any commit suggestion.
