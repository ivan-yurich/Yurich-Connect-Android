# Changelog

## 1.0.85 - 2026-06-21

- Added an engine selector layer for VPN profiles: supported protocols stay on
  sing-box, while Xray-only VLESS transports fail clearly instead of starting a
  broken tunnel.
- Hardened VLESS Reality TCP normalization and validation for Android startup.
- Removed unsafe `tls.insecure` from normalized Reality outbounds.
- Kept NaiveProxy, Hysteria/Hysteria2, Smart Route, and routing behavior
  unchanged.

## 1.0.84 - 2026-06-21

- Fixed Android auto-update downgrade failures by moving the app to a high
  monotonic `versionCode` line above previous universal and ABI split builds.
- Added native APK inspection before update installation: package name,
  version name, and version code are checked before Android's installer opens.
- The updater now rejects downloaded APKs whose `versionCode` is not newer than
  the installed app, preventing repeat download/install loops.
- Kept VPN protocols, Smart Route, and routing behavior unchanged.

## 1.0.83 - 2026-06-20

- Hardened VLESS Reality profile validation before VPN startup.
- Normalized VLESS Reality TCP profiles to stable Android defaults:
  `xtls-rprx-vision`, `xudp`, uTLS Chrome, SNI, and Reality enabled fields.
- Added clearer failures for incomplete Reality profiles instead of starting a
  broken tunnel.
- Extended diagnostics with VLESS mode, flow, SNI, uTLS, and packet encoding.
- Kept NaiveProxy, Hysteria/Hysteria2, Smart Route, and routing behavior
  unchanged.

## 1.0.82 - 2026-06-20

- Reworked Android update installation to prefer `PackageInstaller` sessions
  instead of the fragile `ACTION_VIEW` APK handoff.
- Added native package-name validation before an update APK is handed to
  Android, preventing wrong or unreadable APKs from reaching the installer.
- Prepared ABI split APK release assets so phones can download a smaller
  update package when supported.
- Kept VPN protocols, Smart Route, and routing behavior unchanged.

## 1.0.81 - 2026-06-20

- Hardened Android in-app updates against corrupted or partial APK downloads.
- The updater now validates the downloaded file as an APK archive before
  handing it to Android's installer.
- The native Android installer bridge also refuses invalid update files, so
  cached HTML/error pages can no longer be installed as APKs.
- Added regression coverage for invalid APK downloads.
- Kept VPN protocols, Smart Route, and routing behavior unchanged.

## 1.0.80 - 2026-06-20

- Increased GitHub Releases updater network timeouts and retry backoff for
  slow or filtered mobile networks.
- Added support for the current versioned APK asset name
  `Yurich-Connect-Android-vX.Y.Z.apk`.
- The manual APK fallback now opens the exact APK found by the update check
  instead of an older static release filename.
- Kept VPN protocols, Smart Route, and routing behavior unchanged.

## 1.0.79 - 2026-06-20

- Strengthened the native VPN keeper for night idle and mobile network changes.
- Added a cellular/idle settle delay before native health probes to avoid
  premature reconnects while LTE is switching towers or waking from Doze.
- Android idle-mode events now trigger a soft tunnel check through the native
  keeper instead of waiting for the next regular watchdog tick.
- Native mixed-proxy health checks now include an additional Google
  connectivity endpoint as a fallback.

## 1.0.78 - 2026-06-20

- Added explicit connection states for long-running sessions: Connected, Idle,
  Degraded, Reconnecting, and Failed.
- Strengthened the background keeper for night/idle phone use with a separate
  idle health-check path, softer recovery, and detailed diagnostics for resume,
  stale tunnel, and idle recovery events.
- Improved `/s/<token>/` subscription import by automatically trying
  `links.txt`, `hiddify.txt`, `nekobox.txt`, and `v2rayng.txt` variants while
  preserving the original subscription source for refresh.
