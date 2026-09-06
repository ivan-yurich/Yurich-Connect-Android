import subprocess
import unittest
from dataclasses import replace
from types import SimpleNamespace
from unittest.mock import Mock, patch

from tooling.soak.native_observer import counter_delta, native_payload_probe, parse_snapshot, read_native_snapshot
from tooling.soak.run_24h_matrix import ProbeResult
from tooling.soak.run_network_recovery_checks import result_exit_code, wait_for_payload


PAYLOAD = ('v=1 request=q1 pid=42 instance=100 elapsed=120 generation=3 '
           'phase=Connected desired=true runtime=xray tun=true tx=1024 rx=2048 source=uid')


def broadcast(payload=PAYLOAD):
    return f'Broadcast completed: result=1, data="{payload}"\n'


class NativeObserverTests(unittest.TestCase):
    def test_version_two_preserves_unknown_and_explicit_network_flags(self):
        payload = PAYLOAD.replace('v=1', 'v=2') + ' activeNet=107 trackedNet=1 sameNet=0'
        snapshot = parse_snapshot(broadcast(payload), 'q1', '42')
        self.assertEqual(snapshot.format_version, 2)
        self.assertEqual((snapshot.active_net, snapshot.tracked_net, snapshot.same_net), (107, 1, 0))
        self.assertEqual(parse_snapshot(broadcast(), 'q1', '42').active_net, -1)
        for raw in (payload.replace('activeNet=107', 'activeNet=4'),
                    payload.replace('sameNet=0', 'sameNet=2'),
                    payload.replace('v=2', 'v=3'), payload + ' secret=anything'):
            self.assertIsNone(parse_snapshot(broadcast(raw), 'q1', '42'))

    def test_cli_failure_and_missing_restoration_return_nonzero(self):
        report = dict(completed=True, **{"pass": True}, profile_restored=True, radios_restored=True)
        self.assertEqual(result_exit_code(report), 0)
        self.assertEqual(result_exit_code({}), 1)
        for key in report:
            for value in (False, None, "true", 1):
                self.assertEqual(result_exit_code({**report, key: value}), 1)

    def test_snapshot_is_a_native_session_not_ui_counter(self):
        value = parse_snapshot(broadcast(), "q1", "42")
        self.assertTrue(value.ready)
        self.assertEqual(value.identity, (42, 100, 3, "xray"))

    def test_missing_stale_or_malformed_response_fails_closed(self):
        for raw in ("", "Broadcast completed: result=0\n", broadcast() * 2,
                    broadcast(PAYLOAD + " secret=anything"),
                    broadcast(PAYLOAD + " rx=2048"),
                    broadcast(PAYLOAD.replace("request=q1", "request=q2")),
                    broadcast(PAYLOAD.replace("pid=42", "pid=43")),
                    broadcast(PAYLOAD.replace("tx=1024", "tx=-2")),
                    broadcast(PAYLOAD.replace("elapsed=120", "elapsed=99")),
                    broadcast(PAYLOAD.replace("desired=true", "desired=1"))):
            with self.subTest(raw=raw):
                self.assertIsNone(parse_snapshot(raw, "q1", "42"))

    def test_unsupported_bytes_do_not_look_like_zero_traffic(self):
        before = parse_snapshot(broadcast(PAYLOAD.replace("tx=1024", "tx=-1")), "q1", "42")
        self.assertIsNone(counter_delta(before, before))

    def test_delta_rejects_resets_pid_reuse_and_session_changes(self):
        before = parse_snapshot(broadcast(), "q1", "42")
        after = replace(before, tx=2048, rx=4096, elapsed=200)
        self.assertEqual(counter_delta(before, after), {"tx": 1024, "rx": 2048, "elapsed_ms": 80})
        for changed in (replace(after, pid=43), replace(after, generation=4),
                        replace(after, instance=101), replace(after, runtime="singbox"),
                        replace(after, tx=0), replace(after, elapsed=119), None):
            self.assertIsNone(counter_delta(before, changed))

    def test_observer_never_launches_absent_vpn(self):
        runner = SimpleNamespace(pidof=Mock(return_value=("", True)), shell=Mock())
        self.assertEqual(read_native_snapshot(runner), (None, "vpn_process_absent"))
        runner.shell.assert_not_called()

    def test_query_is_registered_only_and_pid_change_is_unknown(self):
        runner = SimpleNamespace(pidof=Mock(side_effect=[("42", True), ("43", True)]),
                                 next_request_id=Mock(return_value="q1"),
                                 shell=Mock(return_value=(subprocess.CompletedProcess([], 0, broadcast()), "")))
        self.assertEqual(read_native_snapshot(runner), (None, "vpn_process_changed_during_query"))
        self.assertIn("--receiver-registered-only", runner.shell.call_args.args)

    def test_uid_growth_alone_cannot_qualify_direct_or_wrong_session_traffic(self):
        before = parse_snapshot(broadcast(), "q1", "42")
        after = replace(before, tx=2048, rx=4096, elapsed=200)
        for qualified, post, expected in ((True, after, True), (False, after, False),
                                          (True, replace(after, generation=4), False),
                                          (True, replace(after, phase="Reconnecting"), False),
                                          (True, before, False)):
            runner = SimpleNamespace(
                current_profile=SimpleNamespace(runtime="xray"),
                last_probe_had_traffic=qualified,
                probe_tick=Mock(return_value=(ProbeResult(True, True), ProbeResult(True, True, True))),
            )
            with patch("tooling.soak.native_observer.read_native_snapshot",
                       side_effect=[(before, ""), (post, "")]):
                self.assertEqual(native_payload_probe(runner, "test")["pass"], expected)

    def test_one_good_probe_cannot_hide_failure_inside_sustained_window(self):
        clock = [0.0]
        runner = SimpleNamespace(
            current_profile=SimpleNamespace(runtime="xray"), current_network="wifi",
            vpn_state=Mock(return_value=SimpleNamespace(observed=True, validated=True,
                                                        network="wifi", runtime="xray")),
        )
        with patch("tooling.soak.run_network_recovery_checks.native_payload_probe",
                   side_effect=[{"pass": value, "after": {"pid": 42, "instance": 100,
                                                          "generation": 1, "runtime": "xray"}}
                                for value in (True, False, True, True)]), patch(
                "tooling.soak.run_network_recovery_checks.time.monotonic", side_effect=lambda: clock[0]), patch(
                "tooling.soak.run_network_recovery_checks.time.sleep",
                side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)):
            result = wait_for_payload(runner, "test", native_observer=True, sustain_seconds=5)
        self.assertTrue(result["pass"])
        self.assertEqual(result["attempts"], 4)
        self.assertEqual(result["first_success_ms"], 0)
        self.assertEqual(result["sustained_ms"], 5000)
        self.assertEqual(result["elapsed_ms"], 12000)

    def test_new_session_between_successful_probes_resets_sustained_window(self):
        clock = [0.0]
        runner = SimpleNamespace(
            current_profile=SimpleNamespace(runtime="xray"), current_network="wifi",
            vpn_state=Mock(return_value=SimpleNamespace(observed=True, validated=True,
                                                        network="wifi", runtime="xray")),
        )
        samples = [{"pass": True, "after": {"pid": pid, "instance": pid * 100,
                                            "generation": 1, "runtime": "xray"}}
                   for pid in (42, 43, 43)]
        with patch("tooling.soak.run_network_recovery_checks.native_payload_probe", side_effect=samples), patch(
                "tooling.soak.run_network_recovery_checks.time.monotonic", side_effect=lambda: clock[0]), patch(
                "tooling.soak.run_network_recovery_checks.time.sleep",
                side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)):
            result = wait_for_payload(runner, "test", native_observer=True, sustain_seconds=5)
        self.assertTrue(result["pass"])
        self.assertEqual(result["attempts"], 3)
        self.assertEqual(result["sustained_ms"], 5000)
        self.assertEqual(result["elapsed_ms"], 10000)

    def test_probe_finishing_after_deadline_cannot_pass(self):
        clock = [0.0]
        runner = SimpleNamespace(
            current_profile=SimpleNamespace(runtime="xray"), current_network="wifi",
            vpn_state=Mock(return_value=SimpleNamespace(observed=True, validated=True,
                                                        network="wifi", runtime="xray")),
        )
        def probe(*_):
            clock[0] = 3
            return {"pass": True, "after": {"pid": 42, "instance": 100,
                                             "generation": 1, "runtime": "xray"}}
        with patch("tooling.soak.run_network_recovery_checks.native_payload_probe", side_effect=probe), patch(
                "tooling.soak.run_network_recovery_checks.time.monotonic", side_effect=lambda: clock[0]):
            result = wait_for_payload(runner, "test", native_observer=True, timeout_s=2)
        self.assertFalse(result["pass"])
        self.assertEqual(result["elapsed_ms"], 3000)


if __name__ == "__main__":
    unittest.main()
