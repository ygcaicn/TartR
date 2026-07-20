# Security Policy

## Reporting a vulnerability

Please report vulnerabilities privately to the repository maintainer. Do not include credentials, private VM images, registry tokens, or decrypted VM contents in a public issue.

Include the TartR version, macOS version, Tart version, reproduction steps, and the smallest non-sensitive log excerpt needed to diagnose the issue.

## Security boundaries

TartR runs with the current macOS user's permissions and intentionally is not App Sandbox-enabled because it must execute Tart, access Tart's VM storage, and open user logs. TartR does not request root access, store registry credentials, or bypass Tart's own authorization model.

The “永久删除” action invokes `tart delete` and is not recoverable. TartR requires exact-name confirmation before running it.

