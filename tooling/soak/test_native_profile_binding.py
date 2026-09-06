import unittest
from dataclasses import replace
from types import SimpleNamespace
from unittest.mock import Mock, patch

from tooling.soak.native_observer import NativeSnapshot, counter_delta, native_payload_probe, parse_snapshot
from tooling.soak.native_profile_binding import NativeProfileBinding
from tooling.soak.run_24h_matrix import ProbeResult, Profile


class NativeProfileBindingTests(unittest.TestCase):
    def setUp(self):
        self.profile = Profile("p0008", "vlessXhttp", "xray")
        self.native = NativeSnapshot(42, 100, 200, 3, "Connected", True, "xray", True,
                                     1024, 2048, 107, 107, 1, 3, "a" * 64)
        self.status = dict(ok=True, profileToken="p0008", kind="vlessXhttp", engine="xray",
                           busy=False, queueActive=False, connectionState="connected", vpnStatus="Started")

    def test_binding_survives_same_config_restart_but_not_wrong_config(self):
        binding = NativeProfileBinding.establish(self.profile, self.native, self.status, self.native)
        self.assertIsNotNone(binding)
        restarted = replace(self.native, pid=44, instance=300, elapsed=350, generation=1)
        self.assertTrue(binding.matches(restarted))
        self.assertIsNone(counter_delta(self.native, restarted))
        self.assertFalse(binding.matches(replace(restarted, config_fingerprint="b" * 64)))
        self.assertFalse(binding.matches(replace(restarted, runtime="singbox")))

    def test_setup_rejects_stale_profile_generation_missing_or_unready_data(self):
        for status in [None, {}, {**self.status, "profileToken": "p0007"},
                       {**self.status, "busy": True}, {**self.status, "engine": "singBox"}]:
            self.assertIsNone(NativeProfileBinding.establish(self.profile, self.native, status, self.native))
        for native in [None, replace(self.native, generation=4), replace(self.native, tun=False),
                       replace(self.native, phase="Reconnecting"), replace(self.native, format_version=2),
                       replace(self.native, config_fingerprint=None), replace(self.native, config_fingerprint="b" * 64)]:
            self.assertIsNone(NativeProfileBinding.establish(self.profile, self.native, self.status, native))

    def test_v3_parser_rejects_unbounded_untrusted_fingerprint(self):
        base = ('Broadcast completed: result=1, data="v=3 request=q pid=42 instance=100 elapsed=200 '
                'generation=3 phase=Connected desired=true runtime=xray tun=true tx=1024 rx=2048 '
                'source=uid activeNet=107 trackedNet=107 sameNet=1 config=')
        self.assertEqual(parse_snapshot(base + 'a' * 64 + '"', 'q', '42'), self.native)
        self.assertIsNone(parse_snapshot(base + 'secret"', 'q', '42'))
        self.assertIsNone(parse_snapshot(base + 'A' * 64 + '"', 'q', '42'))
        unknown = parse_snapshot(base + 'unknown"', 'q', '42')
        self.assertIsNone(unknown.config_fingerprint)

    def test_counter_cannot_cross_config_change_even_with_same_identity(self):
        self.assertIsNone(counter_delta(self.native, replace(self.native, tx=2048, rx=4096,
                                                             config_fingerprint="b" * 64)))

    def test_bound_payload_cannot_qualify_wrong_profile_or_unknown_config(self):
        binding = NativeProfileBinding(self.profile, "a" * 64)
        post = replace(self.native, elapsed=400, tx=2048, rx=4096)
        for profile, snapshot, expected in [
            (self.profile, post, True),
            (Profile("p0011", "vlessXhttp", "xray"), post, False),
            (self.profile, replace(post, config_fingerprint=None), False),
            (self.profile, replace(post, config_fingerprint="b" * 64), False),
        ]:
            runner = SimpleNamespace(current_profile=profile, last_probe_had_traffic=True,
                probe_tick=Mock(return_value=(ProbeResult(True, True), ProbeResult(True, True, True))))
            with patch("tooling.soak.native_observer.read_native_snapshot",
                       side_effect=[(self.native, ""), (snapshot, "")]) as read:
                self.assertEqual(native_payload_probe(runner, "binding_test", binding=binding)["pass"], expected)
                self.assertTrue(all(call.kwargs == {"version": 3} for call in read.call_args_list))
        with self.assertRaises(ValueError):
            NativeProfileBinding(self.profile, None)


if __name__ == '__main__':
    unittest.main()
