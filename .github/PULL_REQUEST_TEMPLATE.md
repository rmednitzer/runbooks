## Description

<!-- Describe the changes in this PR -->

## Type of Change

- [ ] New script
- [ ] Bug fix
- [ ] Documentation update
- [ ] CI / tooling change

## Checklist

- [ ] Shebang is `#!/usr/bin/env bash` and the script uses
      `set -euo pipefail`
- [ ] Variable expansions are quoted (`"${VAR}"`)
- [ ] Required dependencies are validated with `command -v` at startup
- [ ] `-h | --help` prints a usage block and exits cleanly
- [ ] `DRY_RUN=1` is supported where applicable
- [ ] No hardcoded secrets, credentials, or API tokens
- [ ] Downloaded artifacts are fetched over HTTPS and checksum-verified
- [ ] `[Unreleased]` entry added to [`CHANGELOG.md`](/rmednitzer/runbooks/blob/main/CHANGELOG.md)
- [ ] Header comment block documents purpose, requirements, and
      environment variables

## Operational Context

<!-- Reference the operator event or runbook scenario that motivated
     this script -->

## Additional Notes

<!-- Any other context about this PR -->
