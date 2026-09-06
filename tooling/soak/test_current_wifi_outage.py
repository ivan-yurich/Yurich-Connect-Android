import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from tooling.soak.native_observer import NativeSnapshot
from tooling.soak.run_24h_matrix import VpnState
from tooling.soak.run_current_wifi_outage import main
from tooling.soak.http_diagnostics import HttpAttempt


class CurrentWifiOutageTests(unittest.TestCase):
    def run_failure(self, *, radio_failure, protocol="vlessXhttp"):
        runtime = "xray" if protocol == "vlessXhttp" else "singbox"
        runner = Mock()
        runner.detect_wifi_enabled.return_value = True
        runner.detect_mobile_enabled.return_value = True
        runner.screen_interactive.return_value = False
        runner.query_status.return_value = ({"ok": True, "kind": protocol, "engine": runtime,
                                           "profileToken": "p0008", "connectionState": "connected",
                                           "busy": False, "queueActive": False}, "")
        runner.vpn_state.return_value = VpnState(True, True, "wifi", runtime)
        runner.read_device_epoch.return_value = 1000.0
        runner.shell.side_effect = lambda *args, **_: (
            (None, "nonzero") if args == ("svc", "wifi", "disable")
            else (None, "") if args[:1] == ("svc",) else (None, "unavailable"))
        native = NativeSnapshot(42, 100, 200, 1, "Connected", True, runtime, True, 1024, 2048)
        capture = Mock()
        capture.snapshot.return_value = {"events": [], "dropped": 0, "read_error": False,
                                         "stopped_early": False, "running": False}
        with tempfile.TemporaryDirectory() as temporary, patch(
                "sys.argv", ["test", "--adb", "adb", "--serial", "serial", "--out",
                             str(Path(temporary) / "new"), "--protocol", protocol]), patch(
                "tooling.soak.run_current_wifi_outage.SoakRunner", return_value=runner), patch(
                "tooling.soak.run_current_wifi_outage.read_native_snapshot", return_value=(native, "")), patch(
                "tooling.soak.run_current_wifi_outage.NativeHealthCapture") as capture_type, patch(
                "tooling.soak.run_current_wifi_outage.native_payload_probe",
                side_effect=lambda *_: {"pass": radio_failure, "after": {"phase": "Connected"}}), patch(
                "tooling.soak.run_current_wifi_outage.measure_https",
                return_value=HttpAttempt("health_google")):
            capture_type.return_value.__enter__.return_value = capture
            if radio_failure:
                with self.assertRaisesRegex(RuntimeError, "radio_disable_failed"):
                    main()
            else:
                self.assertEqual(main(), 1)
        commands = [call.args for call in runner.shell.call_args_list]
        self.assertIn(("svc", "wifi", "enable"), commands)
        self.assertIn(("svc", "data", "enable"), commands)
        self.assertFalse(any(args[0] in {"am", "input"} for args in commands))
        report = runner.atomic_json.call_args.args[1]
        self.assertFalse(report["pass"])
        self.assertTrue(report["profile_unchanged"])
        return commands, report

    def test_baseline_failure_never_injects_outage(self):
        commands, report = self.run_failure(radio_failure=False)
        self.assertNotIn(("svc", "wifi", "disable"), commands)
        self.assertEqual(report["error"], "baseline_failed_no_outage")

    def test_failed_radio_command_still_restores_both_radios(self):
        commands, report = self.run_failure(radio_failure=True)
        self.assertIn(("svc", "wifi", "disable"), commands)
        self.assertEqual(report["error_type"], "RuntimeError")

    def test_naive_baseline_failure_also_preserves_radios_and_profile(self):
        _, report = self.run_failure(radio_failure=False, protocol="naive")
        self.assertEqual(report["protocol"], "naive")


if __name__ == "__main__":
    unittest.main()
