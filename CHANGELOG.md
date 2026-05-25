# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `NOTICE` file for Apache 2.0 source-distribution conformance.
- `.editorconfig` for consistent indentation, charset, and EOL across editors.
- `.gitignore` for editor scratch files, local `.env`, and temporary outputs.
- `.github/SECURITY.md` documenting in-scope concerns and the private-reporting
  workflow.
- `.pre-commit-config.yaml` orchestrating `shellcheck`, `shfmt`,
  EditorConfig conformance, and standard hygiene hooks; mirrored in CI.
- `CONTRIBUTING.md` covering branch naming, the local development loop, and
  the placement rules across `runbooks`, `automation`, and `infra`.
- This `CHANGELOG.md`.

### Changed

- `.github/workflows/lint.yml` now runs `shfmt -d` and `pre-commit` alongside
  the existing `bash -n` and `shellcheck` passes.
- `README.md` indexes the new governance and tooling files.

## [0.0.0] — initial scaffolding

Repository renamed from `scripts` to `runbooks`; the SRE-toolchain installer
moved to `automation/roles/sre_toolchain`. No scripts yet — only documentation
and tooling scaffolding (`CLAUDE.md` conventions, lint CI, Claude / Copilot
guides).
