# Contributing

1. Create a branch from `main`.
2. Keep Tart CLI arguments in `TartRCore.TartCommand` instead of constructing shell strings.
3. Add or update tests for parser, state, command, catalog, or validation changes.
4. Run `make check` before opening a pull request.
5. Update `CHANGELOG.md` for user-visible changes.

Do not commit `.build`, `outputs`, Developer ID certificates, notarization credentials, VM images, or logs.

