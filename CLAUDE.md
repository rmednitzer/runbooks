# CLAUDE.md

This repository contains utility scripts for SRE/Platform/Security toolchain setup and management.

## Repository Structure

- `Software/` — Installation and setup scripts (e.g., `install_binaries.sh`)
- `.github/` — GitHub configuration including Copilot instructions

## Conventions

- All bash scripts use `#!/usr/bin/env bash` with `set -euo pipefail`
- Scripts are idempotent by default (safe to re-run)
- Configuration via environment variables with sensible defaults
- Use `log()` helpers for output, not raw `echo`
- Quote all variable expansions: `"${VAR}"`
- Use `local` for function-scoped variables
- Validate dependencies early with `command -v` checks
- Support `DRY_RUN` mode where applicable
- Never hardcode secrets; use HTTPS for downloads; verify checksums
