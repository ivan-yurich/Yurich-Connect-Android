# Android evidence tools

These tools target the signed `soak` flavor on an authorized ADB phone. They
change Wi-Fi/mobile-data state and select existing profiles. Do not run two
controllers on one phone. Keep private artifacts under ignored `build/qa/`.

Only soak enables `<profileable android:shell="true">` for shell CPU profiling.
GitHub/Play manifests must contain neither this flag nor the observer metadata.
Do not disable kernel symbol restrictions or export heap dumps with credentials.

## Native observation

`native_observer.py` reads a dynamic, ordered broadcast from the existing VPN
process. The receiver is enabled only by the soak manifest and requires
`android.permission.DUMP`. It cannot activate a VPN, launch Flutter, change a
profile or query a dead service. Responses contain a nonce, process/service/
session identity, monotonic device time, phase, runtime, TUN state and UID bytes.
Missing responses, PID changes and unsupported counters are unknown, not zero.
PID absence requires a clean `pidof -s` no-match result (exit 1, empty stdout
and stderr). Transport errors, stderr diagnostics and malformed or contradictory
results are unknown, never evidence that Android killed the VPN process. Keep
the SDK platform-tools ADB version consistent across host tools: another ADB
version can replace the shared server and interrupt an otherwise healthy run.
An interrupted interval is not a completed soak and must not be concatenated
with a new interval. Preserve its original summary, including uncertain counts.

Requests without a version retain the original v1 response. A `version=2`
request additionally returns `activeNet`, `trackedNet` and `sameNet`. The host
reader requests v2 but accepts a valid v1 from an older APK with unknown network
fields. Capability bits are: network present 1, capabilities observed 2, VPN 4,
Wi-Fi 8, cellular 16, INTERNET 32, VALIDATED 64. `-1` means the query failed;
`0` means no network; `1` means a network object with unavailable capabilities.
`sameNet=1` also includes both networks being absent, so it is not readiness.
These reads are not atomic and contain no network IDs, IPs or SSIDs.

Explicit v3 requests additionally return `config`, a lowercase SHA256 fingerprint
of the exact configuration loaded by the VPN process, or `unknown`. The value
is bound to the start generation; stale startup work cannot label a later
generation. v1/v2 formats are unchanged. Keep even these opaque correlations
in private QA evidence rather than public logs.

`native_profile_binding.py` establishes a binding from matching native snapshots
around a setup-time profile status observation. `native_payload_probe(...,
binding=...)` then requests v3 and rejects unknown/different configs, runtimes or
expected profiles. The same config may survive a new PID/generation, but byte
deltas cannot span that change. This is config-content attribution, not a unique
logical profile ID or an authorization token. Identical configurations in two
profile entries are indistinguishable; detect/report that ambiguity before
using bindings to certify a complete inventory matrix.

UID counters include encapsulation and other app traffic. They do not replace
UI-counter checks, external HTTPS, DNS leak tests, throughput measurements or
proof that every destination uses the expected route. Pair observations with
OS VPN state before/after each HTTPS request and reject session changes.

## Recovery regression

From the repository root, with Python and Android SDK `adb` on PATH. Set
`ANDROID_SERIAL` to the authorized target from `adb devices -l` before running
device commands. The examples require that environment variable and do not
select a phone automatically.

```powershell
python -m unittest discover -s tooling/soak -p 'test_*.py' -v
if (-not $env:ANDROID_SERIAL) { throw 'Set ANDROID_SERIAL before device checks.' }
python -m tooling.soak.run_network_recovery_checks --adb adb --serial $env:ANDROID_SERIAL --out 'build/qa/native-recovery-new' --restore-profile p0008 --native-observer --sustain-seconds 30
```

The output directory must be new. Tokens refer to the observed inventory, not
permanent server names. Verify them before using another phone/subscription.
The default set is p0001/p0006/p0007/p0008, one representative per protocol on
the current test phone. UI is opened only for deliberate profile activation;
handover/outage windows run with the screen non-interactive.

The test preserves first-success latency and every native probe, then requires
successful samples spanning the requested interval. A failed probe resets that
interval but remains in the result. A scenario PASS means eventual recovery,
not absence of earlier failures or continuous, unobserved connectivity. Inspect
individual probes before reporting stability. `finally` attempts restoration of
the original radios and requested profile; inspect restoration flags.
The recovery CLI returns nonzero on scenario failure or failed restoration.
Native sustained windows reset when a session changes between successful
samples. Probes that finish after the scenario deadline cannot turn it into PASS.

## HTTP diagnostics

