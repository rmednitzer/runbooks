# runbooks

Ad-hoc operator shell scripts for fleet tasks that don't fit
configuration management or infrastructure-as-code — disk and filesystem
work, certificate renewal triggers, log triage, manual rollback,
breakglass, ad-hoc network triage, and Talos Linux cluster operations.

Companion repositories:
[`infra`](https://github.com/rmednitzer/infra) (OpenTofu provisioning),
[`automation`](https://github.com/rmednitzer/automation) (Ansible
hardening + SRE toolchain installer).

## Categories

| Directory | Scope | Key dependency |
|-----------|-------|----------------|
| `storage/` | LVM, filesystem, disk triage | LVM2, GNU coreutils |
| `certificates/` | TLS / PKI: expiry spot-checks, certificate rotation | openssl |
| `logs/` | systemd journal vacuums | journalctl |
| `recovery/` | fail2ban / faillock / AIDE breakglass | per-script |
| `network/` | DNS propagation, port reachability, conntrack | dig / nc / conntrack |
| `talos/` | Talos Linux cluster ops (health, etcd backup/restore, upgrade, reset) | **talosctl** |
| `secops/` | AI-assisted security-signal triage via local inference | python3 / journalctl |

**Talos has no SSH.** Talos Linux is an API-only, immutable OS — no SSH,
no shell, no PAM, no on-node package manager. Everything is done over the
Talos gRPC API (mTLS) with the **`talosctl`** client and a **talosconfig**.
The `talos/` scripts honour `TALOSCONFIG` (and `NODES` / `ENDPOINTS` /
`CONTEXT`) and run on an operator workstation, not on the nodes. The
destructive ones (`etcd-restore.sh`, `reset-node.sh`) are `DRY_RUN`-first
with explicit typed confirmations — read each header before running.

The scripts target **Ubuntu 24.04 *and* 26.04 LTS**; see
[`CLAUDE.md`](./CLAUDE.md) for the 26.04 `uutils`-coreutils note.

## Placement

A script belongs here when it is run manually in response to a specific
event, is not idempotent enough for an Ansible role, does not provision
new infrastructure, and does not enforce baseline configuration. Once a
procedure recurs across many hosts, promote it to an Ansible role in
`automation` rather than scaling horizontally here.

The catalogue layout and full script conventions live in
[`CLAUDE.md`](./CLAUDE.md) — single source of truth.

## Development

```bash
pip install pre-commit && pre-commit install
pre-commit run --all-files
```

Behaviour is covered by a [bats](https://github.com/bats-core/bats-core)
suite under [`tests/`](./tests/): each script's `-h`/`--help`, argument
validation, and `DRY_RUN` paths (against PATH-shimmed fake binaries, so a
destructive tool is never invoked), plus unit tests for the extracted
validators. With `bats-core` and [`just`](https://github.com/casey/just)
installed:

```bash
just test    # bats tests/
just lint    # shellcheck -x
just fmt     # shfmt -i 2 -ci -sr -d
just check   # all three
```

CI ([`.github/workflows/lint.yml`](./.github/workflows/lint.yml)) mirrors
this — shellcheck, shfmt, EditorConfig, hygiene (via pre-commit) and the
bats suite. PRs cannot merge with failing CI.

## Governance

| File | Purpose |
|------|---------|
| [`CLAUDE.md`](./CLAUDE.md) | Script conventions, placement decision tree |
| [`CONTRIBUTING.md`](./CONTRIBUTING.md) | Branch naming, local loop, PR expectations |
| [`CHANGELOG.md`](./CHANGELOG.md) | Keep a Changelog 1.1.0 |
| [`CODE_OF_CONDUCT.md`](./CODE_OF_CONDUCT.md) | Contributor Covenant 2.1 |
| [`.github/SECURITY.md`](./.github/SECURITY.md) | Vulnerability reporting |
| [`.github/CODEOWNERS`](./.github/CODEOWNERS) | Automatic reviewer assignment |
| [`.github/dependabot.yml`](./.github/dependabot.yml) | Weekly GitHub Actions update PRs |
| [`.github/ISSUE_TEMPLATE/`](./.github/ISSUE_TEMPLATE/) | Bug / feature / documentation forms |
| [`.github/PULL_REQUEST_TEMPLATE.md`](./.github/PULL_REQUEST_TEMPLATE.md) | PR checklist |
| [`LICENSE`](./LICENSE) / [`NOTICE`](./NOTICE) | Apache 2.0 |