- Expanded Smart Route package safeguards so Russian apps can stay direct while
  global AI, Google, Telegram, YouTube, Instagram, and browser traffic remains
  on the VPN path.
- Added regression coverage for the new connection UI states and root
  subscription fallback import.

## 1.0.77 - 2026-06-19

- Fixed the server picker UX: switching profile tabs or auto-selecting a
  profile no longer collapses the expanded server list.
- The server list now closes only when the user taps the explicit hide action,
  which keeps bulk profile switching predictable.

## 1.0.76 - 2026-06-19

- Added a compact stability event trail to diagnostics so keeper actions,
  unexpected stops, and native stream errors are visible in support reports.
- Expanded Smart Route global safeguards for AI/Copilot/Bing/Perplexity
  domains and apps so they stay on the VPN path instead of RU direct bypass.
- Added regression coverage for the new Smart Route global app denylist.
- Kept the supported stable protocol set unchanged: VLESS Reality, NaiveProxy,
  and Hysteria/Hysteria2.

## 1.0.75 - 2026-06-19

- Added a global Flutter error guard so uncaught Dart, platform dispatcher, and
  stream errors are logged instead of closing the app.
- Hardened VPN status, traffic, and log streams with explicit error handlers and
  safe timer flushes.
- Expanded Smart Route global routing for Google, OpenAI, Telegram, YouTube,
  browser, and Google core packages while keeping Russian app bypass
  conservative.
- Kept the supported stable protocol set unchanged: VLESS Reality, NaiveProxy,
  and Hysteria/Hysteria2.

## 1.0.74 - 2026-06-19

- Усилен фоновый keeper: если VPN формально включён, но туннель давно не
  подтверждал реальный интернет, приложение принудительно запускает health
  probe и мягкий reconnect без ручного открытия приложения.
- Недавний реальный трафик теперь записывается как здоровое состояние профиля,
  поэтому автоподбор меньше штрафует рабочие серверы.
- Диагностический отчёт расширен полями последнего действия keeper, следующей
  проверки туннеля и следующего reconnect.
- Протоколы и Smart Route не менялись, чтобы не ломать уже рабочие Reality,
  NaiveProxy и Hysteria/Hysteria2 профили.

## 1.0.60 - 2026-06-12

- Reworked Android in-app update installation to use `PackageInstaller`
  sessions first, with the classic APK view intent kept only as a fallback.
- Removed fragile installer extras that could make some Android/Honor package
  installers close without completing the update.
- The update APK is now prepared in app-specific external cache when available
  so Android's package installer can read it more reliably.
- Prepared the release flow to publish ABI-specific APKs again, giving phones a
  smaller update file than the universal APK.

## 1.0.59 - 2026-06-12

- Added a shared connection UI state model for the app and native Android
  service, so status, active protocol, country, ping, traffic, and session time
  are represented consistently.
- Enriched the main connection banner with compact protocol, country, and ping
  chips while keeping the fixed-size cyber/glass layout stable during live
  traffic updates.
- Reworked the Android foreground VPN notification to show the active profile,
  protocol, country, ping, upload/download speed, total traffic, and session
  duration.
- Added notification actions for opening the app, disconnecting, reconnecting,
  or starting the VPN from the foreground notification.
- Added formatter and protocol-display tests for Yurich Connect protocol names:
  VLESS Reality, NaiveProxy, and Hysteria/Hysteria2.

## 1.0.58 - 2026-06-12

- Added a shared Yurich Connect dark cyber/glass design system and moved the
  main app theme to reusable color, gradient, and radius tokens.
- Polished the Android home screen panels, profile cards, filter chips, status
  card, and import dialog to keep the UI consistent with the premium cyan
  brand style.
- Replaced the hardcoded in-app version with the Android package version via
  `package_info_plus`, so updater checks and diagnostics match the installed
  APK.
- Hardened the native VPN service lifecycle by replacing `GlobalScope` usage in
  `BoxService` with a service-owned coroutine scope and guarding duplicate
  command-server starts.
