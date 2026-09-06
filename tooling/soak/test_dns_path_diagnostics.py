import json
import unittest
from unittest.mock import Mock

from tooling.soak.dns_path_diagnostics import HOST, classify_connection, measure_path, parse_public_answers
from tooling.soak.test_http_diagnostics import result


def answer(**changes):
    value = {"Status": 0, "TC": False, "Question": [{"name": HOST + ".", "type": 1}],
             "Answer": [{"name": HOST + ".", "type": 1, "data": "1.1.1.1"}]}
    value.update(changes)
    return json.dumps(value)


class DnsPathDiagnosticsTests(unittest.TestCase):
    def test_validated_question_and_public_v4_required(self):
        self.assertEqual(parse_public_answers(answer()), ["1.1.1.1"])
        for value in [answer(Status=1), answer(Status=False), answer(TC=True),
                      answer(Question=[{"name": "another.example", "type": 1}]),
                      answer(Question=[{"name": HOST, "type": True}]), "null", "[1]", "x" * 16385]:
            self.assertEqual(parse_public_answers(value), [])

    def test_private_fakeip_malformed_and_wrong_owner_are_rejected(self):
        for ip in ["127.0.0.1", "198.18.0.1", "10.0.0.1", "::1", "1.2.3.4;id", None]:
            self.assertEqual(parse_public_answers(answer(Answer=[{"name": HOST, "type": 1, "data": ip}])), [])
        self.assertEqual(parse_public_answers(answer(Answer=[{"name": "other.example", "type": 1,
                                                              "data": "1.1.1.1"}])), [])

    def test_stderr_retains_only_classification(self):
        raw = "*   Trying 198.18.0.3:443...\nsecret certificate\nno alternative certificate subject name"
        value = classify_connection(raw)
        self.assertTrue(value["fake_ip"])
        self.assertTrue(value["hostname_mismatch"])
        self.assertNotIn("secret", json.dumps(value))
        self.assertNotIn("198.18", json.dumps(value))
        self.assertFalse(classify_connection("unavailable")["observed"])
        self.assertTrue(classify_connection("*   Trying 1.1.1.1:443...", "1.1.1.1")["matches_override"])
        self.assertFalse(classify_connection("*   Trying 8.8.8.8:443...", "1.1.1.1")["matches_override"])

    def test_override_preserves_url_and_tls_validation(self):
        runner = Mock()
        runner.shell.return_value = result(), ""
        measure_path(runner, "system_doh_address", "1.1.1.1")
        args = runner.shell.call_args.args
        self.assertIn(f"{HOST}:443:1.1.1.1", args)
        self.assertIn("https://speed.cloudflare.com/__down?bytes=65536", args)
        self.assertNotIn("--insecure", args)
        self.assertNotIn("-k", args)
        self.assertNotIn("--proxy", args)
        for ip in ["198.18.0.1", "127.0.0.1", "1.1.1.1;id", None]:
            with self.assertRaises(ValueError):
                measure_path(runner, "system_doh_address", ip)


if __name__ == "__main__":
    unittest.main()
