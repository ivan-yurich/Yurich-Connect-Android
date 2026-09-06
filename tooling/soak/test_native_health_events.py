import json
import unittest

from tooling.soak.native_health_events import parse_health_event


def line(message, tag="BoxService"):
    return f"1788599900.125 5486 123 D {tag}: {message}"


class NativeHealthEventTests(unittest.TestCase):
    def test_stage_measurement_is_bounded_and_rejects_extra_fields(self):
        message = ('SOAK_HEALTH v=1 endpoint=google generation=3 revision=7 started=100 finished=250 '
                   'stage=http ok=true failure=none proxyConnectMs=10 proxyResponseMs=30 '
                   'tlsMs=60 httpMs=50 activeNet=107 trackedNet=107 sameNet=1')
        event = parse_health_event(line(message, 'YurichNativeHealth'))
        self.assertEqual(event['code'], 'probe_stage')
        self.assertEqual(event['tlsMs'], 60)
        self.assertEqual(event['activeNet'], 107)
        for bad in (message + ' token=secret', message + ' tlsMs=60',
                    message.replace('tlsMs=60', 'tlsMs=-2'),
                    message.replace('finished=250', 'finished=99'),
                    message.replace('activeNet=107', 'activeNet=128')):
            self.assertIsNone(parse_health_event(line(bad, 'YurichNativeHealth')))

    def test_quorum_preserves_only_metrics(self):
        self.assertEqual(parse_health_event(line("External readiness quorum: 2/3, healthy=true secret")),
                         {"device_epoch": 1788599900.125, "pid": 5486,
                          "code": "quorum", "successful": 2, "total": 3})

    def test_endpoint_error_drops_details(self):
        event = parse_health_event(line("Watchdog probe failed for www.google.com: timeout token=secret"))
        self.assertTrue(event["timeout"])
        self.assertEqual(event["endpoint"], "google")
        self.assertNotIn("secret", json.dumps(event))
        self.assertNotIn("www.google", json.dumps(event))

    def test_unknown_and_oversized_lines_are_ignored(self):
        for raw in (line("config=vless://secret"), line("FATAL EXCEPTION", "OtherApp"), "x" * 9000):
            self.assertIsNone(parse_health_event(raw))

    def test_planned_stop_is_not_labeled_crash(self):
        event = parse_health_event(line("forced stop after graceful stop timeout", "FlutterSingboxPlugin"))
        self.assertEqual(event["code"], "forced_stop")


if __name__ == "__main__":
    unittest.main()
