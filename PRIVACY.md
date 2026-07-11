# Yurich Connect Privacy Policy

Effective date: 2026-07-10

Yurich Connect is an Android VPN client. It uses Android `VpnService` to route device traffic through a VPN server selected by the user and to encrypt the connection between the device and that tunnel endpoint.

## Data processed on the device

The app processes VPN profile credentials, subscription URLs, DNS requests, destination addresses, installed package names used for optional Smart Route rules, connection state, traffic totals, and diagnostic logs. VPN profiles and runtime credentials are encrypted at rest using Android Keystore-backed storage. Diagnostic and stability data is kept locally unless the user explicitly chooses to share a report.

## Data collection and sharing

The app does not include advertising or analytics SDKs and does not automatically send VPN traffic, browsing history, DNS history, installed app lists, diagnostics, or profile credentials to the developer. If the user explicitly sends a diagnostic report, the app redacts known credentials and subscription tokens before opening the user's email client.

The operator of a VPN server selected or imported by the user may process network traffic and connection metadata according to that operator's own terms and privacy policy. Yurich Connect does not control third-party VPN servers.

## Storage and deletion

VPN profiles remain on the device until the user deletes them or clears the app's data. Android cloud backup and device-transfer backup are disabled for app data. Uninstalling the app or clearing its storage removes locally held app data; Android Keystore keys are removed by the operating system.

## Permissions

- `VpnService` and foreground-service permissions keep the user-requested encrypted tunnel active.
- Network permissions fetch subscriptions and establish VPN connections.
- Camera access is optional and used only to scan a QR code when the user opens the scanner.
- Installed package visibility available to the app is used locally for optional Smart Route rules.
- Notification and battery-optimization permissions support persistent VPN status and connection stability.

## Contact

Privacy questions: `ai@ivan-it.net`
