import json
from pathlib import Path
import tempfile
import unittest
from zipfile import ZipFile

from tooling.analyze_device_diagnostics import analyze


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


if __name__ == "__main__":
    unittest.main()
