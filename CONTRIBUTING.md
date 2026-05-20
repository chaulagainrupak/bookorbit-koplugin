# Contributing to BookOrbit KOReader Plugin

Thanks for your interest in contributing.

This repository hosts the KOReader plugin integration for BookOrbit. Contributions of all sizes are welcome, from typo fixes to major features.

## Before You Start

- Read [README.md](README.md) for current project scope and status.
- Read [SECURITY.md](SECURITY.md) before reporting vulnerabilities.
- Read [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community expectations.

## Issue First, Then PR

For new features and larger behavior changes, open an issue first and wait for maintainer approval before implementation.

- Bug fix for a clear existing issue: usually safe to proceed.
- New feature: open a feature request first.
- Unsure about scope: ask in an issue before coding.

## Workflow

1. Fork the repository and clone your fork.
2. Create a branch from `main`:
   `BO-<issue-number>-<short-description>`
3. Implement one logical change per pull request.
4. Test on KOReader before opening a PR.
5. Open a PR using the repository template and link the issue.

## Testing Expectations

Before requesting review, verify:

- Plugin loads in KOReader without startup errors.
- Main flow for your change works end to end.
- Network failure paths are handled clearly (timeouts/offline/server errors).
- No credentials or secrets are logged.
- Settings changes persist when KOReader restarts (if applicable).

If the change affects UI, include screenshots or a short recording in the PR.

## Pull Request Expectations

- Keep PRs focused. Do not mix unrelated refactors with feature or bug work.
- Describe what changed and why.
- Include exact manual/automated test steps used.
- Highlight non-obvious decisions or trade-offs.

## Commit Guidance

Conventional Commit style is preferred:

`<type>(<scope>): <summary>`

Examples:

- `feat(sync): add initial authentication flow`
- `fix(ui): handle empty state in book link dialog`
- `docs(readme): clarify plugin install path`

## Dependencies

Do not add new dependencies without prior discussion in the linked issue. Keep the plugin lightweight and KOReader-compatible.

## License

By contributing, you agree that contributions are licensed under the same project license (AGPL-3.0).
