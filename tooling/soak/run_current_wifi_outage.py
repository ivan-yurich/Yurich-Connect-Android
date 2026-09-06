"""One Wi-Fi outage on the current profile, without launching Flutter."""

import argparse
import time
from dataclasses import asdict
from pathlib import Path

from tooling.soak.http_diagnostics import measure_https
from tooling.soak.native_health_events import NativeHealthCapture
from tooling.soak.native_observer import native_payload_probe, read_native_snapshot
from tooling.soak.run_24h_matrix import Profile, SoakRunner, parse_exit_info, utc_now
from tooling.soak.run_network_recovery_checks import offline_evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--require-network-diagnostics", action="store_true")
    parser.add_argument("--protocol", choices=("vlessXhttp", "naive"), default="vlessXhttp")
    args = parser.parse_args()
    if args.out.exists():
        parser.error("--out must be a new directory")
    runner = SoakRunner(args.adb, args.serial, args.out)
    runner.started_monotonic, runner.started_epoch = time.monotonic(), time.time()
    wifi, data = runner.detect_wifi_enabled(), runner.detect_mobile_enabled()
    native, native_error = read_native_snapshot(runner)
    status, status_error = runner.query_status(timeout_s=5)
    os_state = runner.vpn_state()
    expected_runtime = "xray" if args.protocol == "vlessXhttp" else "singbox"
    if (wifi is not True or data is None or runner.screen_interactive() is not False
            or native_error or not native or not native.ready or native.runtime != expected_runtime
            or status_error or not status or not status.get("ok")
            or status.get("kind") != args.protocol or status.get("busy") or status.get("queueActive")
            or status.get("connectionState") != "connected"
            or str(status.get("engine")).lower() != expected_runtime
            or not os_state.observed or not os_state.validated or os_state.network != "wifi"):
        parser.error("non_interactive_connected_profile_wifi_baseline_required")
    if args.require_network_diagnostics and native.format_version != 2:
        parser.error("native_observer_version_two_required")
    runner.current_profile = Profile(status["profileToken"], status["kind"], status["engine"])
    runner.current_network = "wifi"
    report = {"started_utc": utc_now(), "completed": False, "pass": False,
              "kind": "single_current_profile_wifi_outage", "protocol": args.protocol,
              "rows": [], "events": [],
              "profile_before": status, "baseline_native": asdict(native),
              "radio_baseline": {"wifi": wifi, "data": data}, "ui_opened": False}
    report["network_diagnostics_required"] = args.require_network_diagnostics
    capture = None

    def save():
        if capture is not None:
            report["health_capture"] = capture.snapshot()
        runner.atomic_json("results.json", report)

    def event(code, **fields):
        report["events"].append({"code": code, "host_utc": utc_now(),
                                 "host_monotonic": time.monotonic(),
                                 "device_epoch": runner.read_device_epoch(), **fields})
        save()

    def exits(label):
        result, error = runner.shell("dumpsys", "activity", "exit-info", "online.dnsai.ivanvpn", timeout=25)
        report[label] = {"observed": not error and result is not None,
                         "events": [asdict(e) for e in parse_exit_info(result.stdout)]
                         if not error and result else []}

    def sample(phase):
        begin = runner.read_device_epoch()
        row = native_payload_probe(runner, phase)
        row.update(phase=phase, device_start_epoch=begin,
                   device_end_epoch=runner.read_device_epoch(), host_monotonic=time.monotonic(),
                   non_interactive=runner.screen_interactive() is False)
        row["pass"] = row["pass"] and row["non_interactive"]
        report["rows"].append(row)
        save()
        print(f"phase={phase} pass={row['pass']} native="
              f"{row['after']['phase'] if row['after'] else 'absent'}", flush=True)
        return row

    def proxy_check(endpoint):
        before, before_error = read_native_snapshot(runner)
        begin = runner.read_device_epoch()
        attempt = measure_https(runner, endpoint, via_native_proxy=True)
        after, after_error = read_native_snapshot(runner)
        report.setdefault("proxy_checks", []).append({
            "device_start_epoch": begin, "device_end_epoch": runner.read_device_epoch(),
            "before": asdict(before) if before else None, "after": asdict(after) if after else None,
            "observer_error": before_error or after_error, "http": asdict(attempt),
        })
        save()

    exits("exits_before")
    save()
    try:
        with NativeHealthCapture(runner) as capture:
            for endpoint in ("health_cloudflare", "health_gstatic", "health_google"):
                if not sample("baseline")["pass"]:
                    report["error"] = "baseline_failed_no_outage"
                    return 1
                proxy_check(endpoint)
            event("outage_commands_begin")
            for radio in ("wifi", "data"):
                _, error = runner.shell("svc", radio, "disable", timeout=20)
                if error:
                    raise RuntimeError("radio_disable_failed")
            event("both_radios_disabled")
            time.sleep(20)
            report["offline"] = offline_evidence(runner)
            report["offline"]["http_attempts"] = runner.last_https_attempts
            native, error = read_native_snapshot(runner)
            report["offline"]["native"] = asdict(native) if native else None
            report["offline"]["native_error"] = error
            event("offline_verified", passed=report["offline"]["pass"])
            event("restore_commands_begin")
            if not runner.set_radios("wifi"):
                raise RuntimeError("radio_enable_failed")
            restore_at = time.monotonic()
            event("restore_commands_finished")
            first_success, sustained, sustained_identity = None, None, None
            recovery = {"pass": False, "budget_s": 150, "sustain_required_s": 30}
            report["recovery"] = recovery
            index = 0
            while time.monotonic() - restore_at < 150:
                row = sample("recovery")
                completed_at = time.monotonic()
                row["since_radio_restore_ms"] = round((completed_at - restore_at) * 1000)
                if row["pass"] and completed_at - restore_at <= 150:
                    identity = tuple(row["after"][key] for key in ("pid", "instance", "generation", "runtime"))
                    if identity != sustained_identity:
                        sustained = None
                        sustained_identity = identity
                    first_success = first_success if first_success is not None else completed_at
                    sustained = sustained if sustained is not None else completed_at
                    if completed_at - sustained >= 30:
                        recovery["pass"] = True
                        recovery["sustained_ms"] = round((completed_at - sustained) * 1000)
                        break
                else:
                    sustained = None
                proxy_check(("health_cloudflare", "health_gstatic", "health_google")[index % 3])
                index += 1
                time.sleep(5)
            recovery["first_success_ms"] = (round((first_success - restore_at) * 1000)
                                             if first_success is not None else None)
            recovery["elapsed_ms"] = round((time.monotonic() - restore_at) * 1000)
            event("recovery_window_finished", passed=recovery["pass"])
            followup_until = time.monotonic() + 90
            while time.monotonic() < followup_until:
                sample("followup")
                time.sleep(8)
            report["completed"] = True
    except Exception as error:
        report["error_type"] = type(error).__name__
        raise
    finally:
        restore_errors = []
        for radio, enabled in (("data", data), ("wifi", wifi)):
            _, error = runner.shell("svc", radio, "enable" if enabled else "disable", timeout=20)
            if error:
                restore_errors.append(radio)
        report["radio_restore_errors"] = restore_errors
        report["radios_restored"] = (not restore_errors and runner.detect_wifi_enabled() == wifi
                                     and runner.detect_mobile_enabled() == data)
        final_status, final_error = runner.query_status(timeout_s=5)
        report["profile_after"] = final_status
        report["profile_unchanged"] = (not final_error and final_status is not None
                                       and final_status.get("profileToken") == status["profileToken"])
        report["profile_observer_error"] = final_error
        report["final_os"] = asdict(runner.vpn_state())
        final_native, final_native_error = read_native_snapshot(runner)
        report["final_native"] = asdict(final_native) if final_native else None
        report["final_native_error"] = final_native_error
        exits("exits_after")
        report["finished_utc"] = utc_now()
        report["elapsed_s"] = round(time.monotonic() - runner.started_monotonic, 3)
        followup = [row for row in report["rows"] if row["phase"] == "followup"]
        health = capture.snapshot() if capture is not None else {}
        report["health_observed"] = bool(health.get("events") and health.get("dropped") == 0
                                         and health.get("read_error") is False
                                         and health.get("stopped_early") is False)
        snapshots = [snapshot for row in report["rows"] for snapshot in (row.get("before"), row.get("after"))
                     if snapshot is not None]
        stages = [e for e in health.get("events", []) if e["code"] == "probe_stage"]
        report["network_diagnostics_observed"] = bool(snapshots and stages and all(
            s.get("format_version") == 2 and s.get("active_net", -1) >= 0
            and s.get("tracked_net", -1) >= 0 for s in snapshots))
        report["pass"] = bool(report["completed"] and report.get("offline", {}).get("pass")
                              and report.get("recovery", {}).get("pass") and followup
                              and all(row["pass"] for row in followup)
                              and report["radios_restored"] and report["profile_unchanged"]
                              and report["health_observed"]
                              and (not args.require_network_diagnostics or report["network_diagnostics_observed"]))
        save()
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
