# justfile — local task runner for runbooks.
#
# Install just:  https://github.com/casey/just  (cargo install just, or a
# distro package). Targets mirror what CI runs in
# .github/workflows/lint.yml so "green locally" means "green in CI".
#
#   just            # list targets
#   just lint       # shellcheck every script (via pre-commit's pinned ver)
#   just fmt        # shfmt formatting check (repo style: -i 2 -ci -sr)
#   just fmt-fix    # rewrite files in place to the canonical format
#   just test       # run the bats suite
#   just check      # lint + fmt + test (the full gate)

# The catalogue scripts, kept in one place so targets stay in sync.
scripts := "certificates/check-cert-expiry.sh recovery/unlock-account.sh recovery/aide-acknowledge.sh storage/extend-lvm.sh storage/disk-usage-triage.sh logs/journal-vacuum.sh network/dns-propagation-check.sh network/port-reachability.sh network/conntrack-triage.sh talos/talos-health-check.sh talos/etcd-snapshot.sh talos/etcd-restore.sh talos/upgrade-node.sh talos/kubeconfig-rotate.sh talos/reset-node.sh secops/ai-triage.sh"

# Default: show the available targets.
default:
    @just --list

# Lint every script with shellcheck. Mirrors the CI/pre-commit gate
# (-x follows sources; --enable=all surfaces info-level checks).
lint:
    shellcheck -x --enable=all {{ scripts }}

# Format check (repo style: -i 2 -ci -sr, same flags as pre-commit).
fmt:
    shfmt -d -i 2 -ci -sr {{ scripts }}

# Rewrite scripts in place to the canonical format.
fmt-fix:
    shfmt -w -i 2 -ci -sr {{ scripts }}

# Run the bats test suite. Requires bats-core on PATH.
test:
    bats tests/

# The full local gate: lint + format check + tests.
check: lint fmt test