- Kept the supported stable protocol set: VLESS Reality, NaiveProxy, and
  Hysteria/Hysteria2.

## 1.0.57 - 2026-06-09

- Restored NaiveProxy support in the Android client while keeping the Xray
  bridge, VLESS XHTTP, and VLESS mKCP disabled.
- Brought back the Naive profile tab, import hints, QR helper text, and FAQ
  wording for the supported stable set: VLESS Reality, NaiveProxy, and
  Hysteria/Hysteria2.
- Kept the reduced APK footprint from removing the bundled Xray binary.

## 1.0.56 - 2026-06-09

- Removed the experimental VLESS XHTTP/mKCP/Xray bridge from the Android app.
- Deleted the bundled Xray native binary, reducing APK size and simplifying the
  VPN startup path.
- The visible Android profile list now focuses on VLESS Reality and
  Hysteria/Hysteria2; legacy Naive, XHTTP, mKCP, TLS-only VLESS, and raw
  sing-box JSON profiles are filtered out of the client UI.
- Updated import hints and FAQ copy to match the supported protocol set.

## 1.0.55 - 2026-06-09

- Added an Android UID traffic fallback so the in-app session counter and VPN
  notification can still show traffic when sing-box status totals stay at zero.
- Added a clear user-facing message for VLESS XHTTP/mKCP on non-arm64 devices:
  the bundled Xray bridge is available only for `arm64-v8a` in this build.
- Updated FAQ copy to describe the new experimental Xray bridge instead of the
  old "future engine" wording.

## 1.0.54 - 2026-06-09

- Added an experimental Android Xray sidecar bridge for imported VLESS XHTTP
  and VLESS mKCP profiles on arm64 devices.
- Kept sing-box as the main Android TUN/VpnService engine and routes XHTTP/mKCP
  through a local Xray SOCKS bridge, preserving the stable NaiveProxy,
  Hysteria2, and VLESS Reality behavior.
- Added tests for Xray bridge JSON generation and sing-box bridge outbound
  generation.

## 1.0.53 - 2026-06-09

- Added a direct APK fallback action when the in-app updater cannot complete
  download or installation through Android.
- Kept the GitHub Releases updater as the primary channel, but made the user
  path less fragile when GitHub API, Android installer, or install permissions
  fail on a device.
- Bumped the Android version so phones on `1.0.52` can verify the update flow
  against a newer build.

## 1.0.52 - 2026-06-09

- Blocked VLESS XHTTP/mKCP connection attempts before stopping the currently
  working tunnel.
- Replaced the technical `Unsupported operation` text with a clear Xray/libXray
  requirement message.
- Kept imported XHTTP/mKCP profiles visible for a future Xray engine without
  breaking Hysteria2, NaiveProxy, or VLESS Reality sessions.

## 1.0.51 - 2026-06-09

- Fixed the in-app version shown to the updater so it matches the Android
  package version.
- Hardened update discovery: if the primary JSON endpoint is stale or not newer,
  the app now continues checking GitHub Releases instead of stopping early.
- Prepared a fresh GitHub Release so phones can verify the auto-update flow
  against a newer version than `1.0.50`.

## 1.0.50 - 2026-06-09

- Made the connection panel more compact so long profile lists get more room on
  the first screen.
- Moved the session traffic total into the glowing uptime button under the
  timer, keeping upload and download counters simpler.
- Kept the stronger selected-profile frame, left glow strip, and in-card
  "Active" badge for the currently connected profile.

## 1.0.49 - 2026-06-09

- Kept the connection/status panel fixed while the profile list scrolls, so the
  connect button and uptime stay available with long subscriptions.
- Made the selected profile highlight stronger and added an explicit active
  tunnel badge for the currently connected profile.
- Brightened profile filter tabs so the selected location/protocol filter is
  visible even when the VPN is stopped.

## 1.0.48 - 2026-06-09

