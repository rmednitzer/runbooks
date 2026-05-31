# Changelog

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `secops/ai-triage.sh` — AI-assisted security-signal triage via **local
  inference**. Gathers recent host security signals (auditd auth/account
  events, fail2ban bans, ufw/kernel drops, warning-and-above journal lines)
  and asks a local Ollama endpoint to triage them into an assessment +
  severity, correlated events, benign-vs-suspicious reasoning, and operator
  next steps. Read-only; the signals stay on-prem (the `automation` `ollama`
  role / POL-004 sovereignty stance), with `DRY_RUN=1` to inspect exactly what
  would be sent before contacting any endpoint. Pluggable `SOURCE` (host
  default; `siem` is a documented stub). Degrades gracefully when the endpoint
  is unset/unreachable (still prints the raw signals). Adds the new `secops/`
  category, a 10-case bats suite, and justfile/README/CLAUDE entries.
- **Server-side secret scanning in CI** — a dedicated `secret scan (gitleaks)`
  job in `.github/workflows/lint.yml` runs `gitleaks dir` over the full working
  tree on every push/PR. The image is pinned by immutable digest (gitleaks
  `v8.30.1`, the same version as the pre-commit hook and the companion repos),
  matching the SHA-pinning posture of the actions in that workflow. The
  `gitleaks` pre-commit hook scans only STAGED changes
  (`pass_filenames: false`; `gitleaks git --pre-commit --staged`), so it is a
  no-op in a clean CI checkout — the earlier note that it was "mirrored by CI"
  was inaccurate. This job is the real server-side enforcement, and matches the
  mechanism added to the `infra` repo.
- `.gitleaks.toml` — extends gitleaks' default ruleset (`useDefault`) and
  allowlists one confirmed false positive: the `generic-api-key` heuristic fires
  on a `local` declaration in `dns-propagation-check.sh` whose variable name
  contains "key" (`majority_key`) — a bash identifier, not a credential. Scoped
  to that exact, anchored source line, so a secret on any other line (or
  appended to that line) still trips the scan.

### Fixed

