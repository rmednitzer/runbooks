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
| R-5 | Validate/­noglob the `RESOLVERS` split in `network/dns-propagation-check.sh:163-164` | audit/02 | low | S | `set -f` around the split, or per-token IP validation reusing `is_ip_literal` from `recovery/unlock-account.sh`. Add a bats case for a `*`-bearing value. | platform/SRE |
| R-6 | Quote/­noglob the `PORT` split in `network/port-reachability.sh:160` | audit/02 | low (nit) | S | Mitigated by the existing `^[0-9]+$` per-token check; tighten only for consistency. | platform/SRE |
| R-7 | Constrain `AIDE_CONF` to a trusted path in `recovery/aide-acknowledge.sh` | audit/02 | low (nit) | S | Assert an absolute path under `/etc/aide/` (or warn otherwise). | platform/SRE |

## Resolved

| Id | Item | Origin | Resolved by |
|----|------|--------|-------------|
| R-1 | Single-node Talos guards bypassed by whitespace-separated `NODES` (split-brain / double-wipe) | audit 2026-06-13 | commit `d2edab4` (this pass): guard widened to reject comma OR whitespace in etcd-restore/reset-node/etcd-snapshot/upgrade-node + bats cases |
| R-2 | `rotate-cert.sh` install modes unvalidated -> private key could be installed world-readable | audit 2026-06-13 | commit `b48ca95` (this pass): octal-format + no-other-access validation on `KEY_MODE`/`CERT_MODE` + bats cases |
| R-3 | Format-validate `VG`/`LV`/`SIZE` in `storage/extend-lvm.sh` before they reach privileged LVM commands | audit/02 | 2026-09-13 audit pass: `validate_lvm_name` (LVM charset, no leading `-`, not `.`/`..`) and `validate_size` (unit grammar vs percentage grammar) run before any LVM tool; exit 2 on anything else. Fixing this also surfaced that the documented `SIZE=+100%FREE` form was being passed to `-L`, which lvextend rejects; percentage forms now go to `-l`. bats cases for accept/reject and for the `-l`/`-L` split |
| R-4 | Validate `VG` before `pvs --select "vg_name=${VG}"` (`storage/extend-lvm.sh:240`) | audit/02 | Folded into R-3 (same pass): `VG` is validated at startup, before the `--select` expression is built |
