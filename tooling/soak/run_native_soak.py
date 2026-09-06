"""Native config-bound matrix and screen-off endurance; not UI certification.

Reuse ADB, HTTP, resource and exit-info parsers from the legacy matrix. Do not
inherit its Flutter counter/main-process liveness qualification for background VPN.
"""

import argparse
import hashlib
import os
import signal
import time
from collections import Counter
from dataclasses import asdict
from pathlib import Path

from tooling.soak.bound_checks import BoundChecks, ControlQueueNotQuiescent
from tooling.soak.native_health_events import NativeHealthCapture
from tooling.soak.native_observer import read_native_snapshot
from tooling.soak.run_24h_matrix import SoakRunner, utc_now, validated_inventory_profiles


def matrix_pairs(profiles):
    return [(profile, network) for network in ("wifi", "cellular") for profile in profiles]


def classify_native_absence(error, phase, expected_outage):
    if error != "vpn_process_absent":
        return "observer_gaps"
    return ("transition_native_absence" if expected_outage or phase.endswith("recovery")
            else "tun_failures")


def evidence_verdict(report):
    """Completion and diagnostic coverage are separate from connectivity success."""
    return bool(report.get("completed") and report.get("duration_met")
                and report.get("matrix_complete") and report.get("endurance_complete")
                and report.get("restored") and not report.get("error_type")
                and not report.get("ambiguous_profiles")
                and report.get("probe_failures") == 0 and report.get("matrix_failures") == 0
                and report.get("recovery_failures") == 0 and report.get("crashes_anrs") == 0
                and report.get("observer_gaps") == 0 and report.get("tun_failures") == 0
                and report.get("control_failures") == 0 and report.get("inventory_unchanged")
                and report.get("scenario_skips") == 0
                and report.get("app_version_unchanged"))


class NativeSoakTransport(SoakRunner):
    """Prevent the legacy bridge poller from overwriting native heartbeat fields."""

    heartbeat_callback = None

    def write_heartbeat(self, force=False):
        now = time.monotonic()
        if self.heartbeat_callback is not None and (force or now - self.last_heartbeat_monotonic >= 15):
            self.last_heartbeat_monotonic = now
            self.heartbeat_callback()


