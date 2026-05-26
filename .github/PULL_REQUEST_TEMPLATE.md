## Description

<!-- What does this PR change, and why? -->

## Type of change

- [ ] New script
- [ ] Bug fix
- [ ] Documentation update
- [ ] CI / tooling change

## Checklist

- [ ] `#!/usr/bin/env bash` shebang and `set -euo pipefail`
- [ ] Variable expansions quoted (`"${VAR}"`)
- [ ] Required dependencies validated with `command -v` at startup
- [ ] `-h | --help` prints a usage block and exits cleanly
- [ ] `DRY_RUN=1` supported where applicable
- [ ] No hardcoded secrets, credentials, or tokens
- [ ] Downloaded artifacts fetched over HTTPS and checksum-verified
- [ ] Header comment documents purpose, requirements, environment
      variables
- [ ] `[Unreleased]` entry added to [`CHANGELOG.md`](/rmednitzer/runbooks/blob/main/CHANGELOG.md)

## Operational context

<!-- Which operator event or runbook scenario motivated this script? -->

## Additional notes

<!-- Anything else worth knowing -->
