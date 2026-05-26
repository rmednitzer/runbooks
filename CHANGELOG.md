# Changelog

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Slim `README.md`: collapse the "When to add" / "When NOT to add" /
  "Layout (proposed)" / "Conventions" sections (which duplicated content
  in `CLAUDE.md`) into a single "Placement" paragraph that defers to
  `CLAUDE.md` as the single source of truth for the catalogue layout and
  script conventions. README drops from 87 to 50 lines; no policy change.
- Add `.github/PULL_REQUEST_TEMPLATE.md`.
- Sync governance docs (SECURITY policy shape, copilot instructions,
  CONTRIBUTING wording, README Governance table) with the companion
  `infra` and `automation` repos.

## [0.0.0]

- Initial governance scaffolding: `NOTICE`, `.editorconfig`, `.gitignore`,
  `.github/SECURITY.md`, `.pre-commit-config.yaml`, `CHANGELOG.md`,
  `CONTRIBUTING.md`.
- `.github/workflows/lint.yml` running shellcheck, shfmt, EditorConfig,
  and standard hygiene hooks.