class NativeSoak:
    def __init__(self, runner, hours=24, probe_interval=120, preflight_only=False):
        self.r = runner
        self.hours = hours
        self.probe_interval = probe_interval
        self.preflight_only = preflight_only
        self.checks = BoundChecks(runner)
        self.capture = None
        self.stopped = False
        self.initial_profile = None
        self.last_native = None
        self.next_resource = 0.0
        self.last_sample_at = None
        self.failure_streak = 0
        self.matrix = []
        self.endurance = []
        self.report = dict(
            scope="native_config_bound_background", ui_coverage="not_tested",
            ui_counters="not_tested", browser="not_tested", battery_only_doze="not_tested",
            hours_target=None if preflight_only else hours,
            mode="preflight" if preflight_only else "endurance",
            pid=os.getpid(), started_utc=utc_now(), completed=False,
            phase="setup", profile=None, network=None, probe_successes=0, probe_failures=0,
            max_failure_streak=0, max_probe_gap_s=0, matrix_failures=0, recovery_failures=0,
            observer_gaps=0, tun_failures=0, crashes_anrs=0, control_failures=0,
            transition_native_absence=0, scenario_skips=0,
            background_pid_changes=0, background_session_changes=0,
            log_event_counts={}, restored=False,
        )
        runner.heartbeat_callback = self.save

    def stop(self, *_):
        self.stopped = True

    def check_stop(self):
        if self.stopped or (self.r.out_dir / "STOP").exists():
            raise InterruptedError("stop_requested")
        if not self.r.device_available():
            raise ConnectionError("adb_unavailable")

    def flush_logs(self, *, ending=False):
        if self.capture is None:
            return
        data = self.capture.drain()
        counts = Counter(self.report["log_event_counts"])
        for event in data["events"]:
            self.r.append_jsonl("native-health.jsonl", event)
            counts[event["code"]] += 1
        self.report["log_event_counts"] = dict(counts)
        self.report["log_capture"] = {k: v for k, v in data.items() if k != "events"}
        if data["dropped"] or data["read_error"] or (not ending and not data["running"]):
            self.report["observer_gaps"] += 1

    def save(self):
        self.flush_logs()
        self.report.update(updated_utc=utc_now(), elapsed_s=self.r.elapsed_s(),
                           foreground_fallbacks=self.r.bridge_foreground_fallbacks,
                           ambiguous_profiles=sorted(self.checks.registry.ambiguous_tokens))
        self.r.atomic_json("heartbeat.json", self.report)

    def scan_exits(self, context):
        events = self.r.read_exit_info()
        if events is None:
            self.report["observer_gaps"] += 1
            return
        for event in reversed(events):
            if event.event_id in self.r.seen_exit_ids:
                continue
            self.r.seen_exit_ids.add(event.event_id)
            # Context is correlation, not permission to suppress a crash or ANR.
            self.r.append_jsonl("native-exits.jsonl", {**asdict(event), "context": context,
                                                      "detected_utc": utc_now()})
            if event.reason_code in {4, 5, 6}:
                self.report["crashes_anrs"] += 1

    def resources(self):
        if time.monotonic() < self.next_resource:
            return
        self.r.memory_tick()
        self.scan_exits(self.report["phase"])
        self.next_resource = time.monotonic() + 300
        rows = self.r.memory_records["vpn"]
        if rows and rows[-1]["battery_temp_c"] >= 43:
            raise RuntimeError("thermal_guard_stop")

    def wait(self, seconds, *, resources=True):
        deadline = time.monotonic() + max(0, seconds)
        while time.monotonic() < deadline:
            self.check_stop()
            if resources:
                self.resources()
            self.save()
            time.sleep(min(10, max(0, deadline - time.monotonic())))

    def sample(self, source, *, qualify=True):
        self.check_stop()
        started = time.monotonic()
        row = self.checks.sample(source)
        row.update(source=source, profile=self.r.current_profile.token,
                   kind=self.r.current_profile.kind, network=self.r.current_network,
                   timestamp_utc=utc_now(), elapsed_s=self.r.elapsed_s(),
                   duration_ms=round((time.monotonic() - started) * 1000))
        if qualify:
            if self.last_sample_at is not None:
                self.report["max_probe_gap_s"] = max(
                    self.report["max_probe_gap_s"], round(started - self.last_sample_at, 1))
            self.last_sample_at = started
            key = "probe_successes" if row["pass"] else "probe_failures"
            self.report[key] += 1
            self.failure_streak = 0 if row["pass"] else self.failure_streak + 1
            self.report["max_failure_streak"] = max(self.report["max_failure_streak"], self.failure_streak)
        self.r.append_jsonl("bound-probes.jsonl", row)
        self.save()
        return row

    def observe(self, *, expected_outage=False):
        native, error = read_native_snapshot(self.r, version=3)
        self.r.append_jsonl("native-samples.jsonl", {
            "timestamp_utc": utc_now(), "elapsed_s": self.r.elapsed_s(),
            "phase": self.report["phase"], "expected_outage": expected_outage,
            "native": asdict(native) if native else None, "error": error,
        })
        if native is None:
            self.report[classify_native_absence(error, self.report["phase"], expected_outage)] += 1
        else:
            if not expected_outage and not native.tun:
                self.report["tun_failures"] += 1
            if self.last_native is not None:
                if (native.pid, native.instance) != (self.last_native.pid, self.last_native.instance):
                    self.report["background_pid_changes"] += 1
                if native.identity != self.last_native.identity:
                    self.report["background_session_changes"] += 1
            self.last_native = native
        return native

    def command(self, profile, command="activate"):
        self.check_stop()
        self.resources()
        self.scan_exits("before_control")
        self.report.update(profile=profile.token, network=self.r.current_network)
        self.save()
        try:
            row = self.checks.command(profile, command)
        except ControlQueueNotQuiescent:
            self.r.append_jsonl("controls.jsonl", {
                "profile": profile.token, "command": command,
                "network": self.r.current_network, "dispatched": False,
                "control_error": "control_queue_not_quiescent", "timestamp_utc": utc_now(),
            })
            raise
        self.r.append_jsonl("controls.jsonl", {**row, "timestamp_utc": utc_now()})
        self.scan_exits("after_control")
        # Do not count a controller-commanded switch as a spontaneous restart.
        self.last_native, _ = read_native_snapshot(self.r, version=3)
        self.report["control_failures"] += int(not row["binding_verified"])
        self.save()
        return row

    def network(self, network):
        self.checks.wait_for_control_completion()
        previous = self.r.current_network
        self.r.current_network = network
        if not self.r.set_radios(network):
            raise RuntimeError("radio_command_failed")
        self.report["network"] = network
        self.wait(5)
        return previous != network

    def matrix_phase(self):
        self.report["phase"] = "matrix"
        network = None
        for profile, target in matrix_pairs(self.r.profiles):
            if target != network:
                self.network(target)
                network = target
            for command in ("activate", "reconnect"):
                control = self.command(profile, command)
                probe = self.sample("matrix_" + command)
                row = {**control, "pass": control["binding_verified"] and probe["pass"]}
                self.matrix.append(row)
                self.report["matrix_failures"] += int(not row["pass"])
                self.r.atomic_json("matrix.json", self.matrix)
        self.report["matrix_complete"] = len(self.matrix) == len(self.r.profiles) * 4

    def outage(self):
        self.checks.wait_for_control_completion()
        baseline = self.sample("outage_baseline")
        if not baseline["pass"]:
            self.report["scenario_skips"] += 1
            self.r.append_jsonl("outages.jsonl", {
                "timestamp_utc": utc_now(), "profile": self.r.current_profile.token,
                "network": self.r.current_network, "baseline_verified": False,
                "skipped": True, "reason": "baseline_unhealthy", "pass": False,
            })
            self.save()
            return
        self.report["phase"] = "planned_outage"
        self.save()
        started = time.monotonic()
        try:
            for radio in ("wifi", "data"):
                result, error = self.r.shell("svc", radio, "disable")
                if error or result is None:
                    raise RuntimeError("outage_command_failed")
            self.wait(30)
            native = self.observe(expected_outage=True)
            confirmed = (self.r.detect_wifi_enabled() is False
                         and self.r.detect_mobile_enabled() is False
                         and native is not None and native.active_net == 0)
        finally:
            # Restore transport even when the stop marker arrives during the outage.
            if not self.r.set_radios(self.r.current_network):
                raise RuntimeError("outage_restore_failed")
        passed, attempts, recovery_s = self.recover("outage_recovery")
        passed = passed and confirmed
        self.report["recovery_failures"] += int(not passed)
        self.r.append_jsonl("outages.jsonl", {
            "timestamp_utc": utc_now(), "profile": self.r.current_profile.token,
            "network": self.r.current_network, "outage_confirmed": confirmed,
            "baseline_verified": True, "skipped": False,
            "duration_s": round(time.monotonic() - started, 1),
            "recovery_s": recovery_s, "attempts": attempts, "pass": passed,
        })

    def recover(self, source):
        self.report["phase"] = source
        recovery_started = time.monotonic()
        deadline = recovery_started + 150
        attempts = []
        streak = 0
        stable_since = None
        session = None
        while time.monotonic() < deadline:
            probe = self.sample(source, qualify=False)
            identity = tuple((probe.get("after") or {}).get(key)
                             for key in ("pid", "instance", "generation", "runtime"))
            if probe["pass"] and time.monotonic() <= deadline:
                if identity != session:
                    streak, stable_since = 0, time.monotonic()
                session = identity
                stable_since = stable_since if stable_since is not None else time.monotonic()
                streak += 1
            else:
                streak, stable_since, session = 0, None, None
            attempts.append({"pass": probe["pass"], "elapsed_s": round(time.monotonic() - recovery_started, 1)})
            self.observe()
            if streak >= 3 and time.monotonic() - stable_since >= 30:
                break
            self.wait(min(10, max(0, deadline - time.monotonic())))
        passed = bool(streak >= 3 and stable_since is not None
                      and time.monotonic() - stable_since >= 30 and time.monotonic() <= deadline)
        return passed, attempts, round(time.monotonic() - recovery_started, 1)

    def handover(self, network):
        previous = self.r.current_network
        if previous == network:
            return
        self.checks.wait_for_control_completion()
        baseline = self.sample("handover_baseline")
        if not baseline["pass"]:
            self.report["scenario_skips"] += 1
            self.r.append_jsonl("handovers.jsonl", {
                "timestamp_utc": utc_now(), "profile": self.r.current_profile.token,
                "from": previous, "network": network, "baseline_verified": False,
                "skipped": True, "reason": "baseline_unhealthy", "pass": False,
            })
            self.save()
            return
        self.network(network)
        passed, attempts, recovery_s = self.recover("handover_recovery")
        self.report["recovery_failures"] += int(not passed)
        self.r.append_jsonl("handovers.jsonl", {
            "timestamp_utc": utc_now(), "profile": self.r.current_profile.token,
            "from": previous, "network": network, "recovery_s": recovery_s,
            "baseline_verified": True, "skipped": False,
            "attempts": attempts, "pass": passed,
        })

    def endurance_phase(self, end):
        # One contiguous hold per profile/transport, instead of incessant UI switches.
        pairs = [(profile, network) for profile in self.r.profiles for network in ("wifi", "cellular")]
        if end - time.monotonic() < len(pairs) * 600:
            raise RuntimeError("insufficient_endurance_budget")
        slot_seconds = (end - time.monotonic()) / len(pairs)
        first = time.monotonic()
        for index, (profile, network) in enumerate(pairs):
            slot_end = first + (index + 1) * slot_seconds
            self.report.update(phase="endurance_setup", slot=index + 1, slots=len(pairs))
            self.handover(network)
            # A skipped handover does not prevent setup of the next matrix cell.
            if self.r.current_network != network:
                self.network(network)
            control = (self.command(profile) if self.r.current_profile != profile
                       else {"binding_verified": self.checks.control_verified})
            entry = self.sample("endurance_entry")
            self.outage()
            self.report["phase"] = "background_hold"
            started = time.monotonic()
            probes = []
            next_probe = started
            while time.monotonic() < slot_end:
                self.observe()
                if time.monotonic() >= next_probe:
                    probes.append(self.sample("background_hold")["pass"])
                    next_probe = time.monotonic() + self.probe_interval
                self.wait(min(30, max(0, slot_end - time.monotonic())))
            self.endurance.append({"profile": profile.token, "network": network,
                                   "hold_s": round(time.monotonic() - started, 1),
                                   "control_ok": control["binding_verified"], "entry_ok": entry["pass"],
                                   "probe_successes": sum(probes), "probe_failures": len(probes) - sum(probes)})
            self.r.atomic_json("endurance.json", self.endurance)
        self.report["endurance_complete"] = (len(self.endurance) == len(pairs)
                                              and all(row["hold_s"] >= 300 for row in self.endurance))

    def setup(self):
        r = self.r
        r.started_monotonic, r.started_epoch = time.monotonic(), time.time()
        r.output_writable = True
        r.initial_wifi_enabled = r.detect_wifi_enabled()
        r.initial_mobile_enabled = r.detect_mobile_enabled()
        r.initial_screen_interactive = r.screen_interactive()
        if None in (r.initial_wifi_enabled, r.initial_mobile_enabled, r.initial_screen_interactive):
            raise RuntimeError("device_baseline_unknown")
        if r.initial_screen_interactive:
            raise RuntimeError("screen_must_be_off_before_background_test")
        r.radio_baseline_observed = True
        before, error = read_native_snapshot(r, version=3)
        status, status_error = r.query_status(timeout_s=8)
        after, after_error = read_native_snapshot(r, version=3)
        payload, inventory_error = r.bridge_request("inventory", timeout_s=30)
        if inventory_error or not payload or payload.get("ok") is not True:
            raise RuntimeError("inventory_unavailable")
        r.profiles = validated_inventory_profiles(payload)
        self.initial_profile = next((p for p in r.profiles if status and p.token == status.get("profileToken")), None)
        if error or status_error or after_error or self.initial_profile is None:
            raise RuntimeError("initial_profile_unverified")
        binding, error = self.checks.registry.accept(self.initial_profile, before, status, after)
        if binding is None:
            raise RuntimeError("initial_config_binding_unverified")
        r.current_profile = self.initial_profile
        r.current_network = "wifi" if r.initial_wifi_enabled else "cellular"
        self.checks.control_verified = True
        r.write_exit_baseline()
        r.diagnostic_started_device_local = r.device_local_timestamp()
        self.report["profiles"] = [asdict(p) for p in r.profiles]
        self.report["app_version"] = r.package_version()
        self.report["controller_sha256"] = {
            name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
            for name in ("run_native_soak.py", "bound_checks.py", "native_profile_binding.py", "native_observer.py",
                         "run_24h_matrix.py", "native_health_events.py", "http_diagnostics.py")
        }
        self.report["baseline"] = {"wifi": r.initial_wifi_enabled, "data": r.initial_mobile_enabled,
                                   "screen": r.initial_screen_interactive, "profile": self.initial_profile.token}
        if not r.set_host_keep_awake(True):
            raise RuntimeError("host_keep_awake_failed")
        self.resources()

    def preflight_phase(self):
        self.report["phase"] = "preflight"
        self.command(self.initial_profile)
        self.sample("preflight_entry")
        self.handover("cellular")
        self.sample("preflight_cellular")
        self.handover("wifi")
        self.sample("preflight_wifi")
        self.outage()
        self.wait(30)
        self.sample("preflight_final")

    def restore(self):
        if not self.r.radio_baseline_observed:
            return
        self.r.restore_device_state()
        if self.initial_profile is not None and self.r.device_available():
            self.r.current_network = "wifi" if self.r.initial_wifi_enabled else "cellular"
            control = self.checks.command(self.initial_profile)
            self.r.restore_device_state()
            self.report["restore_payload"] = self.checks.sample("restore_verification")
            self.report["profile_restored"] = control["binding_verified"]
            self.report["radios_restored"] = (self.r.detect_wifi_enabled() == self.r.initial_wifi_enabled
                and self.r.detect_mobile_enabled() == self.r.initial_mobile_enabled
                and self.r.screen_interactive() == self.r.initial_screen_interactive)
            self.report["restored"] = bool(self.report["profile_restored"]
                and self.report["radios_restored"] and self.report["restore_payload"]["pass"])

    def run(self):
        signal.signal(signal.SIGINT, self.stop)
        signal.signal(signal.SIGTERM, self.stop)
        self.r.atomic_json("process.json", {"pid": os.getpid(), "started_utc": self.report["started_utc"],
                                          "module": "tooling.soak.run_native_soak", "out": str(self.r.out_dir)})
        try:
            self.setup()
            with NativeHealthCapture(self.r) as capture:
                self.capture = capture
                self.save()
                if self.preflight_only:
                    self.preflight_phase()
                else:
                    self.matrix_phase()
                    self.endurance_phase(self.r.started_monotonic + self.hours * 3600)
                self.report["duration_met"] = not self.preflight_only and self.r.elapsed_s() >= self.hours * 3600
                self.report["completed"] = True
                self.scan_exits("final")
                inventory, error = self.r.bridge_request("inventory", timeout_s=30)
                self.report["inventory_unchanged"] = bool(not error and inventory
                    and inventory.get("ok") is True
                    and validated_inventory_profiles(inventory) == self.r.profiles)
                self.report["app_version_unchanged"] = self.r.package_version() == self.report["app_version"]
                self.save()
            self.report["log_stopped_early"] = capture.stopped_early
            if capture.stopped_early or capture.read_error or capture.dropped:
                self.report["observer_gaps"] += 1
        except Exception as error:
            self.report["error_type"] = type(error).__name__
            # Exception text may contain secrets. Explicit, bounded operational codes only.
            if str(error) in {"thermal_guard_stop", "adb_unavailable", "stop_requested",
                              "screen_must_be_off_before_background_test", "insufficient_endurance_budget",
                              "device_baseline_unknown", "inventory_unavailable", "initial_profile_unverified",
                              "initial_config_binding_unverified", "host_keep_awake_failed",
                              "radio_command_failed", "outage_command_failed", "outage_restore_failed",
                              "control_queue_not_quiescent"}:
                self.report["stop_reason"] = str(error)
        finally:
            if self.capture is not None:
                self.flush_logs(ending=True)
                if self.capture.stopped_early:
                    self.report["observer_gaps"] += 1
            self.capture = None
            self.report["phase"] = "restoring"
            try:
                self.restore()
            except Exception as error:
                self.report["restore_error_type"] = type(error).__name__
            self.r.set_host_keep_awake(False)
            self.report["finished_utc"] = utc_now()
            self.report["phase"] = "finished"
            self.report["memory_analysis"] = "measurements_only_not_leak_certification"
            self.report["memory_samples"] = {role: len(rows) for role, rows in self.r.memory_records.items()}
            temperatures = [row["battery_temp_c"] for row in self.r.memory_records["vpn"]
                            if row["battery_temp_c"] >= 0]
            self.report["max_battery_temp_c"] = max(temperatures, default=None)
            self.report["ambiguous_profiles"] = sorted(self.checks.registry.ambiguous_tokens)
            self.report["pass"] = evidence_verdict(self.report)
            if self.preflight_only:
                self.report["preflight_pass"] = bool(self.report["completed"] and self.report["restored"]
                    and not self.report.get("error_type") and not self.report["ambiguous_profiles"]
                    and all(self.report[key] == 0 for key in (
                        "probe_failures", "recovery_failures", "control_failures", "observer_gaps", "crashes_anrs",
                        "scenario_skips", "tun_failures")))
            self.save()
            self.r.atomic_json("summary.json", self.report)
        return 0 if self.report.get("preflight_pass", self.report["pass"]) else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--hours", type=int, choices=(24, 48), default=24)
    parser.add_argument("--probe-interval", type=int, default=120)
    parser.add_argument("--preflight-only", action="store_true")
    args = parser.parse_args()
    if args.out.exists() or not 60 <= args.probe_interval <= 300:
        parser.error("new_output_directory_and_probe_interval_60_to_300_required")
    runner = NativeSoakTransport(args.adb, args.serial, args.out)
    return NativeSoak(runner, args.hours, args.probe_interval, args.preflight_only).run()


if __name__ == "__main__":
    raise SystemExit(main())
