# Changelog

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Optimise and rewrite every `.md` file end-to-end for tighter prose,
  consistent voice, and uniform structure across the three companion
  repos: `README.md`, `CLAUDE.md`, `CONTRIBUTING.md`,
  `.github/SECURITY.md`, `.github/PULL_REQUEST_TEMPLATE.md`,
  `.github/copilot-instructions.md`. The placement decision tree, the
  catalogue tree, the script convention list, and the placement-to-
  Ansible promotion rule all stay; the prose around them is shorter and
  more imperative. No policy or workflow change.

## [0.0.0]

- Initial governance scaffolding: `NOTICE`, `.editorconfig`, `.gitignore`,
  `.github/SECURITY.md`, `.pre-commit-config.yaml`, `CHANGELOG.md`,
  `CONTRIBUTING.md`.
- `.github/workflows/lint.yml` running shellcheck, shfmt, EditorConfig,
  and standard hygiene hooks.
