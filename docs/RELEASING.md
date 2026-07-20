# Releasing TartR

## Required GitHub secrets

- `DEVELOPER_ID_CERTIFICATE_BASE64`: base64-encoded Developer ID Application `.p12`
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`: password protecting the `.p12`
- `DEVELOPER_ID_APPLICATION`: complete codesign identity string
- `KEYCHAIN_PASSWORD`: random password for the temporary CI keychain
- `APPLE_ID`: Apple Developer account email
- `APPLE_TEAM_ID`: Apple Developer Team ID
- `APPLE_APP_PASSWORD`: app-specific password used by `notarytool`

An Apple Development certificate is not sufficient. The certificate must be a valid **Developer ID Application** identity.

## Release process

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
2. Add the release section to `CHANGELOG.md`.
3. Install the current Tart release, then run `make check`, `make compat`, `make build`, `make smoke`, and `make verify` locally.
4. Commit the release changes.
5. Create and push an annotated tag matching the version exactly, for example `v4.14.0`.
6. The Release workflow imports the certificate into an ephemeral keychain, injects the repository-specific HTTPS update manifest URL, builds both architectures, signs with Hardened Runtime, notarizes and staples both the App and DMG, verifies ZIP/DMG/update manifest, and publishes binaries plus checksums, update metadata, and source.

The stable update endpoint is `https://github.com/<owner>/<repo>/releases/latest/download/TartR-update.json`. Local builds leave `TartRUpdateManifestURL` empty and do not make automatic update requests.

Never commit certificates, app-specific passwords, notary profiles, or exported keychains.

`Scripts/notarize.sh` refuses ad-hoc, Apple Development, untimestamped, or non-Hardened Runtime builds before uploading anything to Apple.
