"""Bounded screen-off recovery checks, separate from endurance qualification."""

import argparse
import json
import re
import time
from dataclasses import asdict
from pathlib import Path

from tooling.soak.run_24h_matrix import SoakRunner, validated_inventory_profiles
from tooling.soak.native_observer import native_payload_probe


def power_state(raw):
    match = re.search(r"\bmWakefulness=(\w+)", raw)
    wakefulness = match.group(1).lower() if match else "unknown"
    return {"wakefulness": wakefulness,
            "non_interactive": wakefulness in {"asleep", "dozing"}}


def result_exit_code(report):
    return 0 if all(report.get(key) is True for key in (
        "completed", "pass", "profile_restored", "radios_restored",
    )) else 1


def offline_evidence(runner):
    wifi = runner.detect_wifi_enabled()
    data = runner.detect_mobile_enabled()
    state = runner.vpn_state()
    https = runner.https_probe()
    return {
        "wifi_enabled": wifi, "data_enabled": data,
        "https_observed": https.observed, "https_ok": https.ok,
        # A TUN stack can acknowledge TCP locally without reaching the peer.
        "pass": (wifi is False and data is False and state.observed
                 and state.network == "unknown" and https.observed and not https.ok),
    }


def wait_for_payload(runner, phase, timeout_s=120, *, native_observer=False, sustain_seconds=0):
    started = time.monotonic()
    attempts = 0
    samples = []
    first_success_ms = None
    sustained_since = None
    sustained_identity = None
    while time.monotonic() - started < timeout_s:
        state = runner.vpn_state()
        if (state.observed and state.validated
                and state.network == runner.current_network
                and state.runtime == runner.current_profile.runtime):
            attempts += 1
            if native_observer:
                evidence = native_payload_probe(runner, phase)
                samples.append(evidence)
                passed = evidence["pass"]
                after = evidence.get("after") or {}
                identity = tuple(after.get(key) for key in ("pid", "instance", "generation", "runtime"))
                if None in identity:
                    passed = False
                if identity != sustained_identity:
                    sustained_since = None
                    sustained_identity = identity
            else:
                tcp, https = runner.probe_tick(phase)
                passed = (runner.last_probe_tunnel_verified and tcp.observed and tcp.ok
                          and https.observed and https.ok)
            completed_at = time.monotonic()
            if native_observer:
                evidence["elapsed_ms"] = round((completed_at - started) * 1000)
            if completed_at - started > timeout_s:
                break
            if passed:
                if first_success_ms is None:
                    first_success_ms = round((completed_at - started) * 1000)
                if sustained_since is None:
                    sustained_since = completed_at
                if completed_at - sustained_since < sustain_seconds:
                    time.sleep(5)
                    continue
                return {"pass": True, "elapsed_ms": round(
                    (completed_at - started) * 1000), "attempts": attempts,
                    "first_success_ms": first_success_ms,
                    "sustained_ms": round((completed_at - sustained_since) * 1000),
                    "native_samples": samples}
            sustained_since = None
        else:
            sustained_since = None
        time.sleep(2)
    return {"pass": False, "elapsed_ms": round(
        (time.monotonic() - started) * 1000), "attempts": attempts,
        "first_success_ms": first_success_ms, "native_samples": samples}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--profiles", default="p0001,p0006,p0007,p0008")
    parser.add_argument("--restore-profile", required=True)
    parser.add_argument("--native-observer", action="store_true")
    parser.add_argument("--sustain-seconds", type=int, default=0)
    args = parser.parse_args()
    if not 0 <= args.sustain_seconds <= 120:
        parser.error("--sustain-seconds must be between 0 and 120")
    if args.out.exists():
        parser.error("--out must be a new directory")
    runner = SoakRunner(args.adb, args.serial, args.out)
    runner.started_monotonic = time.monotonic()
    runner.started_epoch = time.time()
    baseline_wifi = runner.detect_wifi_enabled()
    baseline_data = runner.detect_mobile_enabled()
    if baseline_wifi is None or baseline_data is None:
        raise RuntimeError("radio_baseline_unavailable")
    inventory, error = runner.bridge_request("inventory", timeout_s=30)
    if error or not inventory or not inventory.get("ok"):
        raise RuntimeError("inventory_unavailable")
    profiles = validated_inventory_profiles(inventory)
    tokens = set(args.profiles.split(","))
    if not (tokens | {args.restore_profile}) <= {p.token for p in profiles}:
        raise RuntimeError("invalid_profile_selection")
    rows = []
    report = {"completed": False, "kind": "screen_off_recovery", "results": rows,
              "native_observer": args.native_observer, "sustain_seconds": args.sustain_seconds}

    def check_payload(phase):
        return wait_for_payload(
            runner, phase, timeout_s=120 + args.sustain_seconds,
            native_observer=args.native_observer, sustain_seconds=args.sustain_seconds,
        )

    def record(profile, phase, result):
        power, power_error = runner.shell("dumpsys", "power", timeout=15)
        power_snapshot = power_state(power.stdout if not power_error and power else "")
        vpn_pid, pid_observed = runner.pidof("online.dnsai.ivanvpn:vpn")
        row = {"profile": profile.token, "kind": profile.kind,
               "phase": phase, "network": runner.current_network,
               **power_snapshot, "vpn_pid": vpn_pid,
               "pid_observed": pid_observed, "state": asdict(runner.vpn_state()),
               **result}
        if phase != "baseline":
            row["pass"] = row["pass"] and power_snapshot["non_interactive"]
        rows.append(row)
        runner.atomic_json("results.json", report)
        print(json.dumps(row), flush=True)
        return row["pass"]

    try:
        for profile in profiles:
            if profile.token not in tokens:
                continue
            runner.current_profile = profile
            runner.current_network = "wifi"
            if not runner.set_radios("wifi"):
                raise RuntimeError("radio_switch_failed")
            runner.shell("input", "keyevent", "KEYCODE_WAKEUP")
            runner.shell("am", "start", "-n", "online.dnsai.ivanvpn/.MainActivity")
            time.sleep(5)
            result, error = runner.bridge_request("activate", profile.token, timeout_s=120)
            if error or not result or not result.get("ok"):
                record(profile, "baseline", {"pass": False, "error": "activation_failed"})
                continue
            if not record(profile, "baseline", check_payload("baseline")):
                continue
            runner.shell("input", "keyevent", "KEYCODE_HOME")
            runner.shell("input", "keyevent", "KEYCODE_SLEEP")
            time.sleep(3)
            for network in ("cellular", "wifi"):
                runner.current_network = network
                if not runner.set_radios(network):
                    raise RuntimeError("radio_switch_failed")
                if not record(profile, "handover", check_payload("handover")):
                    break
                runner.shell("svc", "wifi", "disable")
                runner.shell("svc", "data", "disable")
                time.sleep(20)
                offline = offline_evidence(runner)
                record(profile, "offline", {**offline, "offline_seconds_min": 20})
                if not runner.set_radios(network):
                    raise RuntimeError("radio_restore_failed")
                if not record(profile, "outage_recovery", check_payload("outage_recovery")):
                    break
        report["completed"] = True
        report["pass"] = (len(rows) == len(tokens) * 7 and all(r["pass"] for r in rows))
    finally:
        runner.shell("svc", "data", "enable" if baseline_data else "disable")
        runner.shell("svc", "wifi", "enable" if baseline_wifi else "disable")
        runner.shell("input", "keyevent", "KEYCODE_WAKEUP")
        runner.shell("am", "start", "-n", "online.dnsai.ivanvpn/.MainActivity")
        time.sleep(5)
        status, error = runner.query_status(timeout_s=8)
        if not error and status and not status.get("busy") and not status.get("queueActive"):
            restored, restore_error = runner.bridge_request("activate", args.restore_profile)
            report["profile_restored"] = bool(not restore_error and restored and restored.get("ok"))
        else:
            report["profile_restored"] = False
        report["radios_restored"] = (runner.detect_wifi_enabled() == baseline_wifi
                                     and runner.detect_mobile_enabled() == baseline_data)
        runner.shell("input", "keyevent", "KEYCODE_HOME")
        runner.shell("input", "keyevent", "KEYCODE_SLEEP")
        runner.atomic_json("results.json", report)

    return result_exit_code(report)


if __name__ == "__main__":
    raise SystemExit(main())
