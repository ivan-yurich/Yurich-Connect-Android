"""Bounded read-only HTTPS checks of an existing native VPN session."""

import argparse
import time
from dataclasses import asdict
from pathlib import Path

from tooling.soak.http_diagnostics import measure_https
from tooling.soak.native_observer import counter_delta, read_native_snapshot
from tooling.soak.run_24h_matrix import SoakRunner, utc_now
from tooling.soak.run_network_recovery_checks import power_state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--rounds", type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.rounds <= 10:
        parser.error("--rounds must be between 1 and 10")
    if args.out.exists():
        parser.error("--out must be a new directory")
    runner = SoakRunner(args.adb, args.serial, args.out)
    baseline, error = read_native_snapshot(runner)
    network = runner.vpn_state()
    if error or baseline is None or not baseline.ready or not network.observed or not network.validated:
        parser.error("existing_ready_native_vpn_required")
    started = time.monotonic()
    rows = []
    report = {
        "kind": "read_only_shell_https", "started_utc": utc_now(), "completed": False,
        "baseline": asdict(baseline), "network": asdict(network), "rows": rows,
        "profile_identity_verified": False, "browser_test": False,
        "native_health_proxy_path_test": False,
    }
    runner.atomic_json("results.json", report)
    for round_index in range(args.rounds):
        for endpoint in ("payload", "health_cloudflare", "health_gstatic", "health_google"):
            before, before_error = read_native_snapshot(runner)
            os_before = runner.vpn_state()
            attempt = measure_https(runner, endpoint)
            os_after = runner.vpn_state()
            after, after_error = read_native_snapshot(runner)
            delta = counter_delta(before, after)
            same_session = bool(before and after and before.ready and after.ready
                                and before.identity == after.identity == baseline.identity)
            same_network = all(state.observed and state.validated
                               and state.runtime == baseline.runtime
                               and state.network == network.network
                               for state in (os_before, os_after))
            power, power_error = runner.shell("dumpsys", "power", timeout=15)
            row = {
                "round": round_index, "timestamp_utc": utc_now(),
                "elapsed_s": round(time.monotonic() - started, 3),
                "http": asdict(attempt), "before": asdict(before) if before else None,
                "after": asdict(after) if after else None,
                "os_before": asdict(os_before), "os_after": asdict(os_after),
                "observer_error": before_error or after_error,
                "same_session": same_session, "same_network": same_network,
                "uid_delta": delta,
                "power": power_state(power.stdout if power and not power_error else ""),
                "pass": bool(attempt.ok and same_session and same_network and delta
                             and delta["tx"] > 0 and delta["rx"] > 0),
            }
            rows.append(row)
            runner.atomic_json("results.json", report)
            print(f"round={round_index} endpoint={endpoint} observed={attempt.observed} "
                  f"http={attempt.http_code} failure={attempt.failure} pass={row['pass']}", flush=True)
    report.update(completed=True, finished_utc=utc_now(),
                  elapsed_s=round(time.monotonic() - started, 3),
                  passed=sum(row["pass"] for row in rows), total=len(rows))
    runner.atomic_json("results.json", report)
    return 0 if report["passed"] == report["total"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
