# Releasing TartR

## Required GitHub secrets

- `DEVELOPER_ID_CERTIFICATE_BASE64`: base64-encoded Developer ID Application `.p12`
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`: password protecting the `.p12`
- `DEVELOPER_ID_APPLICATION`: complete codesign identity string
- `KEYCHAIN_PASSWORD`: random password for the temporary CI keychain
- `APPLE_ID`: Apple Developer account email
- `APPLE_TEAM_ID`: Apple Developer Team ID
- `APPLE_APP_PASSWORD`: app-specific password used by `notarytool`

An Apple Development certificate is not sufficient for a notarized build. The certificate must be a valid **Developer ID Application** identity.

When these secrets are incomplete, the workflow intentionally falls back to a verified ad-hoc signed build. The GitHub Release prominently warns that Gatekeeper approval may be required. This keeps tagged releases reproducible while making the distribution trust level explicit.

## Release process

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
2. Add the release section to `CHANGELOG.md`.
3. Install the current Tart release, then run `make check`, `make compat`, `make build`, `make smoke`, and `make verify` locally.
4. Commit the release changes.
5. Create and push an annotated tag matching the version exactly, for example `v4.16.1`.
6. The Release workflow injects the repository-specific HTTPS update manifest URL, builds both architectures, verifies both localizations, ZIP/DMG/update manifest, and publishes binaries plus checksums, update metadata, and source. When all Apple secrets are present it also imports the certificate into an ephemeral keychain, signs with Hardened Runtime, and notarizes and staples both the App and DMG.

The stable update endpoint is `https://github.com/<owner>/<repo>/releases/latest/download/TartR-update.json`. The manifest includes the exact DMG byte size and SHA-256 used by in-app verified downloads. Local builds leave `TartRUpdateManifestURL` empty and do not make automatic update requests.

Never commit certificates, app-specific passwords, notary profiles, or exported keychains.

`Scripts/notarize.sh` refuses ad-hoc, Apple Development, untimestamped, or non-Hardened Runtime builds before uploading anything to Apple.
