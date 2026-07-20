# Changelog

All notable changes to TartR are documented here.

## 4.0.0 - 2026-07-20

### Added

- Production Swift Package with a reusable `TartRCore` module
- Automatic Tart installation guidance and official quick-start link
- Built-in catalog of 15 official Cirrus Labs macOS images
- Clone, rename, delete, configure, IP, suspend, macOS create and Linux create actions
- VM disk capacity and allocated-size display
- Universal arm64/x86_64 release build
- Developer ID signing, notarization and checksum scripts
- Core unit tests and CI workflow

### Changed

- VM state is sourced from `tart list --source local --format json`
- Tart is invoked directly from known paths; login-shell resolution is fallback-only
- Polling interval is five seconds and refreshes immediately when the app becomes active
- Command output uses bounded temporary files to avoid pipe EOF and buffer deadlocks

### Security

- Destructive deletion now requires typing the exact VM name
- Tart arguments remain separated from shell interpretation
- Application and per-VM logs rotate automatically

