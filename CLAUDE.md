# CLAUDE.md — `runbooks`

Ad-hoc operator shell scripts for recurring fleet tasks that do not
belong in configuration management or infrastructure-as-code: LVM
extension, filesystem resize, certificate renewal triggers, log triage,
manual rollback, breakglass.

Companions: `infra` (OpenTofu), `automation` (Ansible — including the
SRE toolchain installer at `automation/roles/sre_toolchain`).

## What belongs here

All of:

- Run manually by an operator in response to a specific event
- Not naturally idempotent across the fleet (otherwise: Ansible)
- Does not provision new infrastructure (otherwise: OpenTofu)
- Does not install fleet-wide baseline software (otherwise: Ansible)

When a script recurs across many hosts, promote it to an Ansible role
in `automation` — do not scale it horizontally here.

## Catalogue layout

The catalogue is empty today. The tree below is the **suggested**
layout — create the matching directory the first time a script in that
category arrives, not before. Avoid catch-all bins (`misc/`, `utils/`).

```
runbooks/   # suggested categories (none exist on disk yet)
├── storage/        # LVM, filesystem, disk
├── certificates/   # TLS / PKI helpers
├── logs/           # Log rotation triage, journal vacuums
├── network/        # Ad-hoc DNS / firewall / routing checks
└── recovery/       # Manual rollback, breakglass scripts
```

## Script conventions

| Concern | Convention |
|---------|-----------|
| Shebang | `#!/usr/bin/env bash` |
| Safety | `set -euo pipefail` |
| Idempotency | Safe to re-run when the procedure permits; document when it does not |
| Configuration | Environment variables with sensible defaults; document every variable in `usage()` |
| Logging | `log` / `warn` / `err` helpers, not raw `echo` |
| Quoting | Quote every variable expansion (`"${VAR}"`) |
| Scope | `local` for function-scoped variables |
| Dependencies | Validate at startup with `command -v` |
| Dry-run | Support `DRY_RUN=1` where applicable |
| Help | `-h | --help` prints usage and exits 0 |
| Exit codes | `0` success, `1` runtime error, `2` invalid argument |
| Secrets | Never hardcoded; HTTPS downloads; verify checksums |

## Notes for AI assistants

- Add a script here only when no companion repository is a better fit;
  propose the placement to the user when in doubt.
- Keep each script self-contained — no shared helper library until the
  catalogue clearly demands one.
- Document **why** the procedure exists at the top of the script. The
  reader is an operator at 03:00 who has never seen this script before.
- Never commit secrets, credentials, or tokens; check `git diff` before
  proposing a commit.
