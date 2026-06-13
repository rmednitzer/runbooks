# Phase 2/3 — Security and quality findings register (`runbooks`)

Audit pass: `audit/2026-06-13-full-pass`. Schema: ID, title, severity, location,
evidence, exploit-plausibility, disposition. Severity: critical / high / medium
/ low / info.

## Threat model note

These are **operator-run, root-level** scripts. Their environment variables are
supplied by the operator, not by an external attacker — so most "injection"
surfaces are not remotely reachable. The relevant bar is the repo's own
convention (`CLAUDE.md`): defensive coding, input validation, and safety guards
on destructive operations. Findings are graded against that bar, with
exploit-plausibility stated honestly.

## Coverage (this session)

| Area | Method | Result |
|------|--------|--------|
| Lint | `shellcheck -x --enable=all` (17 scripts + helper) | 0 |
| Format | `shfmt -i 2 -ci -sr -d` | 0 |
| Behaviour | `bats tests/` | 169/169 (post-fix) |
| Secrets | `gitleaks detect` history (29 commits) + working tree | 0 |
| Manual review | Every script read; `ai-triage.sh` (LLM/inference surface) and the destructive Talos scripts read line-by-line | see findings |

## Findings and disposition

### FIXED this pass

#### R-1 — Single-node Talos guards bypassed by whitespace-separated `NODES`
- Severity: medium (safety-critical on destructive scripts)
- Location: `talos/etcd-restore.sh:195`, `talos/reset-node.sh:186`,
  `talos/etcd-snapshot.sh:129`, `talos/upgrade-node.sh:165`
- Evidence: each guarded with `[[ "${NODES}" == *,* ]]` (comma only) while the
  header/usage documents "exactly one node" / split-brain prevention. A value
  like `NODES="10.0.0.2 10.0.0.3"` passed the comma-only check.
- Exploit-plausibility: not remote; an operator copy-pasting a space-separated
  node list could bypass the guard on `etcd-restore` (bootstrap two nodes ->
  split brain) or `reset-node` (wipe two nodes).
- Fix: widened the guard to `[[ "${NODES}" =~ [[:space:],] ]]` (comma OR
  whitespace) in all four scripts; added a space-separated bats case to each.
  Commit `d2edab4`. Strictly more conservative — rejects more input, never less.

#### R-2 — `rotate-cert.sh` install modes unvalidated (private-key exposure)
- Severity: medium
- Location: `certificates/rotate-cert.sh` (`CERT_MODE`/`KEY_MODE` -> `chmod`)
- Evidence: `key_mode="${KEY_MODE:-0600}"` then `chmod "${key_mode}" "${TMP_KEY}"`
  with no validation. `KEY_MODE=0644` (a plausible typo) installs the private
  key world-readable.
- Exploit-plausibility: operator misconfiguration leading to a secret on disk
  readable by every local user; not remote.
- Fix: validate both modes are octal (`^[0-7]{3,4}$`) and refuse a key mode
  granting any bit to "other" (`0600`/`0640`/`0400` still allowed — the
  `ssl-cert` group pattern is preserved). Added bats coverage. Commit `b48ca95`.

### DEFERRED to BACKLOG.md (defensive hardening; operator-supplied, root-only)

| ID | Title | Severity | Why deferred |
|----|-------|----------|--------------|
| R-3 | `extend-lvm.sh` does not format-validate `VG`/`LV`/`SIZE` before use in privileged LVM commands (`storage/extend-lvm.sh:163-184,256`) | low | Backstopped by the `lvs --noheadings -- "${lv_path}"` existence check (exits 1 on a bad name) and `lvextend`'s own parse; a strict `SIZE` regex risks rejecting valid LVM size forms (`+10G`, `80%FREE`). Needs care + tests. |
| R-4 | `extend-lvm.sh:240` injects `vg_name=${VG}` into `pvs --select` (LVM filter, not shell) without VG name validation | low | Only reachable with `PV_RESIZE=1`; not shell injection. Fix is the same VG-name validation as R-3. |
| R-5 | `dns-propagation-check.sh:163-164` splits `RESOLVERS` with an unquoted loop; a `*` in the value could glob-expand | low | `dig` rejects non-IP resolver args; cosmetic unless the operator sets a glob. Fix: `set -f` around the split or per-token IP validation (reuse `unlock-account.sh`'s `is_ip_literal`). |
| R-6 | `port-reachability.sh:160` unquoted port-list split | low (nit) | Each token is immediately validated `^[0-9]+$`, which is a sufficient mitigation. |
| R-7 | `aide-acknowledge.sh` does not constrain `AIDE_CONF` to a trusted path | low (nit) | Operator-only, root; self-inflicted misconfiguration only. |

### REVIEWED — NOT a defect (rejected agent suggestions)

- **`rotate-cert.sh` `bash -c "${RELOAD_CMD}"`** (lines 363/394/410): this is the
  script's documented contract — `RELOAD_CMD` IS an operator-provided shell
  command (e.g. `nginx -t` / `nginx -s reload`), the same trust model as a cron
  entry or systemd `ExecReload`. The operator is the trusted party. Not an
  injection defect; no change.
- **`disk-usage-triage.sh` empty `NICE_PREFIX[@]`**: `"${arr[@]}"` on an empty
  array expands to zero words (not an empty argument), so the command is plain
  `du …`. Correct as written.
- **`etcd-restore.sh` `FORCE=1`**: skips the typed `RECOVER` prompt but the
  SHA-256 checksum verification still runs unconditionally first. Safe by design.

## Secrets

`gitleaks detect` over 29 commits of history and the working tree: **0 leaks**.
`.gitleaks.toml` extends the default ruleset and allowlists exactly one
documented false positive, scoped by an anchored line regex (not a path). Sound.

No stop conditions encountered.
