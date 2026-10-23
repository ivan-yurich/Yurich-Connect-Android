import json
from pathlib import Path
import tempfile
import unittest
from zipfile import ZipFile

from tooling.analyze_device_diagnostics import analyze, network_transport


class DiagnosticsAnalysisTest(unittest.TestCase):
    def archive(self, events, metadata=None, extra=False):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "report.zip"
        state = {"schema": 1, "startedAtMs": 1000, "endsAtMs": 604801000,
                 "exportedEvents": len(events), "active": False}
        state.update(metadata or {})
        with ZipFile(path, "w") as archive:
            archive.writestr("metadata.json", json.dumps(state))
            archive.writestr("events.jsonl", "".join(json.dumps(e) + "\n" for e in events))
            if extra:
                archive.writestr("../private", "not-allowed")
        return path

    def quorum(self, success, current=1, pid=10):
        return {"wallMs": 2000, "elapsedMs": 1000, "event": "quorum",
                "data": {"success": success, "total": 3, "desired": 1, "current": current,
                         "pid": pid, "instanceMs": pid, "profile": "anonymous", "durationMs": 50}}

    def test_quorum_and_stale_events_are_distinct(self):
        report = analyze(self.archive([self.quorum(1), self.quorum(0), self.quorum(3), self.quorum(0, 0)]))
        self.assertEqual(report["quorum_passed"], 1)
        self.assertEqual(report["quorum_failed"], 2)
        self.assertEqual(report["max_consecutive_failed_quorums"], 2)
        self.assertEqual(report["stale_or_nonrunning_quorums_excluded"], 1)

    def test_exit_metadata_counts_crash_and_anr(self):
        events = [{"wallMs": 2000, "elapsedMs": 1000, "event": "exit", "data": {"reason": code}}
                  for code in [4, 5, 6, 16]]
        report = analyze(self.archive(events))
        self.assertEqual(report["crash_exits"], 2)
        self.assertEqual(report["anr_exits"], 1)

    def test_unexpected_paths_are_not_extracted(self):
        with self.assertRaisesRegex(ValueError, "unexpected_archive_entries"):
            analyze(self.archive([], extra=True))

    def test_incomplete_snapshot_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "incomplete_event_snapshot"):
            analyze(self.archive([], {"exportedEvents": 10}))

    def test_invalid_quorum_is_not_counted_as_success(self):
        with self.assertRaisesRegex(ValueError, "invalid_quorum"):
            analyze(self.archive([self.quorum(4)]))

    def test_cumulative_drop_counters_are_not_double_counted(self):
        events = [self.quorum(3) for _ in range(2)]
        for e in events:
            e["data"]["droppedQueue"] = 2
        report = analyze(self.archive(events, {"rotatedEvents": 3}))
        self.assertEqual(report["observer_queue_drops"], 2)
        self.assertEqual(report["rotated_events"], 3)

    def test_same_protocol_profiles_remain_distinguishable(self):
        first, second = self.quorum(3), self.quorum(0)
        first["data"].update(profile="opaque_first", protocol="hysteria2")
        second["data"].update(profile="opaque_second", protocol="hysteria2")
        report = analyze(self.archive([first, second]))
        self.assertEqual(report["profile_quorums"]["opaque_first"]["passed"], 1)
        self.assertEqual(report["profile_quorums"]["opaque_second"]["failed"], 1)
        self.assertEqual(set(report["profile_protocols"].values()), {"hysteria2"})

    def test_network_transport_is_reported_without_network_identity(self):
        cellular, wifi = self.quorum(0), self.quorum(3)
        cellular["data"]["trackedNet"] = 1 | 2 | 16 | 32 | 64
        wifi["data"]["trackedNet"] = 1 | 2 | 8 | 32 | 64
        report = analyze(self.archive([cellular, wifi]))
        self.assertEqual(report["quorum_transports"]["cellular"]["failed"], 1)
        self.assertEqual(report["quorum_transports"]["wifi"]["passed"], 1)

    def test_network_transport_handles_absent_unknown_and_multiple(self):
        self.assertEqual(network_transport(-1), "unknown")
        self.assertEqual(network_transport(0), "none")
        self.assertEqual(network_transport(1), "unknown")
        self.assertEqual(network_transport(1 | 2 | 8 | 16), "multiple")

    def test_probe_failures_correlate_by_process_instance_and_probe_id(self):
        quorum = self.quorum(2)
        quorum["data"]["probeId"] = 7
        failures = [
            {"wallMs": 1900 + index, "elapsedMs": 900 + index,
             "event": "probe_failure", "data": {
                 "pid": 10, "instanceMs": 10, "probeId": probe_id, "stage": "tls",
                 "failure": "cancelled" if index == 0 else "tls",
             }}
            for index, probe_id in enumerate([7, 7, 8])
        ]
        uncorrelated = {"wallMs": 1903, "elapsedMs": 903,
                        "event": "probe_failure", "data": {"stage": "http"}}
        report = analyze(self.archive(failures + [uncorrelated, quorum]))
        self.assertEqual(report["probe_attempts_with_id"], 1)
        self.assertEqual(report["probe_failures_for_completed_attempts"], 2)
        self.assertEqual(report["probe_failures_without_completed_attempt"], 1)
        self.assertEqual(report["uncorrelated_probe_failures"], 1)
        self.assertEqual(report["probe_failure_reasons"], {
            "cancelled": 1, "tls": 2, "unknown": 1,
        })
        self.assertEqual(report["endpoint_failures_excluding_cancellation"], 3)

    def test_counter_integrity_does_not_confuse_new_generation_with_reset(self):
        def counter(native, display, generation, elapsed, instance=100):
            return {"wallMs": 2000 + elapsed, "elapsedMs": elapsed, "event": "counter",
                    "data": {"pid": 10, "nativeSessionBytes": native,
                             "displayBytes": display, "uiGeneration": generation,
                             "instanceMs": instance}}

        report = analyze(self.archive([
            counter(100, 100, 1, 1000),
            counter(200, 190, 1, 1001),
            counter(150, 150, 1, 1002),
            counter(0, 0, 2, 1003),
        ]))
        self.assertEqual(report["counter_integrity"], {
            "events": 4,
            "status": "mismatch",
            "native_display_mismatches": 1,
            "same_generation_resets": 1,
            "stable_identity_events": 4,
            "reset_tracking_complete": True,
        })

    def test_counter_integrity_does_not_merge_reused_pid_and_generation(self):
        def counter(native, instance, elapsed):
            return {"wallMs": 2000 + elapsed, "elapsedMs": elapsed, "event": "counter",
                    "data": {"pid": 10, "instanceMs": instance,
                             "nativeSessionBytes": native, "displayBytes": native,
                             "uiGeneration": 1}}

        report = analyze(self.archive([
            counter(200, 100, 1000),
            counter(0, 200, 1001),
            counter(50, 200, 1002),
        ]))
        self.assertEqual(report["counter_integrity"], {
            "events": 3,
            "status": "matched",
            "native_display_mismatches": 0,
            "same_generation_resets": 0,
            "stable_identity_events": 3,
            "reset_tracking_complete": True,
        })

    def test_legacy_counter_identity_does_not_claim_a_reset(self):
        def counter(native, elapsed):
            return {"wallMs": 2000 + elapsed, "elapsedMs": elapsed, "event": "counter",
                    "data": {"pid": 10, "nativeSessionBytes": native,
                             "displayBytes": native, "uiGeneration": 1}}

        report = analyze(self.archive([
            counter(200, 1000),
            counter(0, 1001),
        ]))
        self.assertEqual(report["counter_integrity"], {
            "events": 2,
            "status": "matched_legacy_identity_unverified",
            "native_display_mismatches": 0,
            "same_generation_resets": 0,
            "stable_identity_events": 0,
            "reset_tracking_complete": False,
        })


if __name__ == "__main__":
    unittest.main()
