import unittest
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from tooling.soak.http_diagnostics import HttpAttempt
from tooling.soak.run_protocol_recovery import ProtocolRecovery


class ProtocolRecoveryTest(unittest.TestCase):
    def controller(self, baseline=True, control=True):
        runner = MagicMock()
        runner.profiles = [SimpleNamespace(token="p0006")]
        run = ProtocolRecovery(runner, "p0006")
        for name in ("network", "handover", "outage", "diagnostics"):
            setattr(run, name, MagicMock())
        run.command = MagicMock(return_value={"binding_verified": control})
        run.sample = MagicMock(return_value={"pass": baseline})
        return run

    def test_no_handover_or_outage_after_failed_control(self):
        run = self.controller(control=False)
        run.preflight_phase()
        run.handover.assert_not_called()
        run.outage.assert_not_called()
        run.sample.assert_not_called()

    def test_unhealthy_baseline_skips_all_three_scenarios(self):
        run = self.controller(baseline=False)
        run.preflight_phase()
        self.assertEqual(run.report["scenario_skips"], 3)
        run.handover.assert_not_called()
        run.outage.assert_not_called()

    def test_healthy_baseline_tests_both_handovers_and_outage(self):
        run = self.controller()
        run.preflight_phase()
        self.assertEqual([call.args for call in run.handover.call_args_list],
                         [("cellular",), ("wifi",)])
        run.outage.assert_called_once()
        self.assertEqual(run.diagnostics.call_count, 3)
        self.assertFalse(run.report["completed"])
        self.assertFalse(run.report["pass"] if "pass" in run.report else False)

    def test_invalid_profile_does_not_change_network(self):
        run = self.controller()
        run.token = "p9999"
        with self.assertRaises(ValueError):
            run.preflight_phase()
        run.network.assert_not_called()

    def test_diagnostics_record_actual_controller_network_after_skipped_handover(self):
        runner = MagicMock()
        runner.current_network = "cellular"
        run = ProtocolRecovery(runner, "p0006")
        with patch("tooling.soak.run_protocol_recovery.read_native_snapshot",
                   return_value=(None, "vpn_process_absent")), patch(
                       "tooling.soak.run_protocol_recovery.measure_https",
                       return_value=HttpAttempt("health_cloudflare")):
            run.diagnostics("after_wifi_handover_or_skip")
        self.assertEqual(runner.append_jsonl.call_count, 3)
        for call in runner.append_jsonl.call_args_list:
            self.assertEqual(call.args[1]["network"], "cellular")
            self.assertEqual(call.args[1]["qualification"], "diagnostic_only")


if __name__ == "__main__":
    unittest.main()