- Added import and UI recognition for VLESS XHTTP and VLESS mKCP profiles.
- Kept the current sing-box tunnel safe: XHTTP/mKCP profiles now show a clear
  Xray/libXray requirement instead of generating an invalid sing-box config.
- Treated `/s/<token>/` subscription URLs as first-class saved sources, matching
  providers that do not expose a visible `links.txt` suffix.
- Updated subscription refresh copy so users can paste either `/s/.../` or
  `/links.txt` links.

## 1.0.47 - 2026-06-09

- Added a polished Yurich Connect visual layer with a cool blue app gradient,
  glowing connection card, animated uptime button, highlighted active profile,
  and richer profile/network panels.
- Kept animation centralized in one lightweight controller so the interface
  feels alive without adding VPN timers or touching protocol behavior.
- Preserved fixed status-card sizing so live traffic numbers do not stretch the
  connection area while the VPN is running.

## 1.0.46 - 2026-06-09

- Strengthened the native Android VPN keeper for overnight and idle-phone use.
- Restored `WAKE_LOCK` and boot restore permissions so the foreground VPN
  service can keep checking the tunnel and recover after reboot/update.
- Added boot/package-replaced restore when VPN was previously enabled by the
  user and a valid config is saved.
- Added sticky service recovery when Android removes the task or destroys the
  service unexpectedly.
- Moved the native watchdog to a less noisy one-minute cadence with three failed
  probes before restarting sing-box, reducing false reconnects while still
  restoring dead tunnels in the background.

## 1.0.45 - 2026-06-08

- Reworked the lower app area into a single cleaner center panel with contact
  actions, language, updates, FAQ, and sing-box logs grouped together.
- Added automatic background update discovery on app start.
- When a newer GitHub Release is available, the app now highlights the Updates
  section, shows an in-app notice, and attempts an Android notification.
- Kept update installation manual so Android permissions and installer prompts
  remain predictable for the user.

## 1.0.44 - 2026-06-08

- Made NaiveProxy startup tolerant to false-negative tunnel probes: when
  sing-box reports `Started`, the app no longer immediately stops the VPN only
  because the first internet probe failed.
- Startup probe failures now mark the connection as degraded and schedule a
  quick watchdog recheck, allowing real traffic to confirm the tunnel or the
  keeper to reconnect if the failure is real.
- This reduces cases where NaiveProxy briefly starts, passes traffic, but the
  app shuts it down with "VPN started, but tunnel probe failed".

## 1.0.43 - 2026-06-08

- Improved subscription expiration detection for profile lists where only some
  profile names contain a date.
- Added support for year-first labels such as `until-2027-06-08`.
- When one profile in the same subscription carries the expiration date, the app
  now applies that date to sibling profiles that do not include it in their own
  name.

## 1.0.42 - 2026-06-08

- Added subscription expiration parsing from profile names, including provider
  labels such as `до 08.06.2027`, `until 08-06-2027`, `expire`, `expires`, and
  `expiry`.
- Kept server-provided subscription metadata as the priority source when
  `subscription-userinfo` headers or JSON expiration fields are available.
- Added a regression test for Yurich/links-style profile names with embedded
  subscription dates.

## 1.0.41 - 2026-06-08

- Preserved the original HTTP/HTTPS subscription source for imported profile
  lists such as `/s/.../links.txt`, while keeping each profile's own protocol
  link for QR/copy/manual use.
- Made the subscription refresh button useful for existing installs: if old
  profiles do not yet know their source URL, the app opens the import dialog and
  asks to paste the subscription link once.
- Added a regression test for raw `links.txt` subscriptions with multiple
  profile links and expiration metadata.

## 1.0.40 - 2026-06-08

- Hardened the in-app updater against GitHub `HTTP 504` and other temporary
  network failures.
- Added retries with backoff for both update metadata and APK downloads.
- Added a fallback discovery path through GitHub `/releases/latest` when the
  GitHub JSON API is temporarily unavailable.
