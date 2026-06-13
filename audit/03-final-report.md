# Audit final report — `runbooks` (2026-06-13)

Branch: `audit/2026-06-13-full-pass`. Base: `82f2922` (#26).

## Executive summary

`runbooks` is a mature, well-conventioned shell catalogue. The full gate suite
was green at baseline. A line-by-line review of all 17 scripts (with special
attention to the AI-triage and destructive Talos scripts) surfaced **two
medium-severity defensive defects, both fixed this pass with tests**, plus five
low-severity hardening items deferred to `BACKLOG.md`. No critical or high
findings; no secrets.

## Baseline vs post-fix metrics

| Metric | Baseline | Post-fix |
|--------|----------|----------|
| shellcheck `--enable=all` | clean | clean |
| shfmt | clean | clean |
| bats | 163/163 pass | **169/169 pass** (+6 new tests) |
| gitleaks (history + tree) | 0 | 0 |
| Security findings (fixed) | — | 2 (R-1, R-2) |
| Security findings (deferred) | — | 5 (R-3..R-7, low) |

## Commits in this pass

| Commit | Rationale |
|--------|-----------|
| `d2edab4` | `security:` reject whitespace-separated `NODES` in the four single-node Talos guards (was comma-only); +4 bats cases |
| `b48ca95` | `security:` validate `CERT_MODE`/`KEY_MODE` octal + refuse other-accessible private key in `rotate-cert.sh`; +2 bats cases |
| (docs commit) | `docs:` audit evidence pack + `BACKLOG.md` |

Each fix was followed by the full gate (shellcheck + shfmt + bats); all green.

## Residual risk statement

Residual risk is **low**. The two real safety defects are fixed and covered by
tests. The five deferred items (R-3..R-7) are defensive-coding gaps in
operator-run, root-level scripts whose inputs are operator-supplied (not
attacker-reachable) and which have existing backstops (the LVM existence check,
the per-token port validation, `dig`'s own arg rejection). They are tracked in
`BACKLOG.md` with concrete approaches; the main reason for deferral is that a
strict input regex (especially for LVM `SIZE`) risks rejecting valid forms and
needs its own accept/reject test matrix.

The `ai-triage.sh` log-data-to-LLM path is an inherent prompt-injection surface
(untrusted log lines flow into a model prompt), but the model is LOCAL, the
script is read-only, the endpoint is operator-controlled, and the output is
advisory to a human operator. This is a documented, accepted limitation, not a
fixable code defect.

## Top 5 backlog items

1. **R-3** — Format-validate `VG`/`LV`/`SIZE` in `extend-lvm.sh` (low, M).
2. **R-5** — Validate/noglob the `RESOLVERS` split in `dns-propagation-check.sh` (low, S).
3. **R-4** — Validate `VG` before the `pvs --select` filter (low, S; folds into R-3).
4. **R-7** — Constrain `AIDE_CONF` to a trusted path in `aide-acknowledge.sh` (low, S).
5. **R-6** — Quote/noglob the `PORT` split in `port-reachability.sh` (low nit, S).

## Stop conditions

None encountered. The test suite runs; no secrets in tree or history; no fix
required a major version bump or migration; no untrusted repo content attempted
to redirect the audit. The two fixes are strictly conservative (reject more
input) and fully tested, so the baseline did not regress.
