"""Read-only VPN-process observations, independent of the Flutter UI lifecycle.

UID bytes include encapsulation and other app traffic. They are not UI counters,
payload byte counts, or proof of external connectivity. Pair them with HTTPS and
OS VPN state; never substitute them for those checks.
"""

import re
from dataclasses import asdict, dataclass

from tooling.soak.run_24h_matrix import VPN_PROCESS


@dataclass(frozen=True)
class NativeSnapshot:
    pid: int
    instance: int
    elapsed: int
    generation: int
    phase: str
    desired: bool
    runtime: str
    tun: bool
    tx: int
    rx: int
    active_net: int = -1
    tracked_net: int = -1
    same_net: int = -1
    format_version: int = 1
    config_fingerprint: str | None = None

    @property
    def identity(self):
        return self.pid, self.instance, self.generation, self.runtime

    @property
    def ready(self):
        return self.phase == "Connected" and self.desired and self.tun


def valid_network_flags(value):
    if not re.fullmatch(r"-1|\d{1,3}", value):
        return False
    flags = int(value)
    return flags in {-1, 0, 1} or (3 <= flags <= 127 and flags & 3 == 3)


def parse_snapshot(raw, request, expected_pid):
    if not re.fullmatch(r"[A-Za-z0-9_]{1,64}", request):
        return None
    matches = re.findall(r'^Broadcast completed: result=1, data="([^"\r\n]{1,512})"\s*$',
                         raw, re.MULTILINE)
    if len(matches) != 1:
        return None
    pairs = [item.split("=", 1) for item in matches[0].split()]
    if any(len(pair) != 2 for pair in pairs):
        return None
    fields = dict(pairs)
    expected_fields = {
        "v", "request", "pid", "instance", "elapsed", "generation", "phase",
        "desired", "runtime", "tun", "tx", "rx", "source",
    }
    version = fields.get("v")
    if version in {"2", "3"}:
        expected_fields |= {"activeNet", "trackedNet", "sameNet"}
    if version == "3":
        expected_fields.add("config")
    if len(fields) != len(pairs) or set(fields) != expected_fields:
        return None
    if (version not in {"1", "2", "3"} or fields["request"] != request or fields["source"] != "uid"
            or fields["pid"] != expected_pid
            or fields["phase"] not in {"Stopped", "Starting", "Connected", "Reconnecting", "Stopping", "Failed"}
            or fields["runtime"] not in {"unknown", "singbox", "xray"}
            or any(fields[key] not in {"true", "false"} for key in ("desired", "tun"))):
        return None
    for key in ("pid", "instance", "elapsed", "generation", "tx", "rx"):
        if not re.fullmatch(r"-?\d{1,19}", fields[key]):
            return None
        value = int(fields[key])
        minimum = -1 if key in {"tx", "rx"} else (1 if key == "pid" else 0)
        if value < minimum or value > 2**63 - 1:
            return None
    if int(fields["elapsed"]) < int(fields["instance"]):
        return None
    if version in {"2", "3"} and (not all(valid_network_flags(fields[key]) for key in ("activeNet", "trackedNet"))
                           or fields["sameNet"] not in {"-1", "0", "1"}):
        return None
    if version == "3" and not re.fullmatch(r"unknown|[0-9a-f]{64}", fields["config"]):
        return None
    return NativeSnapshot(
        **{key: int(fields[key]) for key in ("pid", "instance", "elapsed", "generation", "tx", "rx")},
        phase=fields["phase"], desired=fields["desired"] == "true",
        runtime=fields["runtime"], tun=fields["tun"] == "true",
        active_net=int(fields.get("activeNet", "-1")), tracked_net=int(fields.get("trackedNet", "-1")),
        same_net=int(fields.get("sameNet", "-1")), format_version=int(version),
        config_fingerprint=fields.get("config") if fields.get("config") != "unknown" else None,
    )


def read_native_snapshot(runner, *, version=2):
    if type(version) is not int or version not in {1, 2, 3}:
        raise ValueError("unsupported_snapshot_version")
    pid, observed = runner.pidof(VPN_PROCESS)
    if not observed:
        return None, "observer_unavailable"
    if not pid:
        return None, "vpn_process_absent"
    request = runner.next_request_id()
    result, error = runner.shell(
        "am", "broadcast", "--receiver-registered-only", "-a",
        "online.dnsai.ivanvpn.action.SOAK_NATIVE_SNAPSHOT", "-p", "online.dnsai.ivanvpn",
        "--es", "request", request, "--ei", "version", str(version), timeout=15,
    )
    if error or result is None:
        return None, "native_snapshot_unavailable"
    after_pid, after_observed = runner.pidof(VPN_PROCESS)
    if not after_observed or after_pid != pid:
        return None, "vpn_process_changed_during_query"
    snapshot = parse_snapshot(result.stdout, request, pid)
    return (snapshot, "") if snapshot else (None, "native_snapshot_invalid_or_absent")


def counter_delta(before, after):
    if before is None or after is None or before.identity != after.identity:
        return None
    if before.config_fingerprint != after.config_fingerprint:
        return None
    if after.elapsed < before.elapsed or min(before.tx, before.rx, after.tx, after.rx) < 0:
        return None
    if after.tx < before.tx or after.rx < before.rx:
        return None
    return {"tx": after.tx - before.tx, "rx": after.rx - before.rx,
            "elapsed_ms": after.elapsed - before.elapsed}


def native_payload_probe(runner, source, *, binding=None):
    before, before_error = read_native_snapshot(runner, version=3) if binding else read_native_snapshot(runner)
    tcp, https = runner.probe_tick(source)
    after, after_error = read_native_snapshot(runner, version=3) if binding else read_native_snapshot(runner)
    delta = counter_delta(before, after)
    session_verified = bool(before and after and before.ready and after.ready
                            and before.identity == after.identity
                            and before.runtime == runner.current_profile.runtime
                            and before.config_fingerprint == after.config_fingerprint)
    binding_verified = bool(binding and binding.profile == runner.current_profile
                            and binding.matches(before) and binding.matches(after))
    if binding is not None:
        session_verified = session_verified and binding_verified
    return {
        "before": asdict(before) if before else None,
        "after": asdict(after) if after else None,
        "error": before_error or after_error,
        "uid_delta": delta, "session_verified": session_verified,
        "config_binding_required": binding is not None, "config_binding_verified": binding_verified,
        "tcp_ok": tcp.observed and tcp.ok, "https_ok": https.observed and https.ok,
        "qualified_payload": runner.last_probe_had_traffic,
        "http_attempts": getattr(runner, "last_https_attempts", []),
        "pass": bool(session_verified and runner.last_probe_had_traffic
                     and tcp.observed and tcp.ok and delta is not None
                     and delta["tx"] > 0 and delta["rx"] > 0),
    }