- Added direct release download fallbacks for `YurichConnect-android-release.apk`.

## 1.0.39 - 2026-06-08

- Added subscription refresh from saved HTTP/HTTPS subscription sources.
- Profile cards and the profile/network panel now show the remaining
  subscription time when the provider sends expiration metadata.
- Added renewal reminders for subscriptions that are expired or have 5 days or
  less remaining, with an in-app message and Android notification when allowed.
- Preserved cached country metadata and existing expiration data during repeated
  subscription imports.

## 1.0.38 - 2026-06-08

- Added profile country detection and cached country metadata.
- Profile cards now show a country flag when the subscription name contains one,
  when the endpoint IP geolocation is resolved, or after the real VPN exit
  country is detected through the local tunnel proxy.
- Unknown countries now show a neutral globe instead of a protocol-only icon.
- Developer diagnostics now include cached country code/name for profiles.

## 1.0.37 - 2026-06-08

- Fixed profile ping for Hysteria/Hysteria2: UDP/QUIC profiles are no longer
  marked `offline` by a TCP socket check.
- Hysteria/Hysteria2 profile rows now verify endpoint DNS reachability and show
  `DNS ... ms` or `UDP ok` instead of a false TCP failure.
- Bumped Android version for the next install/update package.

## 1.0.36 - 2026-06-08

- Pointed Android in-app updates to the renamed GitHub repository:
  `ivan-yurich/Yurich-Connect-Android`.
- Updated project documentation to use the Yurich Connect Android repository
  address.
- Bumped the Android app version so phones can receive the repository-migration
  update through the built-in updater.
- Reworked the profile/network panel into compact rows for protocol, Wi-Fi/LTE,
  DNS, background stability, country, ping, and endpoint.
- Added a clear note that Android apps can detect the system VPN service through
  OS APIs; the app protects IP/DNS routing but cannot hide Android VpnService
  without unsupported root/system tricks.
- Renamed the DNS status to "through profile" so the UI matches the current
  tunnel/FakeIP behavior without implying a forced third-party resolver.
- Kept the current mobile protocol tuning intact while retaining the native
  background health keeper for long-running Wi-Fi/LTE sessions.
- Made the native health keeper recover faster on mobile handoffs by reducing
  the probe grace, interval, cooldown, and failure threshold.

## 1.0.35 - 2026-06-07

- Added a native Android foreground-service health keeper that probes the local
  mixed proxy in the background and reloads sing-box when the tunnel is alive as
  a service but no longer passes traffic.
- Added a red degraded connection state for stalled or auto-recovering tunnels,
  so the main action button no longer stays visually healthy when the connection
  is broken.
- Extended VPN diagnostics with the degraded connection flag, health-failure
  counters, reconnect attempts, uptime, profile ping, and last healthy timestamps.

## 1.0.32 - 2026-06-05

- Renamed the Android app brand from Aurum VPN to Yurich Connect across the
  launcher label, Flutter title, notification title, updater messages, and
  support docs.
- Kept the Android package/application id unchanged so existing installs can
  update in place.

## 1.0.27 - 2026-06-01

- Improved Android APK handoff for in-app updates on OEM firmware by copying
  the downloaded APK into the app cache and opening it with a MIME-aware
  installer intent.
- Granted temporary APK read access to all matching Android package installers.

## 1.0.26 - 2026-06-01

- Added a visible update channel line in the Updates panel so in-app update
  tests clearly show that the GitHub Releases flow is active.
- Prepared a new release build for Android auto-update validation.

## 1.0.25 - 2026-06-01

- Throttled live traffic UI updates so long VPN sessions do not rebuild the
  home screen on every native counter event.
- Added timeouts and best-effort handling around native VPN calls, reducing UI
  hangs during start, stop, reconnect, and language changes.
- Hardened Android service cleanup on destroy by closing the command server,
  TUN file descriptor, network monitor, receiver, and notification.