- `certificates/check-cert-expiry.sh` was **non-functional**: it passed
  `-connect_timeout` to `openssl s_client` (no such option → "Unknown
  option", silently swallowed by `2>/dev/null`) and a duplicate
  `-connect`, so it failed to retrieve a certificate on every run. The
  connection is now bounded by coreutils `timeout "${CONNECT_TIMEOUT}"`
  around the openssl call (added to the dependency check), the duplicate
  `-connect` is gone, and `CONNECT_TIMEOUT` must be a positive integer.
  Also inspects `notBefore` and warns when the leaf is not yet valid, and
  documents that only the leaf certificate is checked.
- `recovery/unlock-account.sh` IP validation: zero-padded octets such as
  `08`/`09` no longer abort with bash's "value too great for base" (octet
  comparison forced to base-10 and leading-zero octets rejected), and the
  IPv6 branch no longer accepts garbage like `::::` (validated with
  python3's `ipaddress` when available, a stricter regex otherwise).
- `recovery/aide-acknowledge.sh` promoted the wrong database on non-
  default configs: it hardcoded `/var/lib/aide/aide.db.new` instead of
  reading `database_out`/`database_new` (and `database_in`/`database`)
  from `aide.conf` — expanding `@@{DBDIR}` and the `file:` prefix — and
  did not handle the `aide.db.new.gz` produced when `gzip_dbout=yes`
  (the Debian/Ubuntu default). It now derives the real paths, promotes
  whichever of `<db>.new` / `<db>.new.gz` AIDE actually wrote, and
  refuses if the resolved output is outside the live DB's directory.
- `recovery/aide-acknowledge.sh` now rolls back: an `EXIT` trap restores
  the backup over the live DB if the promote fails after the backup is
  taken, the promote is constrained to an atomic same-directory rename
  (no cross-filesystem `mv`), and `sync` is issued afterwards.
- `recovery/aide-acknowledge.sh` no longer streams the full `aide
  --check` diff to the terminal before a blind y/N. It captures the
  report to a `mktemp` file (cleaned via trap), prints a parsed summary
  (added/removed/changed) and the report path, then prompts.
- `storage/extend-lvm.sh` is now atomic: it grows the LV and filesystem
  in one `lvextend --resizefs` (via fsadm) instead of a separate
  `lvextend` + `resize2fs`/`xfs_growfs`, removing the window where the LV
  was larger than its un-grown filesystem; on failure it prints an
  explicit manual-recovery hint. It also refuses thin pools/volumes,
  cache LVs, and snapshots (checked via `lv_attr`), and documents that
  `+SIZE` is additive and re-running repeats the extension.
- `storage/disk-usage-triage.sh` `df` parsing now addresses columns by
  name (`df --output=pcent,target`) so mountpoints containing spaces are
  handled, and drops the `--type=ext*/xfs/btrfs` whitelist (which
  silently skipped zfs/f2fs/bcachefs and produced false "nothing above
  threshold") in favour of excluding pseudo-filesystems with `-x`.
- `logs/journal-vacuum.sh` now measures the before/after delta and warns
  when a vacuum reclaims almost nothing — the case where the space is in
  the active journal file that `--vacuum-*` cannot delete — pointing at
  `journalctl --rotate`. A new `ROTATE=1` performs the rotation first.
- `recovery/unlock-account.sh` unifies its two divergent `DRY_RUN`
  paths: the unban is routed through the `run` family (new `run_ok`
  tolerates the non-zero exit fail2ban returns when an IP is not banned),
  so there is a single DRY_RUN mechanism per script.
- `network/dns-propagation-check.sh` no longer reports a false "OK: all
  resolvers agree" (exit 0) when EVERY resolver returns an empty answer
  (NXDOMAIN/NODATA/SERVFAIL/timeout). The majority-vote logic treated a
  unanimous *non*-answer as agreement; it now detects the all-empty case and
  exits 1 with "no resolver returned an answer", since the record in fact
  resolves nowhere. The `<NO-ANSWER>` sentinel is now a named constant so the
  guard cannot drift from the collector. New bats case covers it.
- `storage/disk-usage-triage.sh` now rejects `TOP_N=0` (exit 2). It passed
  the non-negative-integer check but fed `head`/`tail -n 0`, which print
  nothing — so the triage ran yet reported no directories or files (a silent
  empty page). `TOP_N` must now be ≥ 1. New bats case covers it.
- `secops/ai-triage.sh` now warns — to the operator and inside the gathered
  signals — when `date -d "${SINCE}"` cannot be parsed and the auditd query
  falls back to ausearch's `-ts recent` keyword (~the last 10 minutes). The
  fallback silently narrowed a wide `SINCE` window, so a quiet auditd section
  could be misread as "nothing happened over the window" when that window was
  never searched. New bats case covers it.

### Changed

- Raised the pre-commit/CI shellcheck gate from `--severity=warning` to
  `-x --enable=all`, surfacing the previously hidden info-level findings
  (SC2310 set-e-in-conditionals, SC2312 masked returns, SC2249 missing
  default case). Every script passes at the new level; deliberate
  set-e-disabling-in-`if` sites carry targeted `# shellcheck disable`
  annotations. The "shellcheck-clean" claim is now honest.
- Every script gained a uniform `trap 'err "failed at line $LINENO";
  exit 1' ERR` (plus `EXIT` cleanup traps where temp files exist), is
  source-guarded so the tests can source it, and documents its bash ≥ 4
  and GNU-coreutils assumptions in the header. `CLAUDE.md` records these
  platform assumptions and the trap/test conventions once.
- `storage/disk-usage-triage.sh` runs its `du` walk under `ionice -c3
  nice -n19` when those tools are present, to avoid worsening a
  struggling host.
- **Ubuntu 26.04 readiness.** The catalogue now explicitly targets Ubuntu
  24.04 **and** 26.04 LTS. 26.04 ships `uutils`/`rust-coreutils` as the
  DEFAULT provider for `df`/`du`/`date`/`sort`/`head`/`tail`/`numfmt`
  (only `cp`/`mv`/`rm` stay GNU); uutils implements the GNU flags these
  scripts use, but has known `numfmt --from=iec` discrepancies. No code
  change was needed — `logs/journal-vacuum.sh` already treats `numfmt` as
  optional and degrades safely, and `certificates/check-cert-expiry.sh`
  already feature-probes `date -d`. `CLAUDE.md`'s platform-assumptions
  section documents the 26.04 caveat, the always-present `gnu-coreutils`
  package, and the `coreutils-from-gnu` escape hatch, plus the systemd
  255→259 / cgroup-v1-removal facts (none of which affect these scripts).
- The bats suite grew from 56 to 134 tests with the new `talos/` and
  `network/` scripts (one `.bats` per script; same fake-binary discipline,
  and DRY_RUN tests assert the real `talosctl`/`nc` is never invoked). The
  `justfile` `scripts` list now includes all fifteen scripts so
  `just lint`/`fmt`/`check` stay in sync with CI.

### Added

- A new `talos/` category: operator runbooks for **Talos Linux**, which is
  API-only (no SSH/shell/PAM/package-manager on the node — everything is
  `talosctl` over mTLS using a talosconfig). Each script `command -v
  talosctl`, honours `TALOSCONFIG` / `NODES` / `ENDPOINTS` / `CONTEXT`
  (mapping to the matching `talosctl` flags), documents the no-SSH model
  for a 03:00 operator, and supports `DRY_RUN` on anything that writes.
  - `talos/talos-health-check.sh` — read-only cluster triage: `talosctl
    version` / `get members` / `health --server=false` / `etcd members` +
    `etcd status` / `services` / recent `dmesg`. Exit status follows the
    `health` verdict; a failing telemetry section never aborts the page.
  - `talos/etcd-snapshot.sh` — consistent etcd backup via `talosctl etcd
    snapshot <path>` to a timestamped file, verified non-empty, with a
    SHA-256 sidecar and a printed restore pointer (safe/read-only).
  - `talos/etcd-restore.sh` — guided disaster recovery via `talosctl
    bootstrap --recover-from=<snapshot>`. The most destructive script:
    prominent DANGER header, snapshot checksum verification, a typed
    `RECOVER` confirmation, a split-brain guard (refuses >1 node), and an
    optional `--recover-skip-hash-check` for raw `talosctl cp` copies.
  - `talos/upgrade-node.sh` — `talosctl upgrade --nodes <n> --image <ref>`
    one node at a time, with a pre-flight `talosctl health` gate, image-ref
    shape validation (warns on a mutable tag vs a `@sha256` digest), and
    `--preserve` / `--stage` pass-through.
  - `talos/kubeconfig-rotate.sh` — (re)fetch the admin kubeconfig with
    `talosctl kubeconfig`, backing up any file it overwrites; `MERGE=0`
    maps to `--force`.
  - `talos/reset-node.sh` — `talosctl reset` to wipe a node to maintenance
    mode. EXTREME-danger header, `WIPE` token **and** a second y/N
    confirmation, single-node guard, and `WIPE_MODE` / `SYSTEM_LABELS` /
    `GRACEFUL` / `REBOOT` controls (e.g. `SYSTEM_LABELS=EPHEMERAL
    GRACEFUL=0` for the wipe-etcd-before-recover case).
  All six are validated against the current Talos `talosctl` reference and
  covered by bats using PATH-shimmed fake `talosctl` (usage / exit codes /
  `DRY_RUN`-never-calls-real-talosctl / dependency-missing). `README.md`,
  `CLAUDE.md` (catalogue + the no-SSH paradigm + the talosctl/TALOSCONFIG
  convention), and `.github/CODEOWNERS` updated.
- The `network/` category (previously create-on-first-use) now exists, with
  three read-only triage scripts following the catalogue conventions and
  bats coverage:
  - `network/dns-propagation-check.sh` — query one record across many
    resolvers (a public set UNION `/etc/resolv.conf`) with `dig`, compare
    the sorted answer sets, and flag any resolver that diverges from the
    majority (propagation lag / stale cache / split-horizon). Exits
    non-zero on divergence.
  - `network/port-reachability.sh` — bounded TCP-handshake probe to one or
    more `host:port` from THIS host ("is the firewall blocking X?"), using
    bash `/dev/tcp` by default and falling back to `nc`, each wrapped in
    coreutils `timeout`. Read-only (handshake only, no payload).
  - `network/conntrack-triage.sh` — netfilter conntrack count vs max + the
    `%` used, any `nf_conntrack: table full` drops in the kernel log, and
    the top talkers (by dest port / source IP) from `conntrack -L` or
    `/proc/net/nf_conntrack`. Exits non-zero at/above `WARN_PCT` or on
    logged drops; exits cleanly when conntrack is not in use.
- A [bats](https://github.com/bats-core/bats-core) test harness under
  `tests/` (56 tests): per-script `-h`/`--help`, missing/invalid env,
  and `DRY_RUN` coverage using PATH-shimmed fake binaries (asserting the
  real `lvextend`/`fail2ban-client`/`journalctl`/`openssl` is never
  called), plus unit tests for the extracted validators (the H5 octal /
  IPv6 IP cases; `journal_bytes`; `ensure_plain_lv`). A `justfile`
  (`test`/`lint`/`fmt`/`check`) and a SHA-/tag-pinned `bats` CI job wired
  into `.github/workflows/lint.yml` alongside the existing concurrency
  and timeout.
- Governance scaffolding to match the companion repos: `CODE_OF_CONDUCT.md`
  (Contributor Covenant 2.1), `.github/CODEOWNERS`, `.github/dependabot.yml`
  (weekly `github-actions` updates), and
  `.github/ISSUE_TEMPLATE/{bug_report,feature_request,documentation}.yml`
  tailored to the bash/operator context. `README.md` Governance table and
  the development docs updated accordingly.
- Replaced `LICENSE` with the canonical Apache-2.0 text (the prior copy
  was missing the phrase "reasonable and customary use in" from §6,
  Trademarks); it is now byte-identical to the companion repos' license.

- CI hardening for secret-scan coverage and supply-chain integrity:
  add `gitleaks` to the pre-commit hook set for
  general secret scanning beyond the PEM-only `detect-private-key`;
  pin every GitHub Actions reference in `.github/workflows/lint.yml`
  to a full 40-char commit SHA, per GitHub's security-hardening
  guidance that a full-length commit SHA is "currently the only way
  to use an action as an immutable release"; add `timeout-minutes:
  15` to the lint job and a workflow-level `concurrency` group with
  `cancel-in-progress: true`. The hook set, severity levels, and
  overall gate semantics are unchanged.
- Seed the catalogue with six high-value operator scripts covering four
  of the five suggested categories in `CLAUDE.md`. Each script is
  self-contained, shellcheck/shfmt-clean, documents the WHY for a 03:00
  operator, validates required environment variables, and supports
  `DRY_RUN=1` and `-h | --help`. Exit codes follow the
  `0`/`1`/`2` (success / runtime error / invalid argument) contract.
  - `storage/extend-lvm.sh` — extend an LVM logical volume and grow
    its filesystem (ext{2,3,4} via resize2fs, xfs via xfs_growfs).
    Optional `PV_RESIZE=1` for the case where the hypervisor grew an
    underlying disk.
  - `storage/disk-usage-triage.sh` — one-page disk-full triage:
    largest directories, large files, journal usage, and (via lsof)
    deleted-but-held-open files that du cannot see.
  - `logs/journal-vacuum.sh` — vacuum the systemd journal by age
    (`KEEP_DAYS`) or by size (`KEEP_SIZE`); reports before/after disk
    usage.
  - `certificates/check-cert-expiry.sh` — TLS spot-check via
    `openssl s_client` with optional STARTTLS, SNI, and a configurable
    `THRESHOLD_DAYS` for non-zero exit.
  - `recovery/unlock-account.sh` — clear fail2ban bans across every
    jail and reset pam_faillock counters for a user. Env var is
    `TARGET_USER` rather than `USER` to avoid the always-set shell
    variable collision.
  - `recovery/aide-acknowledge.sh` — accept the current filesystem
    state as the new AIDE baseline after a sanctioned change; keeps a
    timestamped backup of the previous database for rollback.
- Optimise and rewrite every `.md` file end-to-end for tighter prose,
  consistent voice, and uniform structure across the three companion
  repos: `README.md`, `CLAUDE.md`, `CONTRIBUTING.md`,
  `.github/SECURITY.md`, `.github/PULL_REQUEST_TEMPLATE.md`,
  `.github/copilot-instructions.md`. The placement decision tree, the
  catalogue tree, the script convention list, and the placement-to-
  Ansible promotion rule all stay; the prose around them is shorter and
  more imperative. No policy or workflow change.

## [0.0.0]

- Initial governance scaffolding: `NOTICE`, `.editorconfig`, `.gitignore`,
  `.github/SECURITY.md`, `.pre-commit-config.yaml`, `CHANGELOG.md`,
  `CONTRIBUTING.md`.
- `.github/workflows/lint.yml` running shellcheck, shfmt, EditorConfig,
  and standard hygiene hooks.
