import unittest
from dataclasses import replace
from types import SimpleNamespace
from unittest.mock import Mock, patch

from tooling.soak.bound_checks import BoundChecks, ControlQueueNotQuiescent
from tooling.soak.native_observer import NativeSnapshot
from tooling.soak.native_profile_binding import NativeBindingRegistry
from tooling.soak.run_24h_matrix import Profile
from tooling.soak.run_native_soak import NativeSoak, NativeSoakTransport, classify_native_absence, evidence_verdict, matrix_pairs


class BoundChecksTests(unittest.TestCase):
    def setUp(self):
        self.profile = Profile("p0008", "vlessXhttp", "xray")
        self.native = NativeSnapshot(42, 100, 200, 3, "Connected", True, "xray", True,
                                     1024, 2048, 107, 107, 1, 3, "a" * 64)
        self.status = dict(ok=True, profileToken="p0008", kind="vlessXhttp", engine="xray",
                           busy=False, queueActive=False, connectionState="connected", vpnStatus="Started")

    def test_registry_does_not_rebind_wrong_config_on_revisit(self):
        registry = NativeBindingRegistry()
        self.assertIsNotNone(registry.accept(self.profile, self.native, self.status, self.native)[0])
        other = replace(self.native, config_fingerprint="b" * 64)
        self.assertEqual(registry.accept(self.profile, other, self.status, other)[1], "profile_config_changed")
        self.assertEqual(registry.get(self.profile).fingerprint, "a" * 64)

    def test_duplicate_invalidates_both_profiles_retroactively(self):
        registry = NativeBindingRegistry()
        registry.accept(self.profile, self.native, self.status, self.native)
        other = Profile("p0011", "vlessXhttp", "xray")
        status = {**self.status, "profileToken": other.token}
        self.assertEqual(registry.accept(other, self.native, status, self.native)[1], "ambiguous_config_ownership")
        self.assertIsNone(registry.get(self.profile))
        self.assertIsNone(registry.get(other))
        self.assertEqual(registry.ambiguous_tokens, {"p0008", "p0011"})

    def test_unknown_and_stale_binding_cannot_be_learned(self):
        registry = NativeBindingRegistry()
        self.assertIsNone(registry.accept(self.profile, self.native, {}, self.native)[0])
        self.assertIsNone(registry.accept(self.profile, self.native, self.status,
                                         replace(self.native, generation=4))[0])
        self.assertEqual(registry.bindings, {})

    def test_no_binding_cannot_fall_back_to_unbound_pass(self):
        runner = SimpleNamespace(current_profile=self.profile)
        checks = BoundChecks(runner)
        with patch("tooling.soak.bound_checks.native_payload_probe", return_value={"pass": True, "error": ""}):
            self.assertFalse(checks.sample("test")["pass"])

    def test_periodic_probe_never_launches_activity_or_queries_ui(self):
        runner = Mock(current_profile=self.profile)
        checks = BoundChecks(runner)
        checks.registry.accept(self.profile, self.native, self.status, self.native)
        checks.control_verified = True
        with patch("tooling.soak.bound_checks.native_payload_probe", return_value={"pass": True}) as probe:
            self.assertTrue(checks.sample("test")["pass"])
            self.assertIsNotNone(probe.call_args.kwargs["binding"])
        runner.shell.assert_not_called()
        runner.query_status.assert_not_called()
        runner.bridge_request.assert_not_called()

    def test_failed_control_cannot_reuse_previous_good_binding(self):
        runner = Mock(current_profile=self.profile, bridge_foreground_fallbacks=0)
        runner.bridge_request.return_value = (None, "timeout")
        checks = BoundChecks(runner)
        checks.registry.accept(self.profile, self.native, self.status, self.native)
        checks.control_verified = True
        with patch("tooling.soak.bound_checks.read_native_snapshot", return_value=(self.native, "")):
            self.assertFalse(checks.command(self.profile)["binding_verified"])
        with patch("tooling.soak.bound_checks.native_payload_probe", return_value={"pass": True, "error": ""}):
            self.assertFalse(checks.sample("test")["pass"])

    def test_next_command_waits_for_busy_and_active_queue_to_finish(self):
        runner = Mock(current_profile=self.profile, bridge_foreground_fallbacks=0)
        runner.query_status.side_effect = [
            {"ok": True, "busy": True, "queueActive": True},
            {"ok": True, "busy": False, "queueActive": True},
            {"ok": True, "busy": False, "queueActive": False},
        ]
        states = list(runner.query_status.side_effect)
        runner.query_status.side_effect = [(status, "") for status in states]
        runner.bridge_request.return_value = ({"ok": False, "error": "connection_failed"}, "")
        checks = BoundChecks(runner)
        checks.pending_control = True
        with patch("tooling.soak.bound_checks.time.sleep"), patch(
                "tooling.soak.bound_checks.read_native_snapshot", return_value=(self.native, "")):
            checks.command(self.profile)
        self.assertEqual(runner.query_status.call_count, 3)
        runner.bridge_request.assert_called_once()

    def test_expired_pending_control_never_dispatches_or_changes_target(self):
        runner = Mock(current_profile=self.profile)
        checks = BoundChecks(runner)
        checks.pending_control = True
        other = Profile("p0011", "vlessXhttp", "xray")
        with patch("tooling.soak.bound_checks.time.monotonic", side_effect=[0, 181]):
            with self.assertRaises(ControlQueueNotQuiescent):
                checks.command(other)
        runner.bridge_request.assert_not_called()
        runner.shell.assert_not_called()
        self.assertEqual(runner.current_profile, self.profile)
        self.assertTrue(checks.pending_control)

    def test_unknown_status_cannot_release_pending_operation(self):
        runner = Mock()
        runner.query_status.return_value = (None, "status_query_failed")
        checks = BoundChecks(runner)
        checks.pending_control = True
        with patch("tooling.soak.bound_checks.time.monotonic", side_effect=[0, 0, 2, 2]), patch(
                "tooling.soak.bound_checks.time.sleep"):
            with self.assertRaises(ControlQueueNotQuiescent):
                checks.wait_for_control_completion(timeout_s=1)
        self.assertTrue(checks.pending_control)

    def test_reconnect_must_observe_new_session(self):
        runner = Mock(bridge_foreground_fallbacks=0)
        runner.bridge_request.return_value = ({"ok": True}, "")
        runner.query_status.return_value = (self.status, "")
        checks = BoundChecks(runner)
        with patch("tooling.soak.bound_checks.read_native_snapshot", return_value=(self.native, "")):
            row = checks.command(self.profile, "reconnect")
        self.assertFalse(row["binding_verified"])
        self.assertEqual(row["error"], "reconnect_session_unchanged")

    def test_plan_has_every_profile_and_transport(self):
        other = Profile("p0006", "hysteria2", "singBox")
        pairs = matrix_pairs([self.profile, other])
        self.assertEqual(len(pairs), 4)
        self.assertEqual({(p.token, n) for p, n in pairs},
                         {(p.token, n) for p in (self.profile, other) for n in ("wifi", "cellular")})

    def test_final_verdict_rejects_short_incomplete_ambiguous_or_gapped_run(self):
        good = dict(completed=True, duration_met=True, matrix_complete=True, endurance_complete=True,
                    restored=True, ambiguous_profiles=[], probe_failures=0, matrix_failures=0,
                    recovery_failures=0, crashes_anrs=0, observer_gaps=0, tun_failures=0, control_failures=0,
                    inventory_unchanged=True, app_version_unchanged=True, scenario_skips=0)
        self.assertTrue(evidence_verdict(good))
        for key in ("completed", "duration_met", "matrix_complete", "endurance_complete", "restored",
                    "inventory_unchanged", "app_version_unchanged"):
            self.assertFalse(evidence_verdict({**good, key: False}))
        for key in ("probe_failures", "matrix_failures", "recovery_failures", "crashes_anrs", "observer_gaps", "tun_failures", "control_failures", "scenario_skips"):
            self.assertFalse(evidence_verdict({**good, key: 1}))
        self.assertFalse(evidence_verdict({**good, "ambiguous_profiles": ["p0008"]}))
        self.assertFalse(evidence_verdict({**good, "error_type": "ConnectionError"}))
        self.assertFalse(evidence_verdict({}))

    def test_outage_stop_always_restores_transport(self):
        runner = Mock(current_network="wifi")
        runner.shell.return_value = (object(), "")
        runner.set_radios.return_value = True
        soak = NativeSoak(runner)
        soak.save = Mock()
        soak.sample = Mock(return_value={"pass": True})
        soak.wait = Mock(side_effect=InterruptedError())
        with self.assertRaises(InterruptedError):
            soak.outage()
        runner.set_radios.assert_called_once_with("wifi")

    def test_failed_baseline_never_injects_outage_or_claims_recovery_failure(self):
        runner = Mock(current_network="wifi", current_profile=self.profile)
        soak = NativeSoak(runner)
        soak.save = Mock()
        soak.sample = Mock(return_value={"pass": False})
        soak.recover = Mock()
        soak.outage()
        runner.shell.assert_not_called()
        runner.set_radios.assert_not_called()
        soak.recover.assert_not_called()
        row = runner.append_jsonl.call_args.args[1]
        self.assertTrue(row["skipped"])
        self.assertFalse(row["pass"])
        self.assertEqual(soak.report["scenario_skips"], 1)
        self.assertEqual(soak.report["recovery_failures"], 0)

    def test_failed_handover_baseline_preserves_network_and_records_skip(self):
        runner = Mock(current_network="wifi", current_profile=self.profile)
        soak = NativeSoak(runner)
        soak.save = Mock()
        soak.sample = Mock(return_value={"pass": False})
        soak.network, soak.recover = Mock(), Mock()
        soak.handover("cellular")
        soak.network.assert_not_called()
        soak.recover.assert_not_called()
        self.assertEqual(runner.current_network, "wifi")
        row = runner.append_jsonl.call_args.args[1]
        self.assertEqual(row["reason"], "baseline_unhealthy")
        self.assertTrue(row["skipped"])
        self.assertEqual(soak.report["scenario_skips"], 1)

    def test_healthy_handover_retains_failed_recovery(self):
        runner = Mock(current_network="wifi", current_profile=self.profile)
        soak = NativeSoak(runner)
        soak.sample = Mock(return_value={"pass": True})
        soak.network = Mock(return_value=True)
        soak.recover = Mock(return_value=(False, [{"pass": False}], 150))
        soak.handover("cellular")
        soak.network.assert_called_once_with("cellular")
        row = runner.append_jsonl.call_args.args[1]
        self.assertTrue(row["baseline_verified"])
        self.assertFalse(row["skipped"])
        self.assertFalse(row["pass"])
        self.assertEqual(soak.report["recovery_failures"], 1)

    def test_network_change_waits_for_outstanding_control(self):
        runner = Mock(current_network="wifi")
        soak = NativeSoak(runner)
        soak.checks.wait_for_control_completion = Mock(side_effect=ControlQueueNotQuiescent())
        with self.assertRaises(ControlQueueNotQuiescent):
            soak.network("cellular")
        runner.set_radios.assert_not_called()
        self.assertEqual(runner.current_network, "wifi")

    def test_known_absence_is_not_an_unknown_observer_or_a_crash(self):
        self.assertEqual(classify_native_absence("vpn_process_absent", "handover_recovery", False),
                         "transition_native_absence")
        self.assertEqual(classify_native_absence("vpn_process_absent", "background_hold", False), "tun_failures")
        self.assertEqual(classify_native_absence("vpn_process_absent", "planned_outage", True),
                         "transition_native_absence")
        self.assertEqual(classify_native_absence("observer_unavailable", "handover_recovery", False), "observer_gaps")

    def test_skipped_handover_still_sets_up_next_endurance_network(self):
        runner = Mock(current_network="cellular", current_profile=None, profiles=[self.profile])
        soak = NativeSoak(runner)
        soak.handover = Mock()
        soak.network = Mock(side_effect=lambda target: setattr(runner, "current_network", target))
        soak.command = Mock(side_effect=RuntimeError("test_setup_boundary"))
        with patch("tooling.soak.run_native_soak.time.monotonic", return_value=0):
            with self.assertRaisesRegex(RuntimeError, "test_setup_boundary"):
                soak.endurance_phase(1500)
        soak.handover.assert_called_once_with("wifi")
        soak.network.assert_called_once_with("wifi")
        soak.command.assert_called_once_with(self.profile)
        self.assertEqual(runner.current_network, "wifi")

    def test_same_network_does_not_claim_handover_coverage(self):
        runner = Mock(current_network="wifi", current_profile=self.profile)
        soak = NativeSoak(runner)
        soak.sample, soak.network = Mock(), Mock()
        soak.handover("wifi")
        soak.sample.assert_not_called()
        soak.network.assert_not_called()
        runner.append_jsonl.assert_not_called()

    def test_legacy_poller_uses_native_heartbeat_callback(self):
        runner = object.__new__(NativeSoakTransport)
        runner.last_heartbeat_monotonic = 0
        runner.heartbeat_callback = Mock()
        runner.atomic_json = Mock()
        runner.write_heartbeat(force=True)
        runner.heartbeat_callback.assert_called_once_with()
        runner.atomic_json.assert_not_called()

    def test_recovery_requires_stable_session_and_cannot_pass_late(self):
        for restart, duration, expected, expected_count in (
            (False, 10, True, 3), (True, 10, True, 4), (False, 151, False, 1),
        ):
            clock = [0.0]
            calls = [0]
            soak = NativeSoak(Mock())
            soak.observe = Mock()

            def sample(*_, **__):
                calls[0] += 1
                clock[0] += duration
                after = {"pid": 42, "instance": 100, "generation": 1, "runtime": "xray"}
                if restart and calls[0] >= 2:
                    after = {**after, "generation": 2}
                return {"pass": True, "after": after}

            def wait(seconds):
                clock[0] += seconds

            soak.sample, soak.wait = sample, wait
            with patch("tooling.soak.run_native_soak.time.monotonic", side_effect=lambda: clock[0]):
                passed, attempts, _ = soak.recover("test")
            self.assertEqual(passed, expected)
            self.assertEqual(len(attempts), expected_count)


if __name__ == "__main__":
    unittest.main()
