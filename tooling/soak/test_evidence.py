"""Regression checks for evidence from the interrupted September soak."""

import subprocess
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import Mock, patch

from tooling.soak.run_24h_matrix import (
    ExitEvent,
    PassiveCounterEvent,
    ProbeResult,
    Profile,
    SoakRunner,
    VpnState,
    parse_exit_info,
    evaluate_passive_counters,
)
from tooling.soak.run_network_recovery_checks import offline_evidence, power_state, wait_for_payload


class EvidenceTests(unittest.TestCase):
    def runner(self):
        runner = SoakRunner("adb", "serial", Path("unused"))
        runner.append_csv = Mock()
        runner.observe_issue = Mock()
        runner.event = Mock()
        return runner

    def test_pidof_observes_only_successful_numeric_pid(self):
        runner = self.runner()
        runner.shell = Mock(return_value=(subprocess.CompletedProcess([], 0, "123\n", ""), ""))
        self.assertEqual(runner.pidof("process"), ("123", True))

    def test_pidof_no_match_is_observed_absence(self):
        runner = self.runner()
        runner.shell = Mock(return_value=(subprocess.CompletedProcess([], 1, "", ""), "nonzero"))
        self.assertEqual(runner.pidof("process"), ("", True))

    def test_pidof_adb_errors_are_unknown_not_process_absence(self):
        runner = self.runner()
        for stderr in ("error: closed", "error: device unauthorized", "adb: error: connection reset"):
            with self.subTest(stderr=stderr):
                runner.shell = Mock(return_value=(subprocess.CompletedProcess([], 1, "", stderr), "nonzero"))
                self.assertEqual(runner.pidof("process"), ("", False))

    def test_pidof_unexpected_result_is_unknown(self):
        runner = self.runner()
        for code, stdout, stderr in ((0, "", ""), (0, "0", ""), (0, "123 456", ""),
                                     (0, "unexpected", ""), (1, "123", ""), (2, "", "")):
            with self.subTest(code=code, stdout=stdout):
                runner.shell = Mock(return_value=(subprocess.CompletedProcess([], code, stdout, stderr),
                                                 "nonzero" if code else ""))
                self.assertEqual(runner.pidof("process"), ("", False))

    def test_pidof_transport_error_and_timeout_are_unknown(self):
        runner = self.runner()
        for result, error in ((None, "timeout"), (None, "host_command_error"),
                              (subprocess.CompletedProcess([], 1, "", ""), "observer_unavailable")):
            with self.subTest(error=error):
                runner.shell = Mock(return_value=(result, error))
                self.assertEqual(runner.pidof("process"), ("", False))

    def test_sigkill_is_a_failure_but_not_a_native_crash(self):
        runner = self.runner()
        event = ExitEvent("e1", "2026-09-04 12:00:00.000", "vpn", 2,
                          "signaled", 0, "unknown", -1, -1, status=9)
        self.assertEqual(runner.classify_exit_event(event), ("signaled_exit", True))
        self.assertEqual(runner.classify_exit_event(replace(event, reason_code=5)),
                         ("native_crash", True))
        runner.planned_vpn_exit_event_pending = False
        runner.planned_vpn_exit_event_ambiguous_pending = True
        self.assertEqual(runner.classify_exit_event(replace(event, status=11)),
                         ("signaled_exit", True))
        runner.planned_vpn_exit_event_ambiguous_pending = False
        runner.planned_vpn_exit_event_pending = True
        self.assertEqual(runner.classify_exit_event(event),
                         ("expected_vpn_signal", False))
        self.assertEqual(runner.classify_exit_event(replace(event, status=11)),
                         ("signaled_exit", True))
        self.assertEqual(runner.classify_exit_event(replace(event, reason_code=5)),
                         ("native_crash", True))

    def test_exit_parser_keeps_signal_without_persisting_process_details(self):
        text = """timestamp=2026-09-04 12:00:00.000 pid=123
process=online.dnsai.ivanvpn:vpn reason=2 (SIGNALED) subreason=0 (UNKNOWN) status=9
importance=300 pss=1MB rss=2MB
"""
        self.assertEqual(parse_exit_info(text)[0].status, 9)
        self.assertEqual(parse_exit_info(text.replace(" status=9", ""))[0].status, -1)

    def run_probe(self, before, after):
        runner = self.runner()
        runner.current_profile = Profile("p0001", "naive", "singBox")
        runner.current_network = "wifi"
        runner.vpn_state = Mock(side_effect=[before, after])
        runner.tcp_probe = Mock(return_value=ProbeResult(True, True))
        runner.https_probe = Mock(return_value=ProbeResult(True, True, True))
        runner.read_device_epoch = Mock(return_value=1000.0)
        runner.probe_tick()
        row = runner.append_csv.call_args.args[1]
        return runner, row

    def test_direct_internet_with_no_vpn_does_not_qualify_payload(self):
        runner, row = self.run_probe(VpnState(observed=True), VpnState(observed=True))
        self.assertTrue(row["https_ok"])
        self.assertFalse(row["https_tunnel_ok"])
        self.assertFalse(runner.last_probe_had_traffic)
        self.assertEqual(runner.payload_probe_epochs, [])

    def test_tunnel_disappearing_during_https_does_not_qualify_payload(self):
        before = VpnState(True, True, "wifi", "singbox")
        runner, row = self.run_probe(before, VpnState(observed=True))
        self.assertFalse(row["tunnel_verified"])
        self.assertFalse(runner.last_probe_had_traffic)

    def test_wrong_runtime_does_not_qualify_payload(self):
        state = VpnState(True, True, "wifi", "xray")
        runner, row = self.run_probe(state, state)
        self.assertFalse(row["tunnel_verified"])
        self.assertFalse(runner.last_probe_had_traffic)

    def test_validated_target_on_both_sides_qualifies_payload(self):
        state = VpnState(True, True, "wifi", "singbox")
        runner, row = self.run_probe(state, state)
        self.assertTrue(row["https_tunnel_ok"])
        self.assertTrue(runner.last_probe_had_traffic)
        self.assertEqual(len(runner.payload_probe_epochs), 1)

    def test_payload_counter_correlation_uses_phone_clock_when_host_is_ahead(self):
        state = VpnState(True, True, "wifi", "singbox")
        with patch("tooling.soak.run_24h_matrix.time.time", return_value=1027.0):
            runner, _ = self.run_probe(state, state)
        self.assertEqual(runner.payload_probe_epochs, [1000.0])
        before = PassiveCounterEvent("a", 999.0, "p0001", 1, 4096, 4096)
        after = PassiveCounterEvent("b", 1001.0, "p0001", 1, 4096, 4096)
        self.assertTrue(evaluate_passive_counters(
            before, [after], runner.payload_probe_epochs).stalled)

    def test_post_transition_baseline_uses_phone_epoch_and_monotonic_grace(self):
        runner = self.runner()
        runner.current_profile = Profile("p0001", "naive", "singBox")
        runner.vpn_state = Mock(return_value=VpnState(True, True, "wifi", "singbox"))
        runner.read_device_epoch = Mock(return_value=1000.0)
        with patch("tooling.soak.run_24h_matrix.time.time", return_value=1027.0), patch(
                "tooling.soak.run_24h_matrix.time.monotonic", return_value=50.0):
            runner.begin_post_transition_counter_baseline()
        current = PassiveCounterEvent("c", 1001.0, "p0001", 2, 1024, 1024)
        runner.read_passive_counter_events = Mock(return_value=([current], ""))
        with patch("tooling.soak.run_24h_matrix.time.time", return_value=5000.0), patch(
                "tooling.soak.run_24h_matrix.time.monotonic", return_value=51.0):
            runner.counter_tick()
        self.assertEqual(runner.counter_previous, current)
        self.assertFalse(runner.counter_baseline_pending)

    def test_missing_device_clock_blocks_qualification_and_does_not_use_host_time(self):
        runner = self.runner()
        runner.shell = Mock(return_value=(None, "observer_unavailable"))
        self.assertIsNone(runner.read_device_epoch())
        self.assertEqual(runner.device_clock_failures, 1)
        self.assertFalse(runner.summary()["verdict"]["observer_gates"]["device_clock_integrity"])
        for raw in ("1788585134.744898640\n", "1788585134.%N\n", "nan", ""):
            with self.subTest(raw=raw):
                runner = self.runner()
                runner.shell = Mock(return_value=(subprocess.CompletedProcess([], 0, raw, ""), ""))
                result = runner.read_device_epoch()
                self.assertEqual(result is not None, raw.startswith("1788585134.744"))

    def test_fd_listing_counts_entries_and_rejects_denied_or_malformed_output(self):
        for listing, error, expected in [("0\n1\n2\n45\n", "", 4),
                                         ("", "nonzero", -1),
                                         ("53\nPermission denied\n", "", -1)]:
            with self.subTest(listing=listing):
                runner = self.runner()
                def shell(*args, **kwargs):
                    if args[0] == "ls":
                        self.assertEqual(args, ("ls", "-1", "/proc/123/fd"))
                        return subprocess.CompletedProcess(args, 1 if error else 0,
                                                           listing, ""), error
                    return subprocess.CompletedProcess(args, 0, "", ""), ""
                runner.shell = shell
                memory, _ = runner.process_memory("example", pid_override="123",
                                                  cpu_percent_override=0)
                self.assertEqual(memory.fd_count, expected)

    def test_missing_ui_counter_is_an_observer_issue(self):
        runner = self.runner()
        runner.current_profile = Profile("p0001", "naive", "singBox")
        runner.vpn_state = Mock(return_value=VpnState(True, True, "wifi", "singbox"))
        runner.read_passive_counter_events = Mock(return_value=([], ""))
        runner.counter_tick()
        calls = [call for call in runner.observe_issue.call_args_list
                 if call.args[0] == "passive_counter_missing"]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0].kwargs["severity"], "observer")
        self.assertTrue(calls[0].kwargs["bad"])

    def test_recovery_requires_verified_tunnel_and_both_probes(self):
        for verified, tcp_ok, https_ok, expected in [
            (True, True, True, True), (False, True, True, False),
            (True, True, False, False), (True, False, True, False),
        ]:
            with self.subTest(verified=verified, tcp=tcp_ok, https=https_ok):
                runner = self.runner()
                runner.current_profile = Profile("p0001", "naive", "singBox")
                runner.current_network = "wifi"
                runner.vpn_state = Mock(return_value=VpnState(True, True, "wifi", "singbox"))
                runner.probe_tick = Mock(return_value=(ProbeResult(True, tcp_ok),
                                                       ProbeResult(True, https_ok)))
                runner.last_probe_tunnel_verified = verified
                with patch("tooling.soak.run_network_recovery_checks.time.monotonic",
                           side_effect=[0, 0, 1, 121, 121]), patch(
                               "tooling.soak.run_network_recovery_checks.time.sleep"):
                    result = wait_for_payload(runner, "test")
                self.assertEqual(result["pass"], expected)

    def test_recovery_does_not_probe_the_wrong_underlying_network(self):
        runner = self.runner()
        runner.current_profile = Profile("p0001", "naive", "singBox")
        runner.current_network = "cellular"
        runner.vpn_state = Mock(return_value=VpnState(True, True, "wifi", "singbox"))
        runner.probe_tick = Mock()
        with patch("tooling.soak.run_network_recovery_checks.time.monotonic",
                   side_effect=[0, 0, 121, 121]), patch(
                       "tooling.soak.run_network_recovery_checks.time.sleep"):
            self.assertFalse(wait_for_payload(runner, "test")["pass"])
        runner.probe_tick.assert_not_called()

    def test_power_state_accepts_dozing_but_not_dreaming_or_missing_evidence(self):
        for state, expected in [("Awake", False), ("Dreaming", False),
                                ("Asleep", True), ("Dozing", True), ("", False)]:
            with self.subTest(state=state):
                self.assertEqual(power_state("mWakefulness=" + state)["non_interactive"],
                                 expected)

    def test_offline_check_requires_radio_and_external_https_evidence(self):
        for wifi, data, network, observed, https_ok, expected in [
            (False, False, "unknown", True, False, True),
            (True, False, "wifi", True, False, False),
            (False, True, "cellular", True, False, False),
            (False, False, "unknown", True, True, False),
            (False, False, "unknown", False, False, False),
        ]:
            with self.subTest(wifi=wifi, data=data, network=network,
                              observed=observed, https_ok=https_ok):
                runner = self.runner()
                runner.detect_wifi_enabled = Mock(return_value=wifi)
                runner.detect_mobile_enabled = Mock(return_value=data)
                runner.vpn_state = Mock(return_value=VpnState(True, True, network, "singbox"))
                runner.https_probe = Mock(return_value=ProbeResult(observed, https_ok))
                runner.tcp_probe = Mock(return_value=ProbeResult(True, True))
                self.assertEqual(offline_evidence(runner)["pass"], expected)
                runner.tcp_probe.assert_not_called()


if __name__ == "__main__":
    unittest.main()