- Guarded sing-box/libbox initialization so Flutter engine reattach does not
  launch duplicate setup jobs.
- Disabled Android backup/data extraction for app data and explicitly blocked
  cleartext traffic in the release manifest.

## 1.0.24 - 2026-05-26

- Added subscription expiry metadata to saved profiles.
- Imported subscription expiration from common subscription metadata such as
  `subscription-userinfo: ... expire=...`.
- Added a paid subscription countdown to the profile/network card.

## 1.0.23 - 2026-05-26

- Fixed Android in-app update installation by registering the APK
  `FileProvider` and exposing the app cache directory used for downloaded
  update files.
- Switched the updater installer intent to Android's package install action for
  a more reliable handoff after the user allows installs from Aurum VPN.

## 1.0.22 - 2026-05-26

- Moved the main connect/disconnect button directly under the connection status
  card, above the profiles block, so the primary VPN action stays visible
  sooner on mobile screens.

## 1.0.21 - 2026-05-26

- Changed generated NaiveProxy startup order to prefer HTTPS CONNECT fallback
  first and keep native Naive as the second fallback. Local tunnel tests showed
  the fallback avoids native Naive's extra UDP/QUIC probing path and performs at
  least as fast on the tested server.
- Restored Android TUN stack to `gvisor`, matching current NB4A guidance where
  newer builds default back to gVisor for compatibility.
- Kept MTU 9000, FakeDNS, protected DNS through the tunnel, and Hysteria/VLESS
  import support.

## 1.0.20 - 2026-05-25

- Added an in-app Updates section that checks release metadata, downloads the
  matching APK for the phone ABI, and opens the Android installer without
  sending the user to a browser.
- Tuned TUN for throughput by switching from full gVisor to `mixed` stack,
  keeping system TCP for TCP-heavy protocols while retaining gVisor for UDP.
- Removed `endpoint_independent_nat` from the default Android TUN config because
  sing-box documents a possible performance cost and Aurum rejects unsupported
  UDP for NaiveProxy by design.

## 1.0.19 - 2026-05-25

- Reverted the experimental 1.0.18 Android inbound/DNS fields that could make
  sing-box stop immediately on startup on some devices.
- Restored the known-good NaiveProxy order: native Naive first, HTTPS CONNECT
  fallback second.
- Removed the automatic throughput probe from startup so a valid connection is
  not rejected while the tunnel is still warming up.
- Kept Hysteria/Hysteria2 import support and VLESS `packet_encoding: xudp`.

## 1.0.18 - 2026-05-25

- Moved sniffing closer to the NekoBox model by enabling it on TUN/mixed
  inbounds instead of using a global route sniff rule.
- Added `domain_strategy` on generated Android inbounds, plus DNS
  `independent_cache` and FakeDNS `disable_cache`.
- Changed NaiveProxy startup order to try HTTPS CONNECT first, then native
  Naive, and added a short tunnel throughput probe so a very slow mode can
  automatically fall back.
- Kept VLESS `packet_encoding: xudp` and Hysteria import support from 1.0.17.

## 1.0.17 - 2026-05-25

- Added first-class import/build support for Hysteria2 (`hy2://`,
  `hysteria2://`) and Hysteria (`hysteria://`) profiles.
- Tuned generated VLESS profiles with `packet_encoding: xudp`, matching common
  Xray/sing-box mobile profile behavior for better UDP compatibility.
- Kept NaiveProxy on the stable HTTP/2 path and preserved the Neko-style DNS
  split that resolved the previous reconnect and FakeDNS issues.
- Shortened the manual stop wait path so the UI returns from disconnect faster
  while sing-box finishes cleanup in the background.
- Updated UI text, QR hints, diagnostics redaction, and tests for the expanded
  protocol set.

## 1.0.16 - 2026-05-25

