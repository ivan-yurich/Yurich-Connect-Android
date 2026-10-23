import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from tooling.soak.passive_soak import (
    COMMANDS,
    SERVICE_COMPONENT,
    AdbPassiveSoak,
    PassiveSoakError,
    StaleStatus,
    parse_status,
    resolve_serial,
)


def encoded_status(request_id="abc", command="passive-status", **updates):
    payload = {
        "schema": 1,
        "requestId": request_id,
        "command": command,
        "timestampMs": 1,
        "secretsIncluded": False,
        "sampling": "opportunistic",
        "ok": True,
        "active": True,
        "available": True,
        "durationMs": 86_400_000,
        "mode": "passive_24h",
    }
    payload.update(updates)
    return json.dumps(payload).encode()


class PassiveSoakStatusTests(unittest.TestCase):
    def test_sanitized_status_is_accepted(self):
        status = parse_status(encoded_status(), "abc", "passive-status")
        self.assertEqual(status["durationMs"], 86_400_000)

    def test_unknown_field_is_rejected_instead_of_printed(self):
        with self.assertRaisesRegex(PassiveSoakError, "invalid_status_fields"):
            parse_status(encoded_status(endpoint="private.example"), "abc", "passive-status")

    def test_stale_request_is_not_attributed_to_new_command(self):
        with self.assertRaises(StaleStatus):
            parse_status(encoded_status(request_id="old"), "new", "passive-status")

    def test_artifact_name_hash_and_size_are_bound_to_request(self):
        data = b"zip"
        status = parse_status(encoded_status(
            command="passive-export",
            artifactFile="passive-soak.zip",
            artifactBytes=len(data),
            artifactSha256=hashlib.sha256(data).hexdigest(),
        ), "abc", "passive-export")
        self.assertEqual(status["artifactBytes"], 3)


class PassiveSoakAdbTests(unittest.TestCase):
    @patch("tooling.soak.passive_soak.subprocess.run")
    def test_auto_discovery_requires_exactly_one_authorized_device(self, run):
        cases = [
            ("List of devices attached\n", "no_authorized_device"),
            ("List of devices attached\na\tdevice\nb\tunauthorized\n", "a"),
            ("List of devices attached\na\tdevice\nb\tdevice\n", "multiple_authorized_devices"),
        ]
        for output, expected in cases:
            with self.subTest(expected=expected):
                run.return_value = subprocess.CompletedProcess([], 0, output, "")
                if expected == "a":
                    self.assertEqual(resolve_serial("adb"), "a")
                else:
                    with self.assertRaisesRegex(PassiveSoakError, expected):
                        resolve_serial("adb")

    @patch("tooling.soak.passive_soak.subprocess.run")
    def test_selected_serial_is_passed_by_environment_not_command_line(self, run):
        run.return_value = subprocess.CompletedProcess([], 0, "", "")
        client = AdbPassiveSoak("adb", "private-device")
        client._run(["shell", "true"])
        self.assertEqual(run.call_args.args[0], ["adb", "shell", "true"])
        self.assertEqual(run.call_args.kwargs["env"]["ANDROID_SERIAL"], "private-device")

    @patch("tooling.soak.passive_soak.time.sleep", return_value=None)
    @patch("tooling.soak.passive_soak.uuid.uuid4")
    def test_request_uses_explicit_dump_service_and_waits_past_stale_status(self, uuid4, _sleep):
        uuid4.return_value.hex = "new"
        client = AdbPassiveSoak("adb", "device", control_timeout=1)
        client._run = Mock(side_effect=[
            subprocess.CompletedProcess([], 0, "", ""),
            subprocess.CompletedProcess([], 0, encoded_status(request_id="old"), b""),
            subprocess.CompletedProcess([], 0, encoded_status(request_id="new"), b""),
        ])
        result = client.request(COMMANDS["status"])
        self.assertTrue(result["ok"])
        self.assertEqual(client._run.call_args_list[0].args[0], [
            "shell", "am", "startservice", "-n", SERVICE_COMPONENT,
            "--es", "command", "passive-status", "--es", "requestId", "new",
        ])

    @patch("tooling.soak.passive_soak.time.sleep", return_value=None)
    @patch("tooling.soak.passive_soak.uuid.uuid4")
    def test_request_retries_a_transient_partial_status_file(self, uuid4, _sleep):
        uuid4.return_value.hex = "new"
        client = AdbPassiveSoak("adb", "device", control_timeout=1)
        client._run = Mock(side_effect=[
            subprocess.CompletedProcess([], 0, "", ""),
            subprocess.CompletedProcess([], 0, b'{"schema":', b""),
            subprocess.CompletedProcess([], 0, encoded_status(request_id="new"), b""),
        ])

        result = client.request(COMMANDS["status"])

        self.assertTrue(result["ok"])
        self.assertEqual(client._run.call_count, 3)

    def test_export_verifies_bytes_before_atomic_host_write(self):
        data = b"zip-payload"
        digest = hashlib.sha256(data).hexdigest()
        client = AdbPassiveSoak("adb", "device")
        client.request = Mock(return_value={
            "ok": True,
            "artifactFile": "passive-soak.zip",
            "artifactBytes": len(data),
            "artifactSha256": digest,
        })
        def stream_remote(_remote, temporary):
            temporary.write_bytes(data)
            return len(data), digest
        client._stream_remote = Mock(side_effect=stream_remote)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory, "passive.zip")
            result = client.export(output)
            self.assertEqual(output.read_bytes(), data)
            self.assertTrue(result["verified"])

    @patch("tooling.soak.passive_soak.uuid.uuid4")
    def test_export_is_dispatched_to_lifecycle_owned_service(self, uuid4):
        uuid4.return_value.hex = "export"
        data = b"zip"
        client = AdbPassiveSoak("adb", "device")
        client._run = Mock(side_effect=[
            subprocess.CompletedProcess([], 0, "", ""),
            subprocess.CompletedProcess([], 0, encoded_status(
                request_id="export",
                command="passive-export",
                artifactFile="passive-soak.zip",
                artifactBytes=len(data),
                artifactSha256=hashlib.sha256(data).hexdigest(),
            ), b""),
        ])
        self.assertTrue(client.request(COMMANDS["export"])["ok"])
        self.assertEqual(client._run.call_args_list[0].args[0], [
            "shell", "am", "startservice", "-n", SERVICE_COMPONENT,
            "--es", "command", "passive-export", "--es", "requestId", "export",
        ])

    def test_export_timeout_has_a_safe_minimum(self):
        with self.assertRaisesRegex(PassiveSoakError, "export_timeout_too_short"):
            AdbPassiveSoak("adb", "device", export_timeout=119)


if __name__ == "__main__":
    unittest.main()
