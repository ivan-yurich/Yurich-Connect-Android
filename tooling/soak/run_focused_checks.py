"""Config-bound profile/reconnect matrix; no graphical UI coverage is implied."""

import argparse
import json
import time
from pathlib import Path

from tooling.soak.bound_checks import BoundChecks
from tooling.soak.run_24h_matrix import SoakRunner, validated_inventory_profiles


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--profiles", help="Comma-separated opaque tokens; default: all")
    parser.add_argument("--restore-profile", required=True)
    parser.add_argument("--networks", default="wifi,cellular")
    args = parser.parse_args()
    if args.out.exists():
        parser.error("--out must be a new directory")
    runner = SoakRunner(args.adb, args.serial, args.out)
    runner.started_monotonic = time.monotonic()
    runner.started_epoch = time.time()
    baseline_wifi = runner.detect_wifi_enabled()
    baseline_data = runner.detect_mobile_enabled()
    baseline_screen = runner.screen_interactive()
    if baseline_wifi is None or baseline_data is None or baseline_screen is None:
        raise RuntimeError("radio_baseline_unavailable")
    networks = args.networks.split(",")
    if not networks or any(n not in {"wifi", "cellular"} for n in networks):
        parser.error("invalid_networks")
    payload, error = runner.bridge_request("inventory", timeout_s=30)
    if error or not payload or not payload.get("ok"):
        raise RuntimeError("inventory_unavailable")
    inventory = validated_inventory_profiles(payload)
    tokens = set(args.profiles.split(",")) if args.profiles else {p.token for p in inventory}
    if not tokens <= {p.token for p in inventory}:
        raise RuntimeError("invalid_profile_selection")
    if args.restore_profile not in {p.token for p in inventory}:
        raise RuntimeError("invalid_restore_profile")
    profiles = [p for p in inventory if p.token in tokens]
    rows = []
    checks = BoundChecks(runner, screen_off=not baseline_screen)
    report = {"kind": "config_bound_checks", "completed": False, "results": rows,
              "ui_coverage": "not_tested", "screen_interactive_baseline": baseline_screen}
    runner.atomic_json("results.json", report)
    try:
        for network in networks:
            if not runner.set_radios(network):
                raise RuntimeError("radio_switch_failed")
            runner.current_network = network
            time.sleep(5)
            for profile in profiles:
                runner.current_profile = profile
                for command in ("activate", "reconnect"):
                    row = checks.command(profile, command)
                    row["probe"] = checks.sample("focused_bound")
                    row["pass"] = row["binding_verified"] and row["probe"]["pass"]
                    rows.append(row)
                    runner.atomic_json("results.json", report)
                    print(json.dumps(row), flush=True)
                    status, status_error = runner.query_status(timeout_s=8)
                    if status_error or not status or status.get("busy") or status.get("queueActive"):
                        raise RuntimeError("command_queue_not_quiescent")
        report["completed"] = True
        report["pass"] = bool(rows) and all(row["pass"] for row in rows)
    except Exception as error:
        report["interruption"] = type(error).__name__
        report["pass"] = False
        raise
    finally:
        runner.shell("svc", "data", "enable" if baseline_data else "disable")
        runner.shell("svc", "wifi", "enable" if baseline_wifi else "disable")
        time.sleep(5)
        status, error = runner.query_status(timeout_s=8)
        if not error and status and not status.get("busy") and not status.get("queueActive"):
            restore_profile = next(p for p in inventory if p.token == args.restore_profile)
            runner.current_network = "wifi" if baseline_wifi else "cellular"
            restored = checks.command(restore_profile)
            report["profile_restored"] = restored["binding_verified"]
        else:
            report["profile_restored"] = False
        report["radios_restored"] = (runner.detect_wifi_enabled() == baseline_wifi
                                     and runner.detect_mobile_enabled() == baseline_data)
        if runner.screen_interactive() != baseline_screen:
            runner.shell("input", "keyevent", "KEYCODE_WAKEUP" if baseline_screen else "KEYCODE_SLEEP")
        report["screen_restored"] = runner.screen_interactive() == baseline_screen
        report["ambiguous_profiles"] = sorted(checks.registry.ambiguous_tokens)
        report["pass"] = bool(report.get("pass") and report["profile_restored"]
                              and report["radios_restored"] and report["screen_restored"]
                              and not report["ambiguous_profiles"])
        runner.atomic_json("results.json", report)
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