- Added NekoBox-style DNS separation: proxy server hostnames are resolved with
  the local resolver, while user traffic DNS stays protected through the tunnel.
- Kept FakeDNS scoped to the TUN inbound so local mixed-proxy checks do not use
  FakeIP records.
- Removed release debug symbols from packaged native libraries to reduce APK
  size and make the build closer to a production artifact.

## 1.0.15 - 2026-05-25

- Tuned Android TUN performance closer to NekoBox: MTU 9000 and
  endpoint-independent NAT.
- Scoped FakeDNS to the TUN inbound so the local mixed proxy and health checks
  do not inherit unnecessary FakeIP behavior.
- Force native NaiveProxy to HTTP/2 unless a raw custom sing-box config is used,
  avoiding accidental QUIC/H3 negotiation in generated profiles.
- Disabled live sing-box log streaming by default; logs are attached only when
  the log panel is opened or a report is prepared.

## 1.0.14 - 2026-05-25

- Removed experimental NaiveProxy QUIC/H3 from automatic startup because it can
  cause reconnect loops on mobile networks and some Wi-Fi routers.
- Restored stable NaiveProxy startup order: native Naive over HTTP/2 first,
  HTTPS CONNECT fallback second.
- Kept IPv4-only endpoint dialing to avoid broken server IPv6 paths, but
  removed TCP Fast Open from default dial settings for safer compatibility.
- Prepared Android split-per-ABI APK artifacts locally to reduce install size.

## 1.0.13 - 2026-05-25

- Added a faster NaiveProxy startup plan that tries native Naive over QUIC/H3
  before falling back to HTTP/2 and HTTPS CONNECT.
- Tuned outbound dial settings for IPv4-only resolution, TCP Fast Open, and
  quicker network fallback.
- Replaced the bottom import sheet with a centered import dialog.
- Prepared local Android test artifacts without publishing to GitHub.

## 1.0.12 - 2026-05-23

- Improved NaiveProxy health checks for servers where CONNECT to IP targets
  works but server-side DNS resolution is broken or slow.
- Kept domain probes first, then falls back to an IP probe so valid TUN
  profiles are not rejected too early during startup.

## 1.0.11 - 2026-05-23

- Added NaiveProxy startup fallback between native Naive and HTTPS CONNECT
  modes, with a real mixed-proxy health check before the connection is accepted.
- Added import support for standalone sing-box outbound JSON such as
  `type: http` / `type: naive` NaiveProxy configs.
- Improved VPN stop timing and status watchdog checks for long-running sessions
  and profile switching.
- Removed technical app text that referenced other clients.

## 1.0.10 - 2026-05-23

- Fixed `naive+https://` profile generation on Android by using sing-box native
  NaiveProxy outbound instead of forcing the link into generic HTTP CONNECT.
- Added regression coverage for go-it style NaiveProxy links.

## 1.0.9 - 2026-05-23

### Android

- Cleaned the app header and removed extra top action icons.
- Fixed the connection status card height so traffic counters do not stretch the
  layout.
- Moved language switching to the contact section.
- Rewrote profile/network helper text to be clearer for regular users.
- Kept protected DNS, mobile network tuning, and explicit profile stop/start
  behavior from the previous build.

### Verification

- `flutter analyze`
- `flutter test`
- Android APK verified with APK Signature Scheme v2

## 1.0.8 - 2026-05-22

- Added protected DNS routing for Android profiles.
- Improved VPN stop handling so the UI does not wait for long sing-box cleanup.
- Improved diagnostics summary for profile, protocol, endpoint, and config.

## 1.0.7 - 2026-05-22

- Improved NaiveProxy compatibility with HTTPS CONNECT mode.
- Tuned Android TUN settings for Wi-Fi and LTE.
- Added Android release APK packaging.

## 1.0.0 - 2026-05-22

- Initial Android edition with Flutter, sing-box, profile import, QR import,
  clipboard import, VLESS Reality, NaiveProxy, notifications, and diagnostics.
