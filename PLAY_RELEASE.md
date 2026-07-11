# Google Play Release Checklist

## Build

```powershell
$env:PUB_CACHE = 'D:\PubCache'
D:\FlutterSDK\bin\flutter.bat pub get
D:\FlutterSDK\bin\flutter.bat analyze --no-pub
D:\FlutterSDK\bin\flutter.bat test --no-pub
D:\FlutterSDK\bin\flutter.bat build appbundle --release --flavor play --no-pub
```

Upload `build/app/outputs/bundle/playRelease/app-play-release.aab` to an
internal testing track before production.

The Play flavor adds `10000` to the base `versionCode`. This keeps Play
updates newer than GitHub APK splits, where Flutter applies ABI-specific
version-code offsets.

## Play Console

1. Complete the VPN service declaration and explain that `VpnService` is the
   core user-visible functionality.
2. Declare the `specialUse` foreground service and provide the requested demo
   video showing connection, persistent notification, and disconnect flow.
3. Publish `PRIVACY.md` at a stable public HTTPS URL and add that URL to the
   store listing and in-app disclosure.
4. Complete Data safety using the actual production backend behavior. The
   current client has no analytics or advertising SDK and keeps diagnostics on
   device unless the user explicitly shares them.
5. Verify that the Play manifest does not contain
   `REQUEST_INSTALL_PACKAGES`, and that backup and cleartext traffic remain
   disabled.
6. Run internal-track tests for VPN consent, first-use disclosure, profile
   import, connection switching, background recovery, reboot, and update.

## Signing

- Keep `android/key.properties` and the keystore outside git.
- Use Play App Signing and retain an offline backup of the upload key.
- Never mix the GitHub and Play artifacts: GitHub receives the APK; Google Play
  receives the AAB.
