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
3. Run `make check`, `make build`, and `make verify` locally.
4. Commit the release changes.
5. Create and push an annotated tag matching the version exactly, for example `v4.3.0`.
6. The Release workflow imports the certificate into an ephemeral keychain, builds both architectures, signs with Hardened Runtime, notarizes, staples, verifies, and publishes binaries plus checksums and source.

Never commit certificates, app-specific passwords, notary profiles, or exported keychains.