`http_diagnostics.py` preserves only allowlisted curl exit/status/size/TLS-result
and timing fields. It never stores response bodies, headers, URLs, IP addresses,
certificate contents or stderr. Curl must support `--write-out %{json}`; missing
or malformed measurements are unknown, not a successful request. TLS validation
remains enabled. Each endpoint has an exact expected status, and the payload
must download exactly 65536 bytes. A fallback 204 cannot count as payload.

The focused native recovery output retains every attempt, including a failed
payload followed by a successful fallback. The 24h runner emits equivalent
`https_attempt` events, but still has the native-observer limitation below.

For an already connected native VPN, without profile, radio or UI changes:

```powershell
if (-not $env:ANDROID_SERIAL) { throw 'Set ANDROID_SERIAL before device checks.' }
python -m tooling.soak.run_http_diagnostics --adb adb --serial $env:ANDROID_SERIAL --out 'build/qa/http-diagnostics-new' --rounds 3
```

This bounded test pairs OS VPN state and native session/counters before and
after each request. It does not establish profile identity, test the browser,
or exercise BoxService's local HTTP proxy health-check path. UID growth alone
does not prove routing. Successful samples do not certify a continuous interval.
The `time_*` measurements are cumulative from curl's request start, in ms; in
particular `time_appconnect` is not the TLS-only handshake duration.
See [curl write-out documentation](https://curl.se/docs/manpage.html#-w).

## Single current-profile outage

`run_current_wifi_outage.py` requires an already connected XHTTP profile (default)
or a Naive profile selected with `--protocol naive` on
Wi-Fi and a non-interactive display. It queries the existing Flutter bridge
only before and after the test; it does not launch an activity or activate a
profile. It disables both radios once, externally confirms the outage, and
enables data plus Wi-Fi as in the earlier recovery matrix. Therefore the first
seconds of restoration may use cellular before Wi-Fi is observed. Finalization
restores the recorded radio baseline without altering the profile.

```powershell
if (-not $env:ANDROID_SERIAL) { throw 'Set ANDROID_SERIAL before device checks.' }
python -m tooling.soak.run_current_wifi_outage --adb adb --serial $env:ANDROID_SERIAL --out 'build/qa/current-xhttp-outage-new' --require-network-diagnostics
```

The recovery budget is 150s with a 30s successful sampled window in one native
session, then 90s follow-up. HTTP diagnostics can additionally use the fixed
loopback proxy on port 20808. These requests share the proxy entrance with the
native watchdog but use curl/BoringSSL rather than Java SSLSocket, so their
TLS behavior and timeouts are not identical. No browser test is implied.

`native_health_events.py` streams a bounded allowlist of endpoint aliases,
quorum counts and lifecycle codes. It discards raw log messages without writing
them to disk and never clears logcat. Missing, interrupted or truncated capture
blocks the current diagnostic runner's PASS. Preserve device clock timestamps
when correlating probes and native logs. An interrupted process must not leave
radios disabled; after host failure manually verify their state before retrying.

Soak-only `YurichNativeHealth` events additionally expose individual stage
durations: loopback connect, CONNECT response, TLS and HTTP. Stages not reached
remain `-1`; failures use fixed categories, never exception messages or response
contents. `http_status` includes an absent/EOF status, not just a valid HTTP error.
Generation and revision describe state at endpoint entry, not ownership of the
caller job. This instrumentation adds some overhead and is not a performance fix.
`--require-network-diagnostics` requires native v2 during preflight and observed
capabilities plus stage events in the completed report. It does not mean every
probe was captured or that a capability snapshot proves the payload route.

## Limits and rollback

`run_24h_matrix.py` still uses the older Flutter bridge/counter qualification.
Do not use its legacy PASS to certify config-bound native background coverage.
The new `run_native_soak.py` reuses its ADB, HTTPS, resource and exit-info parsers,
but has a separate native qualification scope. `run_focused_checks.py` now also
requires v3 config bindings by default. `bound_checks.py` shares these controls.
No periodic payload probe queries Flutter or launches an activity. Only explicit
control boundaries can bootstrap a missing Flutter control receiver; fallback
counts are recorded. Screen-off is not proof of frozen Flutter or battery-only
Doze, especially with ADB and charging attached. A v2 snapshot cannot qualify
profile ownership. Missing GUI counters do not fail native connectivity.

After a dispatched control request, `BoundChecks` requires an observed idle
Flutter control queue before sending another command. A host timeout does not
cancel the asynchronous operation on the phone. Busy/unknown queue state is
polled read-only for up to 180s; failure aborts the scenario without dispatching
the next profile or crediting its coverage. See `control-queue.jsonl`. This
prevents cascading `busy` replies from being mislabeled as protocol failures.

`NativeBindingRegistry` preserves the first setup-confirmed fingerprint. A
different hash on revisit fails instead of silently replacing the binding.
Two tokens sharing a hash become ambiguous; both lose qualification, including
earlier results when computing the final verdict. This is evidence correlation,
not independent verification of a server's credentials or identity.

## Config-bound long run

First run `run_focused_checks` against representative inventory tokens and both
transports. Then validate the long controller's own lifecycle using its bounded
preflight: current profile, Wi-Fi/mobile handovers, one 30s outage, restoration.
`preflight_pass` is deliberately separate from the 24-hour `pass` field.

```powershell
if (-not $env:ANDROID_SERIAL) { throw 'Set ANDROID_SERIAL before device checks.' }
python -m tooling.soak.run_focused_checks --adb adb --serial $env:ANDROID_SERIAL --out 'build/qa/bound-focused-new' --profiles p0001,p0006,p0007,p0008 --restore-profile p0008
python -m tooling.soak.run_native_soak --adb adb --serial $env:ANDROID_SERIAL --out 'build/qa/bound-preflight-new' --preflight-only
python -m tooling.soak.run_native_soak --adb adb --serial $env:ANDROID_SERIAL --out 'build/qa/bound-24h-new' --hours 24
```

Run these sequentially, never together. The phone must initially be connected
to a known profile with its screen off. The long run starts with all inventory
profiles, activate/reconnect on both transports, then allocates the remaining
24h to per-profile/transport holds. Each hold attempts a 30s outage and native
recovery. Both outages and handovers first require a fresh config-bound external
payload on the source network. An unhealthy baseline records `skipped=true`,
`reason=baseline_unhealthy` and `scenario_skips`, without injecting an outage or
calling it a recovery failure. Skips prevent a passing final verdict. After a
skipped handover, the next endurance cell still sets up its scheduled network;
that setup is not qualified handover coverage. The outstanding control queue
must be idle before radio changes. Handovers do not send an automatic reconnect
command. Recovery needs
at least three qualified payload samples spanning 30s in the same native session,
within 150s; earlier failures remain recorded. This is sampled recovery, not
continuous connectivity or a promise of zero packet loss.

Payloads are 64KiB at approximately 120s intervals during holds. Native snapshots
are sampled at approximately 30s intervals, resource/exit-info every 5min; ADB
latency adds overhead. Logs are streamed through an allowlist and drained to
disk incrementally, without clearing logcat. A 43C battery measurement stops
this experiment conservatively; it does not establish an app-caused thermal bug.

Inspect `heartbeat.json`, `process.json`, `matrix.json`, `bound-probes.jsonl`,
`native-samples.jsonl`, `native-health.jsonl`, `native-exits.jsonl`, `memory.csv`,
`outages.jsonl`, `handovers.jsonl`, `endurance.json`, and final `summary.json`.
Check the actual host PID/command line and fresh samples, not only heartbeat
timestamps. A dead process without final restoration is an interrupted run.
The runner requests host wakefulness while alive; it cannot survive PC shutdown,
USB removal or forced process termination. Keep the host and ADB connected.

Create a `STOP` file inside that run's output directory for a graceful stop.
It may take the current bounded ADB/control request to finish. `finally` attempts
radio/profile/screen restoration and verifies a payload afterward. Verify the
restoration flags; following a hard host failure restore networks manually.
Keep memory measurements, UI testing, leak analysis and security review separate
from native connectivity PASS. Do not claim store readiness from this run.

## Application rollback

The rapid reload defect reproduced on 39133: selecting another same-core
profile changed the UI token and native generation, but not the loaded config.
39134 transfers the config through the package-scoped, non-exported reload
receiver and updates the VPN process cache before `serviceReload`. No persistent
data/API migration is involved. Earlier matrix successes without a config
binding are not proof that every intended server was actually exercised.

`dns_path_diagnostics.py` compares the fixed payload endpoint through system
DNS, loopback HTTP proxy, and public A records obtained through HTTPS DNS over
the proxy. It retains only allowlisted HTTP measurements and address classes;
addresses and raw stderr stay in memory. `--resolve` preserves the original
TLS hostname. CNAME chains, nonpublic answers and malformed responses are not
accepted by this deliberately narrow diagnostic. A sequential path comparison
during changing connectivity cannot establish DNS as the cause of a failure.

No profile data migration is introduced. Do not uninstall or clear app data.
For APK rollback, rebuild the intended prior source with the same signing key
and a higher versionCode, then `adb install -r`. Preserve the working diff and
test evidence. Do not revert unrelated work or publish a soak APK as a release.
