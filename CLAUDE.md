# CLAUDE.md — `runbooks`

Ad-hoc operator shell scripts for recurring fleet tasks that do not
belong in configuration management or infrastructure-as-code: LVM
extension, filesystem resize, certificate renewal triggers, log triage,
manual rollback, breakglass, ad-hoc network triage, and Talos Linux
cluster operations (`talosctl`).

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

All categories now exist. Add a new top-level category only when a script
that genuinely belongs in it arrives; avoid catch-all bins (`misc/`,
`utils/`).

```
runbooks/
├── storage/        # LVM, filesystem, disk  (extend-lvm, disk-usage-triage)
├── certificates/   # TLS / PKI helpers      (check-cert-expiry)
├── logs/           # Journal vacuums        (journal-vacuum)
├── recovery/       # Rollback, breakglass   (unlock-account, aide-acknowledge)
├── network/        # Ad-hoc DNS / firewall / routing
│                   #   (dns-propagation-check, port-reachability, conntrack-triage)
├── talos/          # Talos Linux operator runbooks via talosctl
│                   #   (talos-health-check, etcd-snapshot, etcd-restore,
│                   #    upgrade-node, kubeconfig-rotate, reset-node)
├── secops/         # AI-assisted security triage via LOCAL inference
│                   #   (ai-triage)
└── tests/          # bats suite + shared helpers (one .bats per script)
```

### The `talos/` category — the Talos no-SSH paradigm

Talos Linux is an **API-only, immutable** OS: there is **no SSH, no shell,
no PAM, and no package manager on the node**. Every operator action goes
over the Talos gRPC API (mTLS) using the **`talosctl`** client and a
**talosconfig** (client certificate + endpoints). So the usual "ssh in and
run `systemctl`/`apt`/`etcdctl`" reflexes do not apply — the Talos scripts
wrap `talosctl` instead. Conventions specific to this category:

- **Dependency**: every Talos script `command -v talosctl` at startup
  (and `sha256sum` etc. where it writes files). `talosctl` is the one hard
  dependency the rest of the catalogue does not share.
- **TALOSCONFIG**: scripts honour the `TALOSCONFIG` env var (passed
  through as `talosctl --talosconfig`), falling back to talosctl's own
  default (`~/.talos/config`) when unset. They also accept `NODES` /
  `ENDPOINTS` / `CONTEXT` overrides, mapping to `talosctl --nodes /
  --endpoints / --context`. Remember the Talos distinction: **`--endpoints`
  are the control-plane IPs talosctl connects TO; `--nodes` are the
  machines a request is ABOUT**.
- **Destructive ones carry extra guards**: `etcd-restore.sh` (rebuilds
  cluster state — typed `RECOVER` confirmation + snapshot checksum verify)
  and `reset-node.sh` (wipes a node — `WIPE` token **and** a second y/N)
  are the most dangerous; both are `DRY_RUN`-first and refuse to act on a
  list of nodes. `upgrade-node.sh` gates on a pre-flight `talosctl health`.
  Read each header before running — they are written for an operator who
  has never seen Talos.

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

**Target distributions: Ubuntu 24.04 LTS *and* 26.04 LTS.** The scripts
are otherwise distro-agnostic, but 26.04 ("Resolute Raccoon") changes one
load-bearing assumption: it ships **`uutils`/`rust-coreutils` as the
DEFAULT** provider for `df`, `du`, `date`, `sort`, `head`, `tail`,
`numfmt`, etc. (only `cp`/`mv`/`rm` stay GNU). uutils aims to be a drop-in
GNU replacement and implements the flags these scripts use (`df --output`,
`du --max-depth`, `date -d`), but there are **known `numfmt --from=iec`
rounding/parsing discrepancies** vs GNU. Mitigations already in place:

- `logs/journal-vacuum.sh` treats `numfmt` as optional and degrades
  gracefully (the reclaim-delta check is skipped, never wrong, if the
  parse fails) — so a uutils numfmt quirk cannot misreport.
- `certificates/check-cert-expiry.sh` feature-probes `date -d` at startup
  rather than assuming an implementation.
- On 26.04 the **`gnu-coreutils` package is always installed**; if a
  uutils flag ever misbehaves, switch the system back with
  `sudo apt install coreutils-from-gnu` (revert: `coreutils-from-uutils`).

systemd on 26.04 is **259** (24.04 ships 255); the journal tooling
(`journalctl --vacuum-*`, `--rotate`, `--disk-usage`) used here is
unchanged. 26.04 also **removes cgroup v1** — none of these scripts depend
on cgroup v1, so that is not a concern for the catalogue. The `talos/`
scripts run on the operator's workstation (any of the above), not on the
Talos nodes themselves.

## Notes for AI assistants

- Add a script here only when no companion repository is a better fit;
  propose the placement to the user when in doubt.
- Keep each script self-contained — no shared helper library until the
  catalogue clearly demands one.
- Document **why** the procedure exists at the top of the script. The
  reader is an operator at 03:00 who has never seen this script before.
- Never commit secrets, credentials, or tokens; check `git diff` before
  proposing a commit.
