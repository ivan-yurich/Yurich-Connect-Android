import json
import subprocess
import unittest
from dataclasses import asdict
from pathlib import Path
from unittest.mock import Mock

from tooling.soak.http_diagnostics import TIMINGS, measure_https, parse_attempt
from tooling.soak.run_24h_matrix import SoakRunner


def result(**changes):
    values = dict(exitcode=0, http_code=200, size_download=65536, ssl_verify_result=0,
                  **{key: 0.25 for key in TIMINGS})
    values.update(changes)
    return subprocess.CompletedProcess([], values['exitcode'], json.dumps(values), 'private stderr')


class HttpDiagnosticsTests(unittest.TestCase):
    def test_native_proxy_is_explicit_and_keeps_tls_validation(self):
        runner = Mock()
        runner.shell.return_value = result(http_code=204, size_download=0), ''
        attempt = measure_https(runner, 'health_google', via_native_proxy=True)
        self.assertTrue(attempt.ok)
        self.assertEqual(attempt.path, 'native_proxy')
        self.assertIn('http://127.0.0.1:20808', runner.shell.call_args.args)
        self.assertNotIn('-k', runner.shell.call_args.args)
        measure_https(runner, 'health_google')
        self.assertNotIn('--proxy', runner.shell.call_args.args)

    def test_success_drops_private_fields(self):
        attempt = parse_attempt('payload', result(url_effective='secret', remote_ip='private',
                                                 certs='private', errormsg='private'), '')
        self.assertTrue(attempt.ok)
        self.assertEqual(attempt.timings_ms['time_total'], 250)
        self.assertNotIn('private', json.dumps(asdict(attempt)))
        self.assertNotIn('secret', json.dumps(asdict(attempt)))

    def test_timeout_and_http_errors_are_observed_not_transport_loss(self):
        for code, status, failure in [(28, 0, 'timeout'), (22, 429, 'http_status'),
                                      (6, 0, 'dns'), (60, 0, 'certificate')]:
            attempt = parse_attempt('payload', result(exitcode=code, http_code=status), 'nonzero')
            self.assertTrue(attempt.observed)
            self.assertFalse(attempt.ok)
            self.assertEqual(attempt.failure, failure)

    def test_redirect_short_body_and_invalid_certificate_cannot_pass(self):
        for change in [dict(http_code=302), dict(size_download=128), dict(ssl_verify_result=1)]:
            self.assertFalse(parse_attempt('payload', result(**change), '').ok)
        self.assertTrue(parse_attempt('fallback', result(http_code=204, size_download=0), '').ok)

    def test_endpoint_status_is_exact(self):
        self.assertFalse(parse_attempt('payload', result(http_code=204), '').ok)
        self.assertFalse(parse_attempt('health_google', result(http_code=200), '').ok)
        self.assertTrue(parse_attempt('health_cloudflare', result(size_download=256), '').ok)

    def test_missing_malformed_and_nonfinite_metadata_are_unknown(self):
        cases = [(None, 'timeout'), (result(), 'observer_unavailable'),
                 (subprocess.CompletedProcess([], 0, '%{json}'), ''),
                 (result(time_total=float('nan')), ''), (result(time_total=-1), ''),
                 (result(time_total=10**400), ''),
                 (result(size_download=True), ''), (result(http_code=1000), ''),
                 (result(time_connect='0.1'), '')]
        for response, error in cases:
            self.assertFalse(parse_attempt('payload', response, error).observed)

    def test_fallback_retains_first_failure_and_never_claims_payload(self):
        runner = SoakRunner('adb', 'serial', Path('unused'))
        runner.shell = Mock(side_effect=[(result(exitcode=28, http_code=0), 'nonzero'),
                                         (result(http_code=204, size_download=0), '')])
        probe = runner.https_probe()
        self.assertTrue(probe.ok)
        self.assertFalse(probe.traffic_generated)
        self.assertEqual(runner.last_https_attempts[0]['failure'], 'timeout')
        self.assertEqual(len(runner.last_https_attempts), 2)
        self.assertIn('%{json}', runner.shell.call_args.args)
        self.assertNotIn('-k', runner.shell.call_args.args)


if __name__ == '__main__':
    unittest.main()
