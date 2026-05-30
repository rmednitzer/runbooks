# Changelog

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

### Added

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
  add `gitleaks` to the pre-commit hook set (mirrored by CI) for
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
