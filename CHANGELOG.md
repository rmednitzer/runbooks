# Changelog

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Slim `CONTRIBUTING.md`, `CHANGELOG.md`, `.github/SECURITY.md`, and the
  README Governance section; consolidate the lint workflow into a single
  pre-commit job (no change to hook coverage).

## [0.0.0]

- Initial governance scaffolding: `NOTICE`, `.editorconfig`, `.gitignore`,
  `.github/SECURITY.md`, `.pre-commit-config.yaml`, `CHANGELOG.md`,
  `CONTRIBUTING.md`.
- `.github/workflows/lint.yml` running shellcheck, shfmt, EditorConfig,
  and standard hygiene hooks.
- Repository renamed from `scripts`; SRE-toolchain installer moved to
  `automation/roles/sre_toolchain`.
