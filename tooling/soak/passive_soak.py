"""Control the device-resident passive 24-hour diagnostics in a soak APK.

This helper never changes profiles, radios, VPN state, or app lifecycle. It sends
DUMP-protected explicit service commands and accepts only a fixed sanitized
response. A service is used because some OEM power managers drop even explicit
manifest broadcasts while the app is idle.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import time
import uuid
from pathlib import Path


PACKAGE = "online.dnsai.ivanvpn"
COMPONENT = f"{PACKAGE}/.qa.SoakControlReceiver"
SERVICE_COMPONENT = f"{PACKAGE}/.qa.SoakControlService"
ACTION = f"{PACKAGE}.action.SOAK_CONTROL"
REMOTE_DIRECTORY = f"/sdcard/Android/data/{PACKAGE}/files/soak"
REMOTE_STATUS = f"{REMOTE_DIRECTORY}/passive-status.json"
COMMANDS = {"start": "passive-start", "status": "passive-status",
            "stop": "passive-stop", "export": "passive-export"}
STATUS_FIELDS = {
    "schema", "requestId", "command", "timestampMs", "secretsIncluded", "sampling",
    "ok", "errorCode", "active", "available", "startedAtMs", "endsAtMs", "endedAtMs",
    "events", "rotatedEvents", "durationMs", "durationHours", "durationDays", "mode",
    "artifactFile", "artifactBytes", "artifactSha256",
}
NUMERIC_FIELDS = {
    "timestampMs", "startedAtMs", "endsAtMs", "endedAtMs", "events", "rotatedEvents",
    "durationMs", "durationHours", "durationDays", "artifactBytes",
}
BOOLEAN_FIELDS = {"secretsIncluded", "ok", "active", "available"}
REQUEST_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")
SHA256 = re.compile(r"[0-9a-f]{64}")
SERIAL = re.compile(r"[A-Za-z0-9._:-]{1,128}")
MAX_STATUS_BYTES = 64 * 1024
MAX_ARTIFACT_BYTES = 24 * 1024 * 1024
ARTIFACT_FILE = "passive-soak.zip"


class PassiveSoakError(RuntimeError):
    """Fixed-code failure that cannot contain device output or secrets."""


class StaleStatus(PassiveSoakError):
    pass


def resolve_serial(adb, supplied=None, timeout=10):
    if supplied:
        if not SERIAL.fullmatch(supplied):
            raise PassiveSoakError("invalid_serial")
        return supplied
    environment = os.environ.copy()
    environment.pop("ANDROID_SERIAL", None)
    try:
        result = subprocess.run(
            [adb, "devices"],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
            env=environment,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise PassiveSoakError("adb_discovery_failed") from error
    if result.returncode != 0:
        raise PassiveSoakError("adb_discovery_failed")
    devices = []
    for line in result.stdout.splitlines()[1:]:
        fields = line.split()
        if len(fields) >= 2 and fields[1] == "device" and SERIAL.fullmatch(fields[0]):
            devices.append(fields[0])
    devices = sorted(set(devices))
    if not devices:
        raise PassiveSoakError("no_authorized_device")
    if len(devices) != 1:
        raise PassiveSoakError("multiple_authorized_devices")
    return devices[0]


def parse_status(raw, expected_request_id, expected_command):
    if not isinstance(raw, bytes) or not raw or len(raw) > MAX_STATUS_BYTES:
        raise PassiveSoakError("invalid_status_size")
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PassiveSoakError("invalid_status_json") from error
    required = {"schema", "requestId", "command", "timestampMs", "secretsIncluded",
                "sampling", "ok"}
    if (not isinstance(payload, dict) or set(payload) - STATUS_FIELDS
            or not required.issubset(payload)):
        raise PassiveSoakError("invalid_status_fields")
    if payload.get("requestId") != expected_request_id:
        raise StaleStatus("stale_status")
    if (payload.get("schema") != 1 or payload.get("command") != expected_command
            or payload.get("sampling") != "opportunistic"
            or payload.get("secretsIncluded") is not False):
        raise PassiveSoakError("invalid_status_identity")
    for key in NUMERIC_FIELDS & set(payload):
        value = payload[key]
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise PassiveSoakError("invalid_status_number")
    for key in BOOLEAN_FIELDS & set(payload):
        if not isinstance(payload[key], bool):
            raise PassiveSoakError("invalid_status_boolean")
    if payload.get("mode") not in (None, "standard", "passive_24h"):
        raise PassiveSoakError("invalid_status_mode")
    if "errorCode" in payload and payload["errorCode"] not in {
            "invalid_request", "active_run_conflict", "no_passive_run",
            "artifact_too_large", "internal_error"}:
        raise PassiveSoakError("invalid_error_code")
    if payload["ok"] is False and "errorCode" not in payload:
        raise PassiveSoakError("invalid_error_code")
    artifact_fields = {"artifactFile", "artifactBytes", "artifactSha256"}
    present_artifact_fields = artifact_fields & set(payload)
    if present_artifact_fields and present_artifact_fields != artifact_fields:
        raise PassiveSoakError("invalid_artifact_fields")
    if expected_command == COMMANDS["export"] and payload["ok"] is True:
        if present_artifact_fields != artifact_fields:
            raise PassiveSoakError("invalid_artifact_fields")
    if present_artifact_fields:
        if payload["artifactFile"] != ARTIFACT_FILE:
            raise PassiveSoakError("invalid_artifact_name")
        if not SHA256.fullmatch(str(payload.get("artifactSha256", ""))):
            raise PassiveSoakError("invalid_artifact_hash")
        size = payload.get("artifactBytes")
        if not isinstance(size, int) or isinstance(size, bool) or not 0 < size <= MAX_ARTIFACT_BYTES:
            raise PassiveSoakError("invalid_artifact_size")
    return payload


class AdbPassiveSoak:
    def __init__(self, adb, serial, control_timeout=30, export_timeout=180):
        if not serial:
            raise PassiveSoakError("serial_required")
        if control_timeout <= 0:
            raise PassiveSoakError("invalid_control_timeout")
        if export_timeout < 120:
            raise PassiveSoakError("export_timeout_too_short")
        self.adb = adb
        self.environment = os.environ.copy()
        self.environment["ANDROID_SERIAL"] = serial
        self.control_timeout = control_timeout
        self.export_timeout = export_timeout

    def _run(self, arguments, *, binary=False, timeout=None):
        try:
            return subprocess.run(
                [self.adb, *arguments],
                capture_output=True,
                text=not binary,
                timeout=timeout or self.control_timeout,
                check=False,
                env=self.environment,
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise PassiveSoakError("adb_transport_failed") from error

    def request(self, command):
        request_id = uuid.uuid4().hex
        timeout = self.export_timeout if command == COMMANDS["export"] else self.control_timeout
        control = [
            "shell", "am", "startservice", "-n", SERVICE_COMPONENT,
            "--es", "command", command, "--es", "requestId", request_id,
        ]
        result = self._run(control, timeout=timeout)
        if result.returncode != 0:
            raise PassiveSoakError("adb_broadcast_failed")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            remaining = max(1, deadline - time.monotonic())
            status = self._run(
                ["exec-out", "cat", REMOTE_STATUS],
                binary=True,
                timeout=min(self.control_timeout, remaining),
            )
            if status.returncode == 0:
                try:
                    return parse_status(status.stdout, request_id, command)
                except StaleStatus:
                    pass
                except PassiveSoakError as error:
                    # External app storage may briefly expose the old file or
                    # an incomplete read while AtomicFile replaces it. Retry
                    # only structural truncation; schema violations stay fatal.
                    if str(error) not in {
                            "invalid_status_size", "invalid_status_json"}:
                        raise
            time.sleep(0.25)
        raise PassiveSoakError("status_timeout")

    def export(self, output):
        response = self.request(COMMANDS["export"])
        if response.get("ok") is not True:
            return response
        output = Path(output)
        if output.exists():
            raise PassiveSoakError("output_exists")
        remote = f"{REMOTE_DIRECTORY}/{response['artifactFile']}"
        try:
            output.parent.mkdir(parents=True, exist_ok=True)
        except OSError as error:
            raise PassiveSoakError("local_output_failed") from error
        temporary = output.with_name(f".{output.name}.{uuid.uuid4().hex}.part")
        try:
            size, digest = self._stream_remote(remote, temporary)
            if size != response["artifactBytes"] or digest != response["artifactSha256"]:
                raise PassiveSoakError("artifact_integrity_failed")
            try:
                os.replace(temporary, output)
            except OSError as error:
                raise PassiveSoakError("local_output_failed") from error
        finally:
            if temporary.exists():
                try:
                    temporary.unlink()
                except OSError:
                    pass
        return {**response, "hostArtifact": str(output), "verified": True}

    def _stream_remote(self, remote, temporary):
        try:
            with temporary.open("xb") as stream:
                result = subprocess.run(
                    [self.adb, "exec-out", "cat", remote],
                    stdout=stream,
                    stderr=subprocess.DEVNULL,
                    timeout=self.export_timeout,
                    check=False,
                    env=self.environment,
                )
                stream.flush()
                os.fsync(stream.fileno())
        except (OSError, subprocess.SubprocessError) as error:
            raise PassiveSoakError("artifact_read_failed") from error
        if result.returncode != 0:
            raise PassiveSoakError("artifact_read_failed")
        try:
            size = temporary.stat().st_size
            if not 0 < size <= MAX_ARTIFACT_BYTES:
                raise PassiveSoakError("invalid_artifact_size")
            digest = hashlib.sha256()
            with temporary.open("rb") as stream:
                for block in iter(lambda: stream.read(64 * 1024), b""):
                    digest.update(block)
        except OSError as error:
            raise PassiveSoakError("artifact_read_failed") from error
        return size, digest.hexdigest()


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", default="adb")
    parser.add_argument(
        "--serial",
        help="Optional ADB target; otherwise exactly one authorized device is required",
    )
    parser.add_argument("--control-timeout", type=float, default=30)
    parser.add_argument("--export-timeout", type=float, default=180,
                        help="Export broadcast/pull timeout in seconds; minimum 120")
    subparsers = parser.add_subparsers(dest="operation", required=True)
    subparsers.add_parser("start", help="Start or query the idempotent passive 24-hour run")
    subparsers.add_parser("status", help="Read passive diagnostic status")
    subparsers.add_parser("stop", help="Stop diagnostics only; never stops the VPN")
    export = subparsers.add_parser("export", help="Export and verify a sanitized ZIP snapshot")
    export.add_argument("--out", required=True)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        serial = resolve_serial(args.adb, args.serial)
        client = AdbPassiveSoak(
            args.adb,
            serial,
            control_timeout=args.control_timeout,
            export_timeout=args.export_timeout,
        )
        if args.operation == "export":
            response = client.export(args.out)
        else:
            response = client.request(COMMANDS[args.operation])
        print(json.dumps(response, ensure_ascii=True, sort_keys=True, indent=2))
        return 0 if response.get("ok") is True else 2
    except PassiveSoakError as error:
        print(json.dumps({"ok": False, "errorCode": str(error)}, sort_keys=True))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
