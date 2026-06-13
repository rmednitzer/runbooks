# Phase 1 — Validation baseline (`runbooks`)

Audit pass: `audit/2026-06-13-full-pass`. Read-only phase. Regression
reference for any later change in this pass. All commands run this session
against branch base `82f2922`. bats-core v1.13.0 (the pinned version) was
installed this session so the suite is executed, not inferred.

## Lint — shellcheck

```
$ shellcheck -x --enable=all <all 17 *.sh> tests/helpers/common.bash
$ echo $?
0
```

Result: **clean** (exit 0). Local shellcheck is 0.9.0; CI pins 0.11.0.1. The
`--enable=all` flag surfaces the optional info-level checks (SC2310, SC2312,
SC2249) so the "shellcheck-clean" claim is honest; deliberate set-e sites carry
targeted in-script `# shellcheck disable=` annotations.

`[UNVERIFIED]` delta: the 0.11.0.1 ruleset may add checks not present in 0.9.0.
Local result is a lower bound; CI runs the pinned newer version.

## Format — shfmt

```
$ shfmt -i 2 -ci -sr -d <all *.sh + *.bash>
$ echo $?
0
```

Result: **clean** (no diff, exit 0). Same flags as the pre-commit hook.

## Tests — bats

```
$ bats tests/
1..163
... (163 ok, 0 not ok)
$ echo $?
0
```

Result: **163 passed, 0 failed** across the 17 test files. The suite is
deterministic: every external binary (`talosctl`, `openssl`, `lvextend`,
`fail2ban-client`, `date`, etc.) is replaced by a PATH-shimmed fake, so no
real fleet/cluster action occurs and there are no flaky candidates. Each
script's suite covers `-h/--help` (exit 0), missing/invalid env (exit 2), and
`DRY_RUN` behaviour, plus helper unit tests (e.g. `unlock(is_ip_literal)`
H5 octal/IPv6 cases).

Coverage tooling: none for bash; the suite's per-script structure is the
coverage proxy. No line-coverage metric is expected for a shell catalogue.

## Security tooling (cross-referenced in Phase 2)

| Tool | Command | Result |
|------|---------|--------|
| gitleaks (history) | `gitleaks detect --redact` | 29 commits scanned, **no leaks** |
| gitleaks (working tree) | `gitleaks detect --no-git --redact` | **no leaks** |

## CI drift

The three commands above mirror the CI jobs (`pre-commit` runs shellcheck +
shfmt with these exact args; `bats` runs `bats tests/`; `secret-scan` runs
gitleaks over the tree). Divergences: shellcheck version (0.9.0 local vs
0.11.0.1 CI) and gitleaks build (dev vs pinned v8.30.1) — both report clean.
No behavioral drift between CI config and what runs.

## Baseline summary

| Gate | Result |
|------|--------|
| shellcheck `--enable=all` | clean (exit 0) |
| shfmt | clean (exit 0) |
| bats | 163/163 pass |
| gitleaks | 0 (history + working tree) |

The repository is **green across every reproducible gate.**
