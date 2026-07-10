# Security Policy

## Reporting

Please report security issues privately by email:

[ai@ivan-it.net](mailto:ai@ivan-it.net)

Do not open a public GitHub issue for private keys, credentials, subscription
links, server configs, or vulnerabilities that could expose users.

## Sensitive Data

The project should not store real VPN profiles, UUIDs, passwords, private keys,
production configs, or signing keys in git.

Imported profiles and subscription source metadata are stored with Android
Keystore-backed encrypted storage. Native runtime configs are encrypted with
AES-GCM before being persisted. Logs and diagnostics redact credentials,
subscription tokens, authorization headers, and endpoint userinfo.

Generated Android release files (`.apk`, `.aab`) should be uploaded to GitHub
Releases instead of being committed to the repository.

## Supported Versions

The latest GitHub Release and the current Google Play production release are
supported. GitHub builds use the in-app signed APK updater; Play builds never
request package-install permission and update only through Google Play.
