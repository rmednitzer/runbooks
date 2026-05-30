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

Four of the five suggested categories exist today; `network/` does not —
create the matching directory the first time a script in that category
arrives, not before. Avoid catch-all bins (`misc/`, `utils/`).

```
runbooks/
├── storage/        # LVM, filesystem, disk  (extend-lvm, disk-usage-triage)
├── certificates/   # TLS / PKI helpers      (check-cert-expiry)
├── logs/           # Journal vacuums        (journal-vacuum)
├── recovery/       # Rollback, breakglass   (unlock-account, aide-acknowledge)
├── network/        # Ad-hoc DNS / firewall / routing  (none yet — create on first use)
└── tests/          # bats suite + shared helpers (one .bats per script)
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
| Traps | `trap 'err "failed at line $LINENO"; exit 1' ERR`; add an `EXIT` cleanup trap wherever a `mktemp` file exists |
| Tests | A bats test in `tests/` per script: `-h`/`--help`, bad/missing env, and `DRY_RUN` via PATH-shimmed fakes (never call the real tool) |

### Platform assumptions

These scripts target **bash ≥ 4 on GNU/Linux** and say so in each
header. They rely on bash-isms — `[[ … ]]`, `[[ =~ ]]` regex matches,
arrays, `${EUID}`, `mapfile`, `BASH_REMATCH` — and on **GNU coreutils /
findutils** behaviour (`df --output`/`-x`, `du --max-depth`, `find
-printf`, `date -d`, `numfmt`, `timeout`). They are **not** expected to
run under POSIX `sh`, BusyBox, or BSD userland; validate GNU-specific
flags at startup with `command -v` (and feature-probe `date -d` where it
matters). Source-guard `main` behind
`[[ "${BASH_SOURCE[0]}" == "${0}" ]]` so the bats suite can source a
script to unit-test its helpers without executing it.

## Notes for AI assistants

- Add a script here only when no companion repository is a better fit;
  propose the placement to the user when in doubt.
- Keep each script self-contained — no shared helper library until the
  catalogue clearly demands one.
- Document **why** the procedure exists at the top of the script. The
  reader is an operator at 03:00 who has never seen this script before.
- Never commit secrets, credentials, or tokens; check `git diff` before
  proposing a commit.
