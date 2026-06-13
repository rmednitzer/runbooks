# Backlog — deferred and tracked work

Deferred items raised by an audit or review and intentionally postponed. Each
is real but lower-priority; close an item by linking the PR/commit that resolves
it and moving it to **Resolved**. Created by the 2026-06-13 audit pass.

## Open

### Security / defensive hardening

These are defensive-coding gaps in operator-run, root-level scripts. Their
environment variables are operator-supplied (not attacker-reachable), and each
has an existing backstop, so they are deferred rather than fixed inline — a
strict input regex risks rejecting valid forms and needs its own tests.

| Id | Item | Origin | Severity | Effort | Suggested approach | Owner |
|----|------|--------|----------|--------|--------------------|-------|
| R-3 | Format-validate `VG`/`LV`/`SIZE` in `storage/extend-lvm.sh` before they reach privileged LVM commands | [audit/02-security-findings.md](audit/02-security-findings.md) | low | M | Validate `VG`/`LV` against the LVM name charset (`[a-zA-Z0-9+_.][a-zA-Z0-9+_.-]*`, reject leading `-`); validate `SIZE` against the lvextend forms (`^[+-]?[0-9]+(\.[0-9]+)?[kKmMgGtTpPeE]?[iI]?[bB]?$` and the `N%{VG,FREE,PVS,ORIGIN}` forms). Add bats cases for accept/reject. | platform/SRE |
| R-4 | Validate `VG` before `pvs --select "vg_name=${VG}"` (`storage/extend-lvm.sh:240`) | audit/02 | low | S | Folds into R-3's VG-name validation. | platform/SRE |
| R-5 | Validate/­noglob the `RESOLVERS` split in `network/dns-propagation-check.sh:163-164` | audit/02 | low | S | `set -f` around the split, or per-token IP validation reusing `is_ip_literal` from `recovery/unlock-account.sh`. Add a bats case for a `*`-bearing value. | platform/SRE |
| R-6 | Quote/­noglob the `PORT` split in `network/port-reachability.sh:160` | audit/02 | low (nit) | S | Mitigated by the existing `^[0-9]+$` per-token check; tighten only for consistency. | platform/SRE |
| R-7 | Constrain `AIDE_CONF` to a trusted path in `recovery/aide-acknowledge.sh` | audit/02 | low (nit) | S | Assert an absolute path under `/etc/aide/` (or warn otherwise). | platform/SRE |

## Resolved

| Id | Item | Origin | Resolved by |
|----|------|--------|-------------|
| R-1 | Single-node Talos guards bypassed by whitespace-separated `NODES` (split-brain / double-wipe) | audit 2026-06-13 | commit `d2edab4` (this pass): guard widened to reject comma OR whitespace in etcd-restore/reset-node/etcd-snapshot/upgrade-node + bats cases |
| R-2 | `rotate-cert.sh` install modes unvalidated -> private key could be installed world-readable | audit 2026-06-13 | commit `b48ca95` (this pass): octal-format + no-other-access validation on `KEY_MODE`/`CERT_MODE` + bats cases |
