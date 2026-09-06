"""Bounded logcat capture that discards raw native health messages immediately."""

import re
import subprocess
import threading

from tooling.soak.native_observer import valid_network_flags


def parse_probe_stage(message):
    pairs = [item.split("=", 1) for item in message.removeprefix("SOAK_HEALTH ").split()]
    if any(len(pair) != 2 for pair in pairs):
        return None
    fields = dict(pairs)
    integer_keys = {"generation", "revision", "started", "finished"}
    duration_keys = {"proxyConnectMs", "proxyResponseMs", "tlsMs", "httpMs"}
    if len(fields) != len(pairs) or set(fields) != integer_keys | duration_keys | {
        "v", "endpoint", "stage", "ok", "failure", "activeNet", "trackedNet", "sameNet",
    }:
        return None
    if (fields["v"] != "1" or fields["endpoint"] not in {"cloudflare", "gstatic", "google"}
            or fields["stage"] not in {"proxy_connect", "proxy_response", "tls", "http"}
            or fields["failure"] not in {"none", "timeout", "tls", "io", "other", "proxy_status", "http_status"}
            or fields["ok"] not in {"true", "false"}
            or (fields["ok"] == "true" and fields["failure"] != "none")
            or not all(valid_network_flags(fields[key]) for key in ("activeNet", "trackedNet"))
            or fields["sameNet"] not in {"-1", "0", "1"}):
        return None
    for key in integer_keys | duration_keys:
        if not re.fullmatch(r"-?\d{1,19}", fields[key]):
            return None
        value = int(fields[key])
        if not (-1 if key in duration_keys else 0) <= value <= (3_600_000 if key in duration_keys else 2**63 - 1):
            return None
    if int(fields["finished"]) < int(fields["started"]):
        return None
    return {"code": "probe_stage", "endpoint": fields["endpoint"], "stage": fields["stage"],
            "ok": fields["ok"] == "true", "failure": fields["failure"],
            **{key: int(fields[key]) for key in integer_keys | duration_keys | {"activeNet", "trackedNet", "sameNet"}}}


def parse_health_event(line):
    if len(line) > 8192:
        return None
    match = re.match(r"\s*(\d{1,12}\.\d{1,9})\s+(\d{1,9})\s+\d+\s+[VDIWEF]\s+"
                     r"(BoxService|FlutterSingboxPlugin|DefaultNetworkMonitor|AndroidRuntime|YurichNativeHealth)\s*:\s*(.*)", line)
    if not match:
        return None
    message = match[4]
    row = {"device_epoch": float(match[1]), "pid": int(match[2])}
    if match[3] == "YurichNativeHealth":
        parsed = parse_probe_stage(message) if message.startswith("SOAK_HEALTH ") else None
        return {**row, **parsed} if parsed is not None else None
    quorum = re.search(r"External readiness quorum: ([0-3])/3", message)
    endpoint = re.search(r"Watchdog probe failed for ([a-z0-9.]+): (.+)", message)
    if quorum:
        row.update(code="quorum", successful=int(quorum[1]), total=3)
    elif endpoint:
        row.update(code="endpoint_failed", endpoint={
            "www.cloudflare.com": "cloudflare", "connectivitycheck.gstatic.com": "gstatic",
            "www.google.com": "google",
        }.get(endpoint[1], "unknown"), timeout="time" in endpoint[2].lower())
    else:
        patterns = (
            ("forced stop after graceful stop timeout", "forced_stop"),
            ("Exiting old VPN process", "clean_process_exit"),
            ("Readiness probe failed", "readiness_failed"),
            ("Watchdog: tunnel probe failed", "periodic_health_failed"),
            ("Watchdog: repeated degraded quorum", "repeated_degraded_quorum"),
            ("Watchdog: restarting VPN runtime", "runtime_restart"),
            ("Watchdog: restart skipped by cooldown", "restart_cooldown"),
            ("Watchdog: restart deferred during runtime startup grace", "startup_grace"),
            ("Watchdog: waiting for default network", "waiting_network"),
            ("Watchdog: network/wake event debounced", "network_event_debounced"),
            ("Watchdog: network/wake event", "network_event"),
            ("Reset sing-box connections after Android default-network change", "network_reset"),
            ("Tunnel readiness confirmed", "ready"),
            ("FATAL EXCEPTION", "fatal_exception"),
        )
        row["code"] = next((code for text, code in patterns if text in message), "")
        if not row["code"]:
            return None
    return row


class NativeHealthCapture:
    def __init__(self, runner, max_events=4096):
        self.runner = runner
        self.max_events = max_events
        self.events = []
        self.dropped = 0
        self.process = None
        self.thread = None
        self.lock = threading.Lock()
        self.read_error = False
        self.stopped_early = False

    def __enter__(self):
        self.process = subprocess.Popen(
            [self.runner.adb, "-s", self.runner.serial, "logcat", "-T", "1", "-v", "epoch", "-s",
             "BoxService:V", "FlutterSingboxPlugin:I", "DefaultNetworkMonitor:D", "AndroidRuntime:E",
             "YurichNativeHealth:I", "*:S"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, encoding="utf-8", errors="replace",
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()
        return self

    def _read(self):
        try:
            for line in self.process.stdout:
                row = parse_health_event(line)
                if row is None:
                    continue
                with self.lock:
                    if len(self.events) < self.max_events:
                        self.events.append(row)
                    else:
                        self.dropped += 1
        except (OSError, ValueError):
            self.read_error = True

    def snapshot(self):
        with self.lock:
            return {"events": list(self.events), "dropped": self.dropped,
                    "running": self.process is not None and self.process.poll() is None,
                    "read_error": self.read_error, "stopped_early": self.stopped_early}

    def drain(self):
        """Persist incrementally during long runs without an unbounded RAM buffer."""
        with self.lock:
            events, self.events = self.events, []
            return {"events": events, "dropped": self.dropped,
                    "running": self.process is not None and self.process.poll() is None,
                    "read_error": self.read_error, "stopped_early": self.stopped_early}

    def __exit__(self, *_):
        self.stopped_early = self.process.poll() is not None
        if self.process.poll() is None:
            self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        self.thread.join(timeout=5)
        self.process.stdout.close()
