#!/usr/bin/env python3
r"""24/48-hour, non-recovering Android VPN soak test.

The runner talks only to the sanitized soak Flutter bridge. It intentionally
does not know profile ids, names, endpoints, credentials, or configurations.

Example (PowerShell):

    python tooling/soak/run_24h_matrix.py `
      --adb "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" `
      --serial <adb-serial> `
      --out build/soak-tests/<run-id>/final-24h-matrix

The default qualification schedule is 86,400 seconds. It snapshots the
validated runnable inventory once, covers every observed opaque profile on
cellular and Wi-Fi for 10 minutes per matrix cell, then divides the remaining
time between sing-box, Xray, and Xray handover endurance groups. Passing
qualification is therefore scoped to the immutable observed N x 2 inventory.
Release qualification can additionally require an exact inventory size with
``--expected-profile-count`` (for example, 18).

The 48-hour plan preserves the same single N x 2 matrix and extends endurance;
it does not duplicate matrix cells.

No failed observation, probe, profile switch, or network handover causes an
automatic app/VPN/ADB restart. A transient observation is marked suspect; a
second consecutive observation creates a sanitized incident bundle.
"""

from __future__ import annotations

import argparse
import ctypes
import csv
import hashlib
import json
import math
import os
import re
import signal
import statistics
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping, Sequence

if __package__:
    from .http_diagnostics import measure_https
else:
    from http_diagnostics import measure_https

PACKAGE = "online.dnsai.ivanvpn"
MAIN_PROCESS = PACKAGE
VPN_PROCESS = f"{PACKAGE}:vpn"
SOAK_ACTION = "online.dnsai.ivanvpn.action.SOAK_FLUTTER_CONTROL"
SOAK_QUERY_ACTION = "online.dnsai.ivanvpn.action.SOAK_FLUTTER_QUERY"
SOAK_ACTIVITY = f"{PACKAGE}/.MainActivity"
SOAK_TAG = "YurichSoakBridge"
ISOLATION_TAG = "RuntimeIsolation"
BRIDGE_CONTROL_OBSERVER_ISSUE = "bridge_control_observer_unavailable"
TRANSITION_OBSERVER_ERROR_CODES = frozenset(
    {
        "observer_unavailable",
        "broadcast_launch_failed",
        "bridge_launch_failed",
        "bridge_timeout",
        "invalid_bridge_json",
        "invalid_bridge_payload",
        "invalid_status_token",
        "main_process_changed_during_status_query",
        "probe_unobserved",
        "ready_observer_unavailable",
        "status_query_failed",
    }
)

SUPPORTED_DURATION_HOURS = (24, 48)
DEFAULT_DURATION_HOURS = 24
REFERENCE_PROFILE_COUNT = 18
MATRIX_SLOT_S = 600
MATRIX_RECONNECT_AT_S = 300

HEALTH_INTERVAL_S = 30
PROBE_INTERVAL_S = 60
COUNTER_INTERVAL_S = 60
MEMORY_INTERVAL_S = 300
EXIT_INFO_INTERVAL_S = 60
HEARTBEAT_INTERVAL_S = 10
COUNTER_BASELINE_GRACE_S = COUNTER_INTERVAL_S + 15

BRIDGE_TIMEOUT_S = 180
SWITCH_READY_TIMEOUT_S = 45
HANDOVER_READY_TIMEOUT_S = 60

SWITCH_P95_SLA_MS = 5_000
SWITCH_MAX_SLA_MS = 10_000
HANDOVER_P95_SLA_MS = 15_000
HANDOVER_MAX_SLA_MS = 30_000
MAIN_PSS_SLOPE_LIMIT_KB_H = 1_024.0
VPN_PSS_SLOPE_LIMIT_KB_H = 2_048.0
PSS_GROWTH_FLOOR_KB = 32 * 1_024
FD_GROWTH_FLOOR = 32
THREAD_GROWTH_FLOOR = 16
MAIN_CPU_P95_LIMIT_PERCENT = 15.0
VPN_CPU_P95_LIMIT_PERCENT = 25.0
BATTERY_TEMPERATURE_LIMIT_C = 45.0
MAX_ISOLATED_PROBE_FAILURES = 1
MAX_ISOLATED_COUNTER_STALLS = 1
OBSERVER_COVERAGE_MIN = 0.995
OBSERVER_MAX_UNKNOWN_STREAK_S = 120
READY_OBSERVED_EVIDENCE_MIN = 0.80

TOKEN_RE = re.compile(r"^p\d{4}$")
ENUM_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]{0,63}$")
REQUEST_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
EXIT_HEADER_RE = re.compile(
    r"timestamp=(?P<timestamp>\d{4}-\d{2}-\d{2} "
    r"\d{2}:\d{2}:\d{2}\.\d+)"
)
EXIT_DETAIL_RE = re.compile(
    r"process=(?P<process>\S+)\s+reason=(?P<reason>\d+)\s+"
    r"\((?P<reason_name>[^)]+)\)\s+subreason=(?P<subreason>\d+)\s+"
    r"\((?P<subreason_name>[^)]+)\)"
)
DEVICE_LOCAL_TIMESTAMP_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+$"
)
MEMORY_AMOUNT_RE = re.compile(r"(?P<value>\d+(?:[.,]\d+)?)\s*(?P<unit>[KMG]?B)")

CSV_SCHEMAS: dict[str, tuple[str, ...]] = {
    "samples.csv": (
        "timestamp_utc",
        "elapsed_s",
        "slot_index",
        "phase",
        "profile_token",
        "engine",
        "expected_network",
        "observed",
        "vpn_validated",
        "observed_network",
        "runtime",
        "main_process_present",
        "vpn_process_present",
        "health_ok",
    ),
    "profile-matrix.csv": (
        "slot_index",
        "profile_token",
        "kind",
        "engine",
        "network",
        "started_elapsed_s",
        "finished_elapsed_s",
        "entry_ok",
        "reconnect_attempted",
        "reconnect_ok",
        "counter_observed",
        "counter_advanced",
        "payload_probe_success",
        "healthy_samples",
        "observed_samples",
        "coverage_ok",
    ),
    "switches.csv": (
        "timestamp_utc",
        "elapsed_s",
        "kind",
        "from_profile_token",
        "to_profile_token",
        "engine",
        "network",
        "command_ok",
        "ready",
        "ready_observed_samples",
        "ready_unobserved_samples",
        "tcp_ok",
        "https_ok",
        "duration_ms",
        "sla_max_ok",
        "error_code",
        "qualifying",
    ),
    "handovers.csv": (
        "timestamp_utc",
        "elapsed_s",
        "slot_index",
        "phase",
        "from_network",
        "to_network",
        "profile_token",
        "engine",
        "radio_command_ok",
        "ready",
        "ready_observed_samples",
        "ready_unobserved_samples",
        "tcp_ok",
        "https_ok",
        "duration_ms",
        "sla_max_ok",
        "error_code",
        "qualifying",
    ),
    "counters.csv": (
        "timestamp_utc",
        "elapsed_s",
        "profile_token",
        "engine",
        "network",
        "expected_network",
        "observed_network",
        "network_verified",
        "observed",
        "generation",
        "traffic_bytes",
        "traffic_delta",
        "native_delta",
        "uplink",
        "downlink",
        "session_total",
        "probe_traffic_generated",
        "counter_advanced",
        "generation_changed",
        "counter_reset",
        "counter_stalled",
        "baseline_pending",
        "baseline_grace",
    ),
    "memory.csv": (
        "timestamp_utc",
        "elapsed_s",
        "phase",
        "profile_token",
        "engine",
        "network",
        "expected_network",
        "observed_network",
        "network_verified",
        "process_role",
        "process_present",
        "process_instance",
        "pss_kb",
        "rss_kb",
        "swap_pss_kb",
        "native_heap_pss_kb",
        "java_heap_pss_kb",
        "graphics_pss_kb",
        "fd_count",
        "thread_count",
        "cpu_percent",
        "battery_level",
        "battery_temp_c",
        "battery_status",
        "app_partial_wakelocks",
        "app_partial_wakelocks_observed",
        "screen_interactive",
    ),
    "probes.csv": (
        "timestamp_utc",
        "elapsed_s",
        "source",
        "profile_token",
        "engine",
        "network",
        "expected_network",
        "observed_network",
        "network_verified",
        "tcp_observed",
        "tcp_ok",
        "https_observed",
        "https_ok",
        "https_payload_generated",
        "tunnel_verified",
        "tcp_tunnel_ok",
        "https_tunnel_ok",
    ),
    "exit-events.csv": (
        "detected_utc",
        "event_timestamp_local",
        "process_role",
        "reason_code",
        "reason_name",
        "subreason_code",
        "subreason_name",
        "status",
        "pss_kb",
        "rss_kb",
        "classification",
        "expected_transition_window",
        "transition_boundary_ambiguous",
    ),
    "runtime-isolation.csv": (
        "detected_utc",
        "elapsed_s",
        "core",
        "libbox_loaded",
        "libgojni_loaded",
        "safe",
    ),
}


@dataclass(frozen=True)
class Profile:
    token: str
    kind: str
    engine: str

    @property
    def runtime(self) -> str:
        normalized = self.engine.lower().replace("-", "")
        return "xray" if normalized == "xray" else "singbox"


def profile_switch_requires_clean_process(
    previous: Profile | None,
    target: Profile,
) -> bool:
    return previous is not None and previous.runtime != target.runtime


@dataclass(frozen=True)
class QualificationPlan:
    duration_hours: int
    duration_s: int
    profile_count: int
    matrix_duration_s: int
    engine_dwell_s: int
    handover_segment_durations_s: tuple[int, int, int]


@dataclass(frozen=True)
class Slot:
    index: int
    phase: str
    profile_token: str
    kind: str
    engine: str
    network: str
    planned_start_s: int
    duration_s: int
    reconnect_at_s: int | None = None

    @property
    def planned_end_s(self) -> int:
        return self.planned_start_s + self.duration_s


@dataclass(frozen=True)
class VpnState:
    observed: bool = False
    validated: bool = False
    network: str = "unknown"
    runtime: str = "unknown"


@dataclass(frozen=True)
class WaitReadyResult:
    ready: bool
    state: VpnState
    observed_samples: int
    unobserved_samples: int

    @property
    def sustained_observation(self) -> bool:
        total = self.observed_samples + self.unobserved_samples
        return (
            self.observed_samples >= 3
            and total > 0
            and self.observed_samples / total >= READY_OBSERVED_EVIDENCE_MIN
        )


def extract_braced_record(raw: str, start: int) -> str:
    brace_start = raw.find("{", start)
    if brace_start < 0:
        return ""
    depth = 0
    for index in range(brace_start, len(raw)):
        character = raw[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return raw[start : index + 1]
    return ""


def parse_vpn_state(raw: str) -> VpnState:
    marker = f"ni{{VPN CONNECTED extra: VPN:{PACKAGE}"
    marker_position = raw.find(marker)
    if marker_position < 0:
        marker_position = raw.find(f"VPN:{PACKAGE}")
    if marker_position < 0:
        return VpnState(observed=True)

    record_start = raw.rfind("NetworkAgentInfo{", 0, marker_position)
    if record_start < 0:
        return VpnState(observed=True)
    block = extract_braced_record(raw, record_start)
    if not block or marker_position >= record_start + len(block):
        return VpnState(observed=True)

    # Some Android builds keep the NAI's Requests/Nat464Xlat dump inside the
    # outer record. Those request capabilities describe consumers, not the VPN
    # network itself, and must never make an unvalidated cellular VPN look like
    # a validated Wi-Fi/Xray VPN.
    details_marker = re.search(
        r"(?im)^\s*(?:Nat464Xlat|Requests):",
        block,
    )
    summary_block = block[: details_marker.start()] if details_marker else block
    if marker_position >= record_start + len(summary_block):
        return VpnState(observed=True)

    upper_block = summary_block.upper()
    validated = (
        "IS_VALIDATED" in upper_block
        or "&VALIDATED" in upper_block
        or "NET_CAPABILITY_VALIDATED" in upper_block
    )
    if "WIFI|VPN" in upper_block or "VPN|WIFI" in upper_block:
        network = "wifi"
    elif "CELLULAR|VPN" in upper_block or "VPN|CELLULAR" in upper_block:
        network = "cellular"
    else:
        network = "unknown"
    lower_block = summary_block.lower()
    if "xray" in lower_block:
        runtime = "xray"
    elif "sing-box" in lower_block or "singbox" in lower_block:
        runtime = "singbox"
    else:
        runtime = "unknown"
    return VpnState(
        observed=True,
        validated=validated,
        network=network,
        runtime=runtime,
    )


@dataclass(frozen=True)
class ProbeResult:
    observed: bool
    ok: bool
    traffic_generated: bool = False


@dataclass(frozen=True)
class ExitEvent:
    event_id: str
    timestamp_local: str
    process_role: str
    reason_code: int
    reason_name: str
    subreason_code: int
    subreason_name: str
    pss_kb: int
    rss_kb: int
    status: int = -1


@dataclass(frozen=True)
class PassiveCounterEvent:
    event_id: str
    epoch: float
    token: str
    generation: int
    native_bytes: int
    display_bytes: int


@dataclass(frozen=True)
class CounterEvaluation:
    current: PassiveCounterEvent | None
    had_comparison: bool = False
    generation_changed: bool = False
    reset: bool = False
    stalled: bool = False
    advanced: bool = False
    native_delta: int = -1
    display_delta: int = -1
    payload_between: bool = False


@dataclass(frozen=True)
class ProcessMemory:
    present: bool = False
    pss_kb: int = -1
    rss_kb: int = -1
    swap_pss_kb: int = -1
    native_heap_pss_kb: int = -1
    java_heap_pss_kb: int = -1
    graphics_pss_kb: int = -1
    fd_count: int = -1
    thread_count: int = -1
    cpu_percent: float = -1.0


@dataclass
class SlotMetrics:
    entry_ok: bool = False
    reconnect_attempted: bool = False
    reconnect_ok: bool = False
    counter_observed: bool = False
    counter_advanced: bool = False
    payload_probe_success: bool = False
    healthy_samples: int = 0
    observed_samples: int = 0


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def opaque_device_token(serial: str) -> str:
    return hashlib.sha256(serial.encode("utf-8")).hexdigest()[:16]


def normalize_engine(value: str) -> str:
    return "xray" if value.lower().replace("-", "") == "xray" else "singbox"


def strict_runtime(value: str) -> str:
    normalized = value.lower().replace("-", "")
    if normalized == "xray":
        return "xray"
    if normalized == "singbox":
        return "singbox"
    return "unknown"


def safe_enum(value: Any, fallback: str = "unknown") -> str:
    text = str(value or "").strip()
    return text if ENUM_RE.fullmatch(text) else fallback


def safe_int(value: Any, fallback: int = -1) -> int:
    if isinstance(value, bool):
        return fallback
    try:
        return int(value)
    except (TypeError, ValueError, OverflowError):
        return fallback


def validated_inventory_profiles(payload: Mapping[str, Any]) -> tuple[Profile, ...]:
    raw_profiles = payload.get("profiles")
    if not isinstance(raw_profiles, list):
        raise RuntimeError("invalid_inventory")
    if safe_int(payload.get("count")) != len(raw_profiles):
        raise RuntimeError("inventory_count_mismatch")
    if not raw_profiles:
        raise RuntimeError("inventory_empty")
    if len(raw_profiles) > 9_999:
        raise RuntimeError("inventory_too_large")
    if not all(profile.get("runnable") is True for profile in raw_profiles):
        raise RuntimeError("inventory_contains_unrunnable_profile")

    tokens = [str(profile.get("profileToken") or "") for profile in raw_profiles]
    expected_tokens = [f"p{index:04d}" for index in range(1, len(raw_profiles) + 1)]
    if tokens != expected_tokens or len(tokens) != len(set(tokens)):
        raise RuntimeError("inventory_token_sequence_invalid")

    profiles = tuple(
        Profile(
            token=str(profile["profileToken"]),
            kind=str(profile["kind"]),
            engine=str(profile["engine"]),
        )
        for profile in raw_profiles
    )
    runtimes = {profile.runtime for profile in profiles}
    if not {"singbox", "xray"}.issubset(runtimes):
        raise RuntimeError("inventory_missing_required_runtime")
    return profiles


def inventory_snapshot_sha256(profiles: Sequence[Profile]) -> str:
    canonical = {
        "schema_version": 1,
        "count": len(profiles),
        "profiles": [
            {
                "engine": profile.engine,
                "kind": profile.kind,
                "profileToken": profile.token,
                "runnable": True,
            }
            for profile in profiles
        ],
    }
    serialized = json.dumps(
        canonical,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(serialized.encode("utf-8")).hexdigest()


def bool_text(value: bool | None) -> str:
    if value is None:
        return "unknown"
    return "true" if value else "false"


def percentile(values: Sequence[float], percentile_value: float) -> float:
    if not values:
        return -1.0
    ordered = sorted(values)
    if len(ordered) == 1:
        return float(ordered[0])
    position = (len(ordered) - 1) * percentile_value
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return float(ordered[lower])
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def linear_slope_per_hour(points: Sequence[tuple[int, int]]) -> float:
    usable = [(float(x), float(y)) for x, y in points if x >= 0 and y >= 0]
    if len(usable) < 3:
        return -1.0
    mean_x = statistics.fmean(point[0] for point in usable)
    mean_y = statistics.fmean(point[1] for point in usable)
    denominator = sum((point[0] - mean_x) ** 2 for point in usable)
    if denominator <= 0:
        return -1.0
    slope_per_second = sum(
        (point[0] - mean_x) * (point[1] - mean_y) for point in usable
    ) / denominator
    return slope_per_second * 3_600.0


def parse_memory_amount(value: str) -> int:
    match = MEMORY_AMOUNT_RE.search(value.upper())
    if not match:
        return -1
    number = float(match.group("value").replace(",", "."))
    multiplier = {"B": 1 / 1024, "KB": 1, "MB": 1024, "GB": 1024 * 1024}[
        match.group("unit")
    ]
    return int(number * multiplier)


def parse_active_partial_wakelocks(raw: str) -> tuple[int, bool]:
    """Return app-owned active partial wakelocks, never historical ACQ rows."""
    lines = raw.splitlines()
    header_index = -1
    declared_size = -1
    for index, line in enumerate(lines):
        match = re.fullmatch(
            r"\s*Wake Locks:\s*size=(\d+)\s*",
            line,
            re.IGNORECASE,
        )
        if match:
            header_index = index
            declared_size = int(match.group(1))
            break
    if header_index < 0:
        return -1, False
    if declared_size == 0:
        return 0, True

    active_rows = 0
    app_rows = 0
    for line in lines[header_index + 1 :]:
        stripped = line.strip()
        if not stripped:
            continue
        # dumpsys headings are not fully stable across Android releases, so
        # stop at any ordinary named section. Historical "Wake Lock Log" rows
        # must never be considered current lock state.
        if stripped.lower().startswith("wake lock log") or re.fullmatch(
            r"[A-Za-z][A-Za-z0-9 /()_.-]{1,100}:\s*(?:size=\d+)?",
            stripped,
        ):
            break
        upper = stripped.upper()
        if "WAKE_LOCK" not in upper:
            continue
        active_rows += 1
        if (
            "PARTIAL_WAKE_LOCK" in upper
            and ("YurichConnect:VpnKeeper" in stripped or PACKAGE in stripped)
        ):
            app_rows += 1

    if active_rows < declared_size:
        return -1, False
    return app_rows, True


def qualification_plan(
    duration_hours: int,
    profile_count: int,
) -> QualificationPlan:
    if duration_hours not in SUPPORTED_DURATION_HOURS:
        raise ValueError(
            "duration_hours must be one of "
            + ", ".join(str(value) for value in SUPPORTED_DURATION_HOURS)
        )
    if profile_count <= 0 or profile_count > 9_999:
        raise ValueError("profile_count must be between 1 and 9999")
    duration_s = duration_hours * 3_600
    matrix_duration_s = profile_count * 2 * MATRIX_SLOT_S
    endurance_s = duration_s - matrix_duration_s
    # Every profile is tested exactly once on each network. The remaining
    # duration is split across two engine dwells and one three-part handover
    # group. The final handover segment absorbs integer-second remainders so
    # arbitrary valid inventory sizes still end at exactly 24/48 hours.
    if endurance_s <= 0:
        raise ValueError("inventory does not leave time for endurance segments")
    engine_dwell_s = endurance_s // 3
    handover_total_s = endurance_s - (engine_dwell_s * 2)
    handover_base_s, handover_remainder_s = divmod(handover_total_s, 3)
    handover_segment_durations_s = tuple(
        handover_base_s
        + (1 if index >= 3 - handover_remainder_s else 0)
        for index in range(3)
    )
    if engine_dwell_s <= 0 or min(handover_segment_durations_s) <= 0:
        raise ValueError("inventory does not leave usable endurance segments")
    return QualificationPlan(
        duration_hours=duration_hours,
        duration_s=duration_s,
        profile_count=profile_count,
        matrix_duration_s=matrix_duration_s,
        engine_dwell_s=engine_dwell_s,
        handover_segment_durations_s=handover_segment_durations_s,
    )


def build_schedule(
    profiles: Sequence[Profile],
    plan: QualificationPlan | None = None,
) -> list[Slot]:
    plan = plan or qualification_plan(DEFAULT_DURATION_HOURS, len(profiles))
    if len(profiles) != plan.profile_count:
        raise ValueError("plan_profile_count_mismatch")
    singbox = next((profile for profile in profiles if profile.runtime == "singbox"), None)
    xray = next((profile for profile in profiles if profile.runtime == "xray"), None)
    if singbox is None or xray is None:
        raise ValueError("qualification requires both sing-box and Xray profiles")

    slots: list[Slot] = []
    elapsed = 0

    def add(
        phase: str,
        profile: Profile,
        network: str,
        duration_s: int,
        reconnect_at_s: int | None = None,
    ) -> None:
        nonlocal elapsed
        slots.append(
            Slot(
                index=len(slots) + 1,
                phase=phase,
                profile_token=profile.token,
                kind=profile.kind,
                engine=profile.engine,
                network=network,
                planned_start_s=elapsed,
                duration_s=duration_s,
                reconnect_at_s=reconnect_at_s,
            )
        )
        elapsed += duration_s

    for profile in profiles:
        add(
            "matrix-cellular",
            profile,
            "cellular",
            MATRIX_SLOT_S,
            MATRIX_RECONNECT_AT_S,
        )
    for profile in reversed(profiles):
        add(
            "matrix-wifi",
            profile,
            "wifi",
            MATRIX_SLOT_S,
            MATRIX_RECONNECT_AT_S,
        )

    add("dwell-singbox-cellular", singbox, "cellular", plan.engine_dwell_s)
    add("dwell-xray-wifi", xray, "wifi", plan.engine_dwell_s)
    add(
        "handover-xray-cellular-1",
        xray,
        "cellular",
        plan.handover_segment_durations_s[0],
    )
    add(
        "handover-xray-wifi",
        xray,
        "wifi",
        plan.handover_segment_durations_s[1],
    )
    add(
        "handover-xray-cellular-2",
        xray,
        "cellular",
        plan.handover_segment_durations_s[2],
    )

    if elapsed != plan.duration_s:
        raise AssertionError(f"invalid schedule duration: {elapsed}")
    return slots


def dedicated_handover_coverage(
    schedule: Sequence[Slot],
    records: Sequence[dict[str, Any]],
) -> dict[str, Any]:
    required = {
        (slot.index, slot.phase)
        for slot in schedule
        if slot.phase.startswith("handover-")
    }
    observed = {
        (safe_int(record.get("slot_index")), safe_enum(record.get("phase")))
        for record in records
        if safe_int(record.get("slot_index")) >= 0
    }
    missing = sorted(required - observed)
    return {
        "required_dedicated_slots": len(required),
        "observed_dedicated_slots": len(required & observed),
        "missing_dedicated_slot_indexes": [index for index, _ in missing],
        "pass": bool(required) and not missing,
    }


def transition_error_is_observer_only(record: Mapping[str, Any]) -> bool:
    error_code = safe_enum(record.get("error_code"), "unknown")
    return (
        error_code in TRANSITION_OBSERVER_ERROR_CODES
        or error_code.endswith("_observer_unavailable")
    )


def transition_has_confirmed_failure(summary: Mapping[str, Any]) -> bool:
    measured_attempts = safe_int(summary.get("measured_attempts"), 0)
    if measured_attempts <= 0:
        return False
    return (
        safe_int(summary.get("confirmed_failed"), 0) > 0
        or float(summary.get("p95_ms", -1))
        > float(summary.get("p95_sla_ms", math.inf))
        or float(summary.get("max_ms", -1))
        > float(summary.get("max_sla_ms", math.inf))
    )


def has_measured_resource_failure(
    main_memory: Mapping[str, Any],
    vpn_memory: Mapping[str, Any],
    optimization: Mapping[str, Any],
) -> bool:
    memory_failed = bool(main_memory.get("failed_instances")) or bool(
        vpn_memory.get("failed_instances")
    )
    cpu = optimization.get("cpu")
    cpu_failed = False
    if isinstance(cpu, Mapping):
        for role in ("main", "vpn"):
            role_cpu = cpu.get(role)
            if not isinstance(role_cpu, Mapping):
                continue
            if (
                safe_int(role_cpu.get("samples"), 0) >= 12
                and float(role_cpu.get("p95_percent", -1))
                > float(role_cpu.get("p95_limit_percent", math.inf))
            ):
                cpu_failed = True
    temperature = float(optimization.get("battery_temperature_max_c", -1))
    thermal_failed = (
        temperature >= 0
        and temperature
        > float(optimization.get("battery_temperature_limit_c", math.inf))
    )
    wakelock_coverage = float(
        optimization.get("partial_wakelock_observer_coverage_ratio", 0.0)
    )
    wakelock_ratio = float(
        optimization.get("partial_wakelock_held_ratio", -1.0)
    )
    wakelock_failed = (
        wakelock_coverage >= OBSERVER_COVERAGE_MIN
        and wakelock_ratio
        > float(optimization.get("partial_wakelock_ratio_limit", math.inf))
    )
    return memory_failed or cpu_failed or thermal_failed or wakelock_failed


def parse_exit_info(raw: str) -> list[ExitEvent]:
    events: list[ExitEvent] = []
    lines = raw.splitlines()
    for index, line in enumerate(lines):
        header = EXIT_HEADER_RE.search(line)
        if not header:
            continue
        detail_text = " ".join(lines[index + 1 : index + 4])
        detail = EXIT_DETAIL_RE.search(detail_text)
        if not detail:
            continue
        process = detail.group("process")
        if process == MAIN_PROCESS:
            role = "main"
        elif process == VPN_PROCESS:
            role = "vpn"
        else:
            continue
        pss_match = re.search(r"\bpss=([^,\s]+(?:,\d+)?\s*[KMG]?B)", detail_text)
        rss_match = re.search(r"\brss=([^,\s]+(?:,\d+)?\s*[KMG]?B)", detail_text)
        status_match = re.search(r"\bstatus=(-?\d+)", detail_text)
        timestamp = header.group("timestamp")
        identity = "|".join(
            (
                timestamp,
                role,
                detail.group("reason"),
                detail.group("subreason"),
            )
        )
        events.append(
            ExitEvent(
                event_id=hashlib.sha256(identity.encode("utf-8")).hexdigest()[:20],
                timestamp_local=timestamp,
                process_role=role,
                reason_code=int(detail.group("reason")),
                reason_name=safe_enum(
                    detail.group("reason_name").lower().replace(" ", "_")
                ),
                subreason_code=int(detail.group("subreason")),
                subreason_name=safe_enum(
                    detail.group("subreason_name").lower().replace(" ", "_")
                ),
                pss_kb=parse_memory_amount(pss_match.group(1)) if pss_match else -1,
                rss_kb=parse_memory_amount(rss_match.group(1)) if rss_match else -1,
                status=int(status_match.group(1)) if status_match else -1,
            )
        )
    return events


def exit_event_is_pre_run(event_timestamp: str, run_started_local: str) -> bool:
    normalized = event_timestamp.replace(" ", "T", 1)
    return bool(
        DEVICE_LOCAL_TIMESTAMP_RE.fullmatch(normalized)
        and DEVICE_LOCAL_TIMESTAMP_RE.fullmatch(run_started_local)
        and normalized <= run_started_local
    )


def status_query_args(request_id: str) -> tuple[str, ...]:
    if not REQUEST_RE.fullmatch(request_id):
        raise ValueError("invalid request id")
    return (
        "shell",
        "am",
        "broadcast",
        "-a",
        SOAK_QUERY_ACTION,
        "-p",
        PACKAGE,
        "--es",
        "soakCommand",
        "status",
        "--es",
        "soakRequestId",
        request_id,
    )


def control_broadcast_args(
    request_id: str,
    command: str,
    profile_token: str | None = None,
) -> tuple[str, ...]:
    if not REQUEST_RE.fullmatch(request_id):
        raise ValueError("invalid request id")
    if command not in {"inventory", "activate", "reconnect", "stop"}:
        raise ValueError("invalid command")
    if profile_token is not None and not TOKEN_RE.fullmatch(profile_token):
        raise ValueError("invalid profile token")
    arguments = [
        "shell",
        "am",
        "broadcast",
        "-a",
        SOAK_ACTION,
        "-p",
        PACKAGE,
        "--es",
        "soakCommand",
        command,
        "--es",
        "soakRequestId",
        request_id,
    ]
    if profile_token is not None:
        arguments.extend(("--es", "soakProfileToken", profile_token))
    return tuple(arguments)


def foreground_bootstrap_args() -> tuple[str, ...]:
    """Launch UI without carrying any privileged/non-idempotent QA command."""
    return (
        "shell",
        "am",
        "start",
        "-W",
        "-a",
        "android.intent.action.MAIN",
        "-c",
        "android.intent.category.LAUNCHER",
        "-n",
        SOAK_ACTIVITY,
    )


def observation_quality_gates(
    *,
    tcp_failures: int,
    https_failures: int,
    counter_stalls: int,
    counter_resets: int,
) -> dict[str, bool]:
    return {
        "tcp_failures_within_tolerance": (
            tcp_failures <= MAX_ISOLATED_PROBE_FAILURES
        ),
        "https_failures_within_tolerance": (
            https_failures <= MAX_ISOLATED_PROBE_FAILURES
        ),
        "counter_stalls_within_tolerance": (
            counter_stalls <= MAX_ISOLATED_COUNTER_STALLS
        ),
        "counter_monotonic": counter_resets == 0,
    }


def parse_passive_counter_logs(raw: str) -> list[PassiveCounterEvent]:
    pattern = re.compile(
        r"^\s*(?P<epoch>\d+\.\d+).+SOAK_QA_COUNTER\s+"
        r"token=(?P<token>p\d{4})\s+"
        r"generation=(?P<generation>\d+)\s+"
        r"native=(?P<native>\d+)\s+"
        r"display=(?P<display>\d+)\s*$",
        re.MULTILINE,
    )
    events: list[PassiveCounterEvent] = []
    for match in pattern.finditer(raw):
        identity = "|".join(
            (
                match.group("epoch"),
                match.group("token"),
                match.group("generation"),
                match.group("native"),
                match.group("display"),
            )
        )
        events.append(
            PassiveCounterEvent(
                event_id=hashlib.sha256(identity.encode("utf-8")).hexdigest()[:20],
                epoch=float(match.group("epoch")),
                token=match.group("token"),
                generation=int(match.group("generation")),
                native_bytes=int(match.group("native")),
                display_bytes=int(match.group("display")),
            )
        )
    return events


def evaluate_passive_counters(
    previous: PassiveCounterEvent | None,
    events: Sequence[PassiveCounterEvent],
    payload_probe_epochs: Sequence[float],
    *,
    establish_baseline: bool = False,
) -> CounterEvaluation:
    ordered = sorted(events, key=lambda event: event.epoch)
    if not ordered:
        return CounterEvaluation(current=None)
    if establish_baseline:
        return CounterEvaluation(current=ordered[-1])

    cursor = previous
    had_comparison = False
    generation_changed = False
    reset = False
    stalled = False
    advanced = False
    native_delta = -1
    display_delta = -1
    payload_between = False

    for event in ordered:
        if cursor is None or cursor.token != event.token:
            cursor = event
            continue

        had_comparison = True
        pair_generation_changed = event.generation != cursor.generation
        if pair_generation_changed:
            generation_changed = True
            reset = True
            native_delta = -1
            display_delta = -1
            cursor = event
            continue

        pair_native_delta = event.native_bytes - cursor.native_bytes
        pair_display_delta = event.display_bytes - cursor.display_bytes
        pair_payload_between = any(
            cursor.epoch < probe_epoch <= event.epoch
            for probe_epoch in payload_probe_epochs
        )
        pair_reset = pair_native_delta < 0 or pair_display_delta < 0
        pair_stalled = not pair_reset and (
            (pair_payload_between and pair_native_delta <= 0)
            or (pair_native_delta > 0 and pair_display_delta <= 0)
        )

        native_delta = pair_native_delta
        display_delta = pair_display_delta
        payload_between = payload_between or pair_payload_between
        reset = reset or pair_reset
        stalled = stalled or pair_stalled
        advanced = advanced or pair_display_delta > 0
        cursor = event

    return CounterEvaluation(
        current=ordered[-1],
        had_comparison=had_comparison,
        generation_changed=generation_changed,
        reset=reset,
        stalled=stalled,
        advanced=advanced,
        native_delta=native_delta,
        display_delta=display_delta,
        payload_between=payload_between,
    )


def select_preflight_xray(
    cellular_candidate: Profile | None,
    cross_network_candidate: Profile | None,
) -> tuple[Profile | None, bool]:
    if cross_network_candidate is not None:
        return cross_network_candidate, True
    return cellular_candidate, False


class SoakRunner:
    def __init__(
        self,
        adb: str,
        serial: str,
        out_dir: Path,
        require_isolation_evidence: bool = True,
        duration_hours: int = DEFAULT_DURATION_HOURS,
        expected_profile_count: int | None = None,
    ) -> None:
        if duration_hours not in SUPPORTED_DURATION_HOURS:
            raise ValueError("unsupported_duration_hours")
        if expected_profile_count is not None and not 1 <= expected_profile_count <= 9_999:
            raise ValueError("invalid_expected_profile_count")
        self.adb = str(Path(adb).expanduser().resolve())
        self.serial = serial
        self.out_dir = out_dir.resolve()
        self.require_isolation_evidence = require_isolation_evidence
        self.duration_hours = duration_hours
        self.duration_target_s = duration_hours * 3_600
        self.expected_profile_count = expected_profile_count
        self.plan: QualificationPlan | None = None

        self.stop_requested = False
        self.output_writable = False
        self.completed = False
        self.completion_reason = "not_started"
        self.started_monotonic = 0.0
        self.started_epoch = 0.0
        self.diagnostic_started_device_local = ""
        self.started_utc = ""
        self.finished_utc = ""
        self.bridge_sequence = 0
        self.incident_sequence = 0

        self.profiles: tuple[Profile, ...] = ()
        self.schedule: list[Slot] = []
        self.inventory_snapshot_count = 0
        self.inventory_snapshot_sha256 = ""
        self.inventory_snapshot_locked = False
        self.inventory_requirement_met = False
        self.inventory_drift_detected = False
        self.inventory_verification_attempts = 0
        self.inventory_verification_observed = 0
        self.inventory_final_verification_observed = False
        self.inventory_last_verification_error = "not_observed"
        self.current_slot: Slot | None = None
        self.current_profile: Profile | None = None
        self.current_profile_verified = False
        # current_network is the scheduled/expected transport. Observed
        # transport is updated only from a fresh VPN state sample.
        self.current_network = "unknown"
        self.last_observed_network = "unknown"
        self.last_network_observation_fresh = False
        self.slot_metrics: SlotMetrics | None = None
        self.profile_by_token: dict[str, Profile] = {}

        self.initial_wifi_enabled = False
        self.initial_mobile_enabled = True
        self.initial_screen_interactive = False
        self.radio_baseline_observed = False
        self.host_keep_awake_active = False

        self.baseline_exit_ids: set[str] = set()
        self.seen_exit_ids: set[str] = set()
        self.seen_runtime_log_ids: set[str] = set()
        self.isolation_evidence: dict[str, bool] = {}

        self.observation_streaks: dict[str, int] = {}
        self.active_confirmed_issues: set[str] = set()
        self.confirmed_issue_counts: dict[str, int] = {}
        self.incidents: list[dict[str, Any]] = []
        self.runner_errors: list[str] = []

        self.health_samples = 0
        self.healthy_samples = 0
        self.health_scheduled_samples = 0
        self.health_last_scheduled_elapsed = -1.0
        self.health_max_scheduled_gap_s = 0.0
        self.observer_unknown_samples = 0
        self.observer_unknown_streak_samples = 0
        self.observer_unknown_streak_started_monotonic = 0.0
        self.observer_max_unknown_streak_s = 0.0
        self.probe_samples = 0
        self.tcp_failures = 0
        self.https_failures = 0
        self.counter_samples = 0
        self.counter_observed_samples = 0
        self.counter_baseline_grace_samples = 0
        self.counter_stalls = 0
        self.counter_resets = 0
        self.counter_previous: PassiveCounterEvent | None = None
        self.counter_baseline_pending = False
        self.counter_baseline_not_before_epoch: float | None = None
        self.counter_baseline_started_monotonic = 0.0
        self.device_clock_failures = 0
        self.seen_counter_event_ids: set[str] = set()
        self.last_probe_had_traffic = False
        self.last_probe_tunnel_verified = False
        self.last_probe_tunnel_observed = False
        self.last_probe_completed_monotonic = 0.0
        self.payload_probe_epochs: list[float] = []

        self.switch_records: list[dict[str, Any]] = []
        self.handover_records: list[dict[str, Any]] = []
        self.matrix_records: list[dict[str, Any]] = []
        self.finished_slot_indexes: set[int] = set()
        self.phase_health: dict[str, dict[str, int]] = {}
        self.successful_profile_tokens: list[str] = []
        self.endurance_profiles: dict[str, str] = {}
        self.endurance_schedule_resolved = False
        self.memory_records: dict[str, list[dict[str, Any]]] = {
            "main": [],
            "vpn": [],
        }
        self.process_last_pid: dict[str, str] = {"main": "", "vpn": ""}
        self.process_instances: dict[str, dict[str, int]] = {
            "main": {},
            "vpn": {},
        }
        self.planned_vpn_process_change_active = False
        self.planned_vpn_pid_change_pending = False
        self.planned_vpn_exit_event_pending = False
        self.planned_vpn_exit_event_ambiguous_pending = False
        self.exit_transition_boundary_observer_failures = 0
        self.bridge_foreground_fallbacks = 0
        self.last_bridge_control_dispatch_monotonic = 0.0
        self.last_heartbeat_monotonic = 0.0
        self.last_exit_scan_monotonic = 0.0
        self.last_runtime_scan_monotonic = 0.0
        self.last_health_summary: dict[str, Any] = {
            "observed": False,
            "vpn_validated": False,
            "network": "unknown",
            "runtime": "unknown",
        }
        self.last_device_observed = False
        self.next_health_at = 0.0
        self.next_probe_at = 0.0
        self.next_counter_at = 3.0
        self.next_memory_at = 30.0
        self.next_exit_info_at = 0.0
        self.definitive_failures: dict[str, int] = {
            "crash": 0,
            "native_crash": 0,
            "anr": 0,
            "oom": 0,
            "excessive_resource": 0,
            "unexpected_exit": 0,
            "runtime_isolation": 0,
            "missing_engine_dwell": 0,
            "inventory_drift": 0,
        }

    def elapsed_s(self) -> int:
        if self.started_monotonic <= 0:
            return 0
        return max(0, int(time.monotonic() - self.started_monotonic))

    def qualification_elapsed_s(self) -> int:
        return min(self.elapsed_s(), self.duration_target_s)

    def expected_periodic_ticks(self, first_due_s: int, interval_s: int) -> int:
        elapsed = self.qualification_elapsed_s()
        if self.started_monotonic <= 0 or elapsed < first_due_s:
            return 0
        return ((elapsed - first_due_s) // interval_s) + 1

    def record_scheduled_health_tick(self, elapsed: float) -> None:
        if self.health_last_scheduled_elapsed >= 0:
            self.health_max_scheduled_gap_s = max(
                self.health_max_scheduled_gap_s,
                elapsed - self.health_last_scheduled_elapsed,
            )
        else:
            self.health_max_scheduled_gap_s = max(
                self.health_max_scheduled_gap_s,
                elapsed,
            )
        self.health_last_scheduled_elapsed = elapsed
        self.health_scheduled_samples += 1

    def health_cadence_summary(self) -> dict[str, Any]:
        expected = self.expected_periodic_ticks(0, HEALTH_INTERVAL_S)
        captured = min(self.health_scheduled_samples, expected)
        missed = max(0, expected - captured)
        trailing_gap = (
            max(
                0.0,
                self.qualification_elapsed_s()
                - self.health_last_scheduled_elapsed,
            )
            if self.health_last_scheduled_elapsed >= 0
            else float(self.qualification_elapsed_s())
        )
        max_gap = max(self.health_max_scheduled_gap_s, trailing_gap)
        coverage = captured / expected if expected else 0.0
        return {
            "expected_samples": expected,
            "scheduled_samples": captured,
            "missed_samples": missed,
            "scheduled_coverage_ratio": round(coverage, 6),
            "max_scheduled_gap_s": round(max_gap, 3),
            "max_scheduled_gap_limit_s": OBSERVER_MAX_UNKNOWN_STREAK_S,
            "pass": (
                expected > 0
                and coverage >= OBSERVER_COVERAGE_MIN
                and max_gap <= OBSERVER_MAX_UNKNOWN_STREAK_S
            ),
        }

    def counter_coverage_summary(self) -> dict[str, Any]:
        expected = self.expected_periodic_ticks(3, COUNTER_INTERVAL_S)
        attempted = min(self.counter_samples, expected)
        missed = max(0, expected - attempted)
        grace = min(self.counter_baseline_grace_samples, expected)
        eligible_expected = max(0, expected - grace)
        observed = min(self.counter_observed_samples, eligible_expected)
        observed_ratio = observed / eligible_expected if eligible_expected else 0.0
        attempted_ratio = attempted / expected if expected else 0.0
        return {
            "expected_ticks": expected,
            "attempted_ticks": attempted,
            "missed_ticks": missed,
            "attempted_ratio": round(attempted_ratio, 6),
            "baseline_grace_ticks": grace,
            "eligible_expected_ticks": eligible_expected,
            "observed_ticks": observed,
            "observed_ratio": round(observed_ratio, 6),
            "pass": (
                eligible_expected > 0
                and attempted_ratio >= 0.99
                and observed_ratio >= 0.99
            ),
        }

    def update_observer_streak(
        self,
        observed: bool,
        *,
        now_monotonic: float | None = None,
    ) -> None:
        now = time.monotonic() if now_monotonic is None else now_monotonic
        if observed:
            if self.observer_unknown_streak_samples:
                duration = max(
                    self.observer_unknown_streak_samples * HEALTH_INTERVAL_S,
                    now - self.observer_unknown_streak_started_monotonic,
                )
                self.observer_max_unknown_streak_s = max(
                    self.observer_max_unknown_streak_s,
                    duration,
                )
            self.observer_unknown_streak_samples = 0
            self.observer_unknown_streak_started_monotonic = 0.0
            return

        if self.observer_unknown_streak_samples == 0:
            self.observer_unknown_streak_started_monotonic = now
        self.observer_unknown_streak_samples += 1
        duration = max(
            self.observer_unknown_streak_samples * HEALTH_INTERVAL_S,
            now - self.observer_unknown_streak_started_monotonic,
        )
        self.observer_max_unknown_streak_s = max(
            self.observer_max_unknown_streak_s,
            duration,
        )

    def request_stop(self, *_: object) -> None:
        self.stop_requested = True

    def set_host_keep_awake(self, enabled: bool) -> bool:
        if os.name != "nt":
            self.host_keep_awake_active = enabled
            return True
        flags = 0x80000000 | (0x00000001 if enabled else 0)
        result = ctypes.windll.kernel32.SetThreadExecutionState(flags)
        if result == 0:
            return False
        self.host_keep_awake_active = enabled
        return True

    def atomic_json(self, name: str, payload: object) -> None:
        target = self.out_dir / name
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_suffix(target.suffix + ".tmp")
        temporary.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True),
            encoding="utf-8",
        )
        for attempt in range(5):
            try:
                os.replace(temporary, target)
                break
            except PermissionError:
                if attempt >= 4:
                    raise
                time.sleep(0.05 * (2**attempt))

    def append_jsonl(self, name: str, payload: Mapping[str, Any]) -> None:
        target = self.out_dir / name
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("a", encoding="utf-8") as handle:
            handle.write(
                json.dumps(dict(payload), ensure_ascii=False, sort_keys=True) + "\n"
            )

    def append_csv(self, name: str, row: Mapping[str, Any]) -> None:
        fields = CSV_SCHEMAS[name]
        target = self.out_dir / name
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("a", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
            if handle.tell() == 0:
                writer.writeheader()
            writer.writerow({field: row.get(field, "") for field in fields})

    def event(self, event_type: str, **fields: Any) -> None:
        if not self.output_writable:
            return
        payload: dict[str, Any] = {
            "timestamp_utc": utc_now(),
            "elapsed_s": self.elapsed_s(),
            "event": safe_enum(event_type),
        }
        for key, value in fields.items():
            if not ENUM_RE.fullmatch(key):
                continue
            if isinstance(value, bool | int | float) or value is None:
                payload[key] = value
            elif isinstance(value, str):
                if TOKEN_RE.fullmatch(value) or ENUM_RE.fullmatch(value):
                    payload[key] = value
                else:
                    payload[key] = "redacted"
        self.append_jsonl("events.jsonl", payload)

    def run_host(
        self,
        command: Sequence[str],
        timeout: int,
    ) -> tuple[subprocess.CompletedProcess[str] | None, str]:
        try:
            result = subprocess.run(
                list(command),
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout,
                check=False,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
        except subprocess.TimeoutExpired:
            return None, "timeout"
        except OSError:
            return None, "host_command_error"
        stderr = result.stderr.lower()
        adb_transport_error = (
            "error: device offline" in stderr
            or re.search(r"error:\s+device\s+.+\s+not found", stderr) is not None
            or "no devices/emulators found" in stderr
            or "protocol fault" in stderr
            or "cannot connect to daemon" in stderr
            or "failed to get feature set" in stderr
        )
        if adb_transport_error:
            return result, "observer_unavailable"
        if result.returncode != 0:
            return result, "nonzero"
        return result, ""

    def adb_run(
        self,
        *args: str,
        timeout: int = 30,
    ) -> tuple[subprocess.CompletedProcess[str] | None, str]:
        return self.run_host((self.adb, "-s", self.serial, *args), timeout)

    def shell(
        self,
        *args: str,
        timeout: int = 30,
    ) -> tuple[subprocess.CompletedProcess[str] | None, str]:
        return self.adb_run("shell", *args, timeout=timeout)

    def device_available(self) -> bool:
        result, error = self.adb_run("get-state", timeout=10)
        return (
            error == ""
            and result is not None
            and result.stdout.strip().lower() == "device"
        )

    def detect_wifi_enabled(self) -> bool | None:
        result, error = self.shell("cmd", "wifi", "status", timeout=15)
        if error or result is None:
            return None
        text = result.stdout.lower()
        if "wifi is enabled" in text:
            return True
        if "wifi is disabled" in text:
            return False
        return None

    def detect_mobile_enabled(self) -> bool | None:
        result, error = self.shell(
            "settings", "get", "global", "mobile_data", timeout=15
        )
        if error or result is None:
            return None
        value = result.stdout.strip()
        if value == "1":
            return True
        if value == "0":
            return False
        return None

    def wifi_connected(self) -> bool | None:
        result, error = self.shell("cmd", "wifi", "status", timeout=20)
        if error or result is None:
            return None
        text = result.stdout.lower()
        if "wifi is connected" in text:
            return True
        if "wifi is disabled" in text or "wifi is enabled" in text:
            return False
        return None

    def screen_interactive(self) -> bool | None:
        result, error = self.shell("dumpsys", "power", timeout=30)
        if error or result is None:
            return None
        match = re.search(r"\bmWakefulness=(\w+)", result.stdout)
        if match:
            return match.group(1).lower() == "awake"
        match = re.search(r"\bmInteractive=(true|false)", result.stdout)
        return match.group(1) == "true" if match else None

    def set_radios(self, network: str) -> bool:
        if network not in {"cellular", "wifi"}:
            return False
        data, data_error = self.shell("svc", "data", "enable", timeout=20)
        wifi, wifi_error = self.shell(
            "svc",
            "wifi",
            "enable" if network == "wifi" else "disable",
            timeout=20,
        )
        ok = (
            data is not None
            and wifi is not None
            and data_error == ""
            and wifi_error == ""
        )
        self.event("radio_plan_applied", network=network, ok=ok)
        return ok

    def restore_device_state(self) -> None:
        if not self.radio_baseline_observed:
            return
        _, data_error = self.shell(
            "svc",
            "data",
            "enable" if self.initial_mobile_enabled else "disable",
            timeout=20,
        )
        _, wifi_error = self.shell(
            "svc",
            "wifi",
            "enable" if self.initial_wifi_enabled else "disable",
            timeout=20,
        )
        interactive = self.screen_interactive()
        if interactive is not None and interactive != self.initial_screen_interactive:
            self.shell(
                "input",
                "keyevent",
                "KEYCODE_WAKEUP"
                if self.initial_screen_interactive
                else "KEYCODE_SLEEP",
                timeout=10,
            )
        verified = False
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            wifi = self.detect_wifi_enabled()
            mobile = self.detect_mobile_enabled()
            if (
                wifi == self.initial_wifi_enabled
                and mobile == self.initial_mobile_enabled
            ):
                verified = True
                break
            time.sleep(1)
        if data_error or wifi_error or not verified:
            self.runner_errors.append("device_state_restore_unverified")
        self.event(
            "device_state_restored",
            wifi=self.initial_wifi_enabled,
            mobile=self.initial_mobile_enabled,
            verified=verified,
        )

    def read_property(self, name: str) -> str:
        result, error = self.shell("getprop", name, timeout=15)
        if error or result is None:
            return "unknown"
        value = result.stdout.strip().replace(" ", "_")
        return (
            value
            if re.fullmatch(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$", value)
            else "unknown"
        )

    def device_local_timestamp(self) -> str:
        result, error = self.shell(
            "date",
            "+%Y-%m-%dT%H:%M:%S.%3N",
            timeout=15,
        )
        if error or result is None:
            return ""
        value = result.stdout.strip()
        return value if DEVICE_LOCAL_TIMESTAMP_RE.fullmatch(value) else ""

    def bridge_request(
        self,
        command: str,
        profile_token: str | None = None,
        timeout_s: int = BRIDGE_TIMEOUT_S,
    ) -> tuple[dict[str, Any] | None, str]:
        self.last_bridge_control_dispatch_monotonic = 0.0
        if command not in {"inventory", "activate", "reconnect", "stop"}:
            return None, "invalid_command"
        if profile_token is not None and not TOKEN_RE.fullmatch(profile_token):
            return None, "invalid_profile_token"
        main_pid, pid_observed = self.pidof(MAIN_PROCESS)
        background_ready = False
        readiness_error = "main_process_absent"
        if pid_observed and main_pid:
            _, readiness_error = self.query_status(timeout_s=3)
            background_ready = readiness_error == ""

        if background_ready:
            request_id = self.next_request_id()
            self.last_bridge_control_dispatch_monotonic = time.monotonic()
            _, launch_error = self.adb_run(
                *control_broadcast_args(request_id, command, profile_token),
                timeout=20,
            )
            if launch_error:
                # Once a non-idempotent control broadcast has been attempted,
                # transport timeout/disconnect is ambiguous: Android may have
                # delivered it before the host lost the response. Never issue a
                # second foreground command with a new request id.
                self.observe_issue(
                    BRIDGE_CONTROL_OBSERVER_ISSUE,
                    bad=True,
                    observed=True,
                    severity="observer",
                )
                return None, (
                    "observer_unavailable"
                    if launch_error == "observer_unavailable"
                    else "broadcast_launch_failed"
                )
            payload, result_error = self.poll_bridge_result(
                request_id,
                command,
                timeout_s,
            )
            if result_error == "":
                self.observe_issue(
                    BRIDGE_CONTROL_OBSERVER_ISSUE,
                    bad=False,
                    observed=True,
                    severity="observer",
                )
            elif result_error:
                # The receiver accepted the broadcast, so a missing result or a
                # later UI-process change cannot prove that the command did not
                # already mutate VPN state. Preserve exactly-once dispatch.
                self.observe_issue(
                    BRIDGE_CONTROL_OBSERVER_ISSUE,
                    bad=True,
                    observed=True,
                    severity="observer",
                )
            return payload, result_error
        elif not pid_observed:
            readiness_error = "observer_unavailable"

        # Foreground bootstrap is a last resort only when no control command
        # was accepted by a live, receiver-ready UI process.
        self.bridge_foreground_fallbacks += 1
        self.event(
            "bridge_foreground_fallback",
            command=command,
            reason=safe_enum(readiness_error, "background_bridge_unavailable"),
        )
        self.observe_issue(
            BRIDGE_CONTROL_OBSERVER_ISSUE,
            bad=True,
            observed=True,
            severity="observer",
        )
        _, launch_error = self.adb_run(*foreground_bootstrap_args(), timeout=20)
        if launch_error:
            return None, (
                "observer_unavailable"
                if launch_error == "observer_unavailable"
                else "bridge_launch_failed"
            )
        bootstrap_deadline = time.monotonic() + min(30, max(5, timeout_s))
        bootstrap_error = "status_query_failed"
        while time.monotonic() < bootstrap_deadline and not self.stop_requested:
            _, bootstrap_error = self.query_status(timeout_s=3)
            if bootstrap_error == "":
                break
            if bootstrap_error == "observer_unavailable":
                return None, bootstrap_error
            time.sleep(0.5)
        if bootstrap_error:
            return None, "status_query_failed"

        # The privileged receiver is now proven ready. Dispatch the control
        # command exactly once; any subsequent transport error is ambiguous and
        # must not fall back to a second activity intent.
        request_id = self.next_request_id()
        self.last_bridge_control_dispatch_monotonic = time.monotonic()
        _, dispatch_error = self.adb_run(
            *control_broadcast_args(request_id, command, profile_token),
            timeout=20,
        )
        if dispatch_error:
            return None, (
                "observer_unavailable"
                if dispatch_error == "observer_unavailable"
                else "broadcast_launch_failed"
            )
        return self.poll_bridge_result(request_id, command, timeout_s)

    def next_request_id(self) -> str:
        self.bridge_sequence += 1
        request_id = (
            f"q{os.getpid()}_{int(time.time())}_{self.bridge_sequence}"
        )[-63:]
        if not REQUEST_RE.fullmatch(request_id):
            raise RuntimeError("invalid_request_id")
        return request_id

    def poll_bridge_result(
        self,
        request_id: str,
        command: str,
        timeout_s: int,
    ) -> tuple[dict[str, Any] | None, str]:
        deadline = time.monotonic() + timeout_s
        pattern = re.compile(
            rf"SOAK_QA_RESULT request={re.escape(request_id)}\s+(\{{.*\}})"
        )
        while time.monotonic() < deadline and not self.stop_requested:
            self.write_heartbeat()
            main_pid, pid_observed = self.pidof(MAIN_PROCESS)
            if not pid_observed:
                return None, "observer_unavailable"
            if not main_pid:
                return None, "main_process_absent"
            logcat, error = self.adb_run(
                "logcat",
                "-b",
                "main",
                "-d",
                "-v",
                "raw",
                "--pid",
                main_pid,
                "-s",
                f"{SOAK_TAG}:V",
                "*:S",
                timeout=20,
            )
            if error == "observer_unavailable":
                return None, "observer_unavailable"
            if not error and logcat is not None:
                matches = pattern.findall(logcat.stdout)
                if matches:
                    try:
                        parsed = json.loads(matches[-1])
                    except json.JSONDecodeError:
                        return None, "invalid_bridge_json"
                    return self.validate_bridge_payload(command, parsed)
            time.sleep(0.5)
        return None, "bridge_timeout"

    def query_status(
        self,
        timeout_s: int = 5,
    ) -> tuple[dict[str, Any] | None, str]:
        main_pid, pid_observed = self.pidof(MAIN_PROCESS)
        if not pid_observed:
            return None, "observer_unavailable"
        if not main_pid:
            return None, "main_process_absent"
        request_id = self.next_request_id()
        _, launch_error = self.adb_run(
            *status_query_args(request_id),
            timeout=20,
        )
        if launch_error:
            return None, (
                "observer_unavailable"
                if launch_error == "observer_unavailable"
                else "status_query_failed"
            )
        payload, error = self.poll_bridge_result(request_id, "status", timeout_s)
        post_pid, post_observed = self.pidof(MAIN_PROCESS)
        if not post_observed:
            return None, "observer_unavailable"
        if post_pid != main_pid:
            return None, "main_process_changed_during_status_query"
        return payload, error

    def validate_bridge_payload(
        self,
        command: str,
        raw: Any,
    ) -> tuple[dict[str, Any] | None, str]:
        if not isinstance(raw, dict) or not isinstance(raw.get("ok"), bool):
            return None, "invalid_bridge_payload"
        payload: dict[str, Any] = {"ok": raw["ok"]}
        if "error" in raw:
            payload["error"] = safe_enum(raw["error"], "bridge_error")
        if command == "inventory":
            profiles_raw = raw.get("profiles")
            if not isinstance(profiles_raw, list):
                return None, "invalid_inventory"
            profiles: list[dict[str, Any]] = []
            for item in profiles_raw:
                if not isinstance(item, dict):
                    return None, "invalid_inventory"
                token = str(item.get("profileToken") or "")
                kind = safe_enum(item.get("kind"))
                engine = safe_enum(item.get("engine"))
                runnable = item.get("runnable")
                if (
                    not TOKEN_RE.fullmatch(token)
                    or kind == "unknown"
                    or engine == "unknown"
                    or not isinstance(runnable, bool)
                ):
                    return None, "invalid_inventory"
                profiles.append(
                    {
                        "profileToken": token,
                        "kind": kind,
                        "engine": engine,
                        "runnable": runnable,
                    }
                )
            payload["profiles"] = profiles
            payload["count"] = safe_int(raw.get("count"))
            return payload, ""

        token = raw.get("selectedProfileToken") or raw.get("profileToken")
        if token is not None and not TOKEN_RE.fullmatch(str(token)):
            return None, "invalid_status_token"
        payload.update(
            {
                "profileToken": str(token) if token else "",
                "vpnStatus": safe_enum(raw.get("vpnStatus")),
                "connectionState": safe_enum(raw.get("connectionState")),
                "busy": bool(raw.get("busy", False)),
                "queueActive": bool(raw.get("queueActive", False)),
                "kind": safe_enum(raw.get("kind")),
                "engine": safe_enum(raw.get("engine")),
                "networkType": safe_enum(raw.get("networkType")),
                "trafficBytes": safe_int(raw.get("trafficBytes")),
                "uplink": safe_int(raw.get("uplink")),
                "downlink": safe_int(raw.get("downlink")),
                "sessionTotal": safe_int(raw.get("sessionTotal")),
            }
        )
        return payload, ""

    def load_inventory(self) -> None:
        payload, error = self.bridge_request("inventory")
        if error or payload is None or not payload.get("ok"):
            raise RuntimeError("inventory_unavailable")
        if self.inventory_snapshot_locked:
            raise RuntimeError("inventory_snapshot_already_locked")

        profiles = validated_inventory_profiles(payload)
        self.profiles = profiles
        self.inventory_snapshot_count = len(profiles)
        self.inventory_snapshot_sha256 = inventory_snapshot_sha256(profiles)
        self.inventory_snapshot_locked = True
        self.inventory_requirement_met = (
            self.expected_profile_count is None
            or self.inventory_snapshot_count == self.expected_profile_count
        )
        try:
            self.plan = qualification_plan(
                self.duration_hours,
                self.inventory_snapshot_count,
            )
        except ValueError as error:
            raise RuntimeError("inventory_schedule_unsupported") from error

        self.atomic_json(
            "inventory-snapshot.json",
            {
                "schema_version": 1,
                "locked_utc": utc_now(),
                "mode": (
                    "strict_expected"
                    if self.expected_profile_count is not None
                    else "observed_snapshot"
                ),
                "requested_expected_count": self.expected_profile_count,
                "observed_count": self.inventory_snapshot_count,
                "runnable_count": self.inventory_snapshot_count,
                "count_requirement_met": self.inventory_requirement_met,
                "snapshot_sha256": self.inventory_snapshot_sha256,
                "profiles_persisted": False,
            },
        )
        if not self.inventory_requirement_met:
            raise RuntimeError("unexpected_profile_count")

        self.profile_by_token = {profile.token: profile for profile in self.profiles}
        try:
            self.schedule = build_schedule(self.profiles, self.plan)
        except (AssertionError, ValueError) as error:
            raise RuntimeError("inventory_schedule_invalid") from error

    def observe_initial_profile(self) -> None:
        payload, error = self.query_status(timeout_s=5)
        if error or payload is None:
            return
        vpn_pid, pid_observed = self.pidof(VPN_PROCESS)
        token = str(payload.get("profileToken") or "")
        profile = self.profile_by_token.get(token)
        if not pid_observed or not vpn_pid or profile is None:
            return
        self.current_profile = profile
        self.event(
            "initial_profile_observed",
            profile=profile.token,
            engine=profile.engine,
        )

    def verify_inventory_snapshot(self, context: str) -> bool | None:
        self.inventory_verification_attempts += 1
        payload, error = self.bridge_request("inventory")
        if error or payload is None or not payload.get("ok"):
            self.inventory_last_verification_error = safe_enum(
                error or "inventory_unavailable",
            )
            self.event(
                "inventory_verification_unavailable",
                context=safe_enum(context),
                error=self.inventory_last_verification_error,
            )
            return None
        try:
            profiles = validated_inventory_profiles(payload)
        except RuntimeError as validation_error:
            self.inventory_last_verification_error = safe_enum(
                str(validation_error),
                "invalid_inventory",
            )
            self.event(
                "inventory_verification_unavailable",
                context=safe_enum(context),
                error=self.inventory_last_verification_error,
            )
            return None

        self.inventory_verification_observed += 1
        if context == "terminal":
            self.inventory_final_verification_observed = True
        observed_sha256 = inventory_snapshot_sha256(profiles)
        matches = (
            self.inventory_snapshot_locked
            and len(profiles) == self.inventory_snapshot_count
            and observed_sha256 == self.inventory_snapshot_sha256
        )
        self.inventory_last_verification_error = "" if matches else "inventory_drift"
        self.event(
            "inventory_verification",
            context=safe_enum(context),
            observed=True,
            matches=matches,
            observed_count=len(profiles),
        )
        if matches or self.inventory_drift_detected:
            return matches

        self.inventory_drift_detected = True
        self.definitive_failures["inventory_drift"] += 1
        self.capture_incident(
            issue="inventory_drift",
            severity="app",
            confirmation="successful_inventory_observation",
            extra={
                "context": safe_enum(context),
                "expected_count": self.inventory_snapshot_count,
                "observed_count": len(profiles),
                "hash_match": False,
            },
        )
        return False

    def pidof(self, process: str) -> tuple[str, bool]:
        result, error = self.shell("pidof", "-s", process, timeout=15)
        if result is None or error not in {"", "nonzero"}:
            return "", False
        pid = result.stdout.strip()
        if not error and result.returncode == 0 and re.fullmatch(r"[1-9][0-9]*", pid):
            return pid, True
        # Only pidof's clean no-match result proves absence. ADB failures do not.
        if error == "nonzero" and result.returncode == 1 and not pid and not result.stderr.strip():
            return "", True
        return "", False

    def vpn_state(self) -> VpnState:
        result, error = self.shell("dumpsys", "connectivity", timeout=45)
        if error or result is None:
            return VpnState()
        return parse_vpn_state(result.stdout)

    def tcp_probe(self) -> ProbeResult:
        result, error = self.shell(
            "nc", "-z", "-w", "5", "1.1.1.1", "443", timeout=12
        )
        if error == "observer_unavailable" or result is None:
            return ProbeResult(False, False)
        return ProbeResult(True, result.returncode == 0)

    def https_probe(self) -> ProbeResult:
        self.last_https_attempts = []
        observed = False
        for index, endpoint in enumerate(("payload", "fallback")):
            attempt = measure_https(self, endpoint)
            self.last_https_attempts.append(asdict(attempt))
            self.event(
                "https_attempt", endpoint=endpoint, observed=attempt.observed,
                ok=attempt.ok, exit_code=attempt.exit_code, http_code=attempt.http_code,
                size_download=attempt.size_download, failure=attempt.failure,
                **attempt.timings_ms,
            )
            if not attempt.observed:
                continue
            observed = True
            if attempt.ok:
                return ProbeResult(
                    True,
                    True,
                    traffic_generated=index == 0,
                )
        return ProbeResult(observed, False)

    def wait_ready(
        self,
        profile: Profile,
        network: str,
        timeout_s: int,
    ) -> WaitReadyResult:
        deadline = time.monotonic() + timeout_s
        last_observed = VpnState()
        observed_samples = 0
        unobserved_samples = 0
        while time.monotonic() < deadline and not self.stop_requested:
            state = self.vpn_state()
            self.last_network_observation_fresh = state.observed
            if state.observed:
                observed_samples += 1
                last_observed = state
                self.last_observed_network = state.network
            else:
                unobserved_samples += 1
            if (
                state.observed
                and state.validated
                and state.network == network
                and state.runtime == profile.runtime
            ):
                return WaitReadyResult(
                    True,
                    state,
                    observed_samples,
                    unobserved_samples,
                )
            self.write_heartbeat()
            time.sleep(0.5)
        return WaitReadyResult(
            False,
            last_observed,
            observed_samples,
            unobserved_samples,
        )

    def write_probe(
        self,
        source: str,
        tcp: ProbeResult,
        https: ProbeResult,
        state: VpnState,
        *,
        tunnel_verified: bool = False,
    ) -> None:
        profile = self.current_profile
        self.append_csv(
            "probes.csv",
            {
                "timestamp_utc": utc_now(),
                "elapsed_s": self.elapsed_s(),
                "source": source,
                "profile_token": profile.token if profile else "",
                "engine": profile.engine if profile else "unknown",
                "network": self.current_network,
                "expected_network": self.current_network,
                "observed_network": state.network,
                "network_verified": (
                    state.observed
                    and state.validated
                    and state.network == self.current_network
                ),
                "tcp_observed": tcp.observed,
                "tcp_ok": tcp.ok if tcp.observed else "",
                "https_observed": https.observed,
                "https_ok": https.ok if https.observed else "",
                "https_payload_generated": https.traffic_generated,
                "tunnel_verified": tunnel_verified,
                "tcp_tunnel_ok": tunnel_verified and tcp.observed and tcp.ok,
                "https_tunnel_ok": tunnel_verified and https.observed and https.ok,
            },
        )

    def probe_tick(self, source: str = "scheduled") -> tuple[ProbeResult, ProbeResult]:
        state = self.vpn_state()
        self.last_network_observation_fresh = state.observed
        if state.observed:
            self.last_observed_network = state.network
        tcp = self.tcp_probe()
        https = self.https_probe()
        post_state = self.vpn_state()
        profile = self.current_profile
        # Shell probes can succeed directly after the VPN disappears. Only a
        # validated target runtime on both sides can qualify their traffic.
        tunnel_verified = profile is not None and all(
            candidate.observed
            and candidate.validated
            and candidate.network == self.current_network
            and candidate.runtime == profile.runtime
            for candidate in (state, post_state)
        )
        self.last_probe_tunnel_verified = tunnel_verified
        self.last_probe_tunnel_observed = state.observed and post_state.observed
        self.probe_samples += 1
        if tcp.observed and not tcp.ok:
            self.tcp_failures += 1
        if https.observed and not https.ok:
            self.https_failures += 1
        self.write_probe(source, tcp, https, state, tunnel_verified=tunnel_verified)
        if source == "scheduled":
            self.observe_issue(
                "tcp_probe_failed",
                bad=tcp.observed and not tcp.ok,
                observed=tcp.observed,
                severity="app",
            )
            self.observe_issue(
                "https_probe_failed",
                bad=https.observed and not https.ok,
                observed=https.observed,
                severity="app",
            )
        self.last_probe_had_traffic = (
            tunnel_verified and https.observed and https.ok and https.traffic_generated
        )
        if self.last_probe_had_traffic:
            device_epoch = self.read_device_epoch()
            if device_epoch is not None:
                self.payload_probe_epochs.append(device_epoch)
        self.last_probe_completed_monotonic = time.monotonic()
        if self.slot_metrics is not None and self.last_probe_had_traffic:
            self.slot_metrics.payload_probe_success = True
        return tcp, https

    def instantaneous_cpu(self, pids: Sequence[str]) -> dict[str, float]:
        usable = [pid for pid in pids if pid.isdigit()]
        if not usable:
            return {}
        result, error = self.shell(
            "top",
            "-b",
            "-n",
            "1",
            "-p",
            ",".join(usable),
            timeout=15,
        )
        if error or result is None:
            return {}
        values: dict[str, float] = {}
        for pid in usable:
            match = re.search(
                rf"^\s*{re.escape(pid)}\s+\S+\s+\d+\s+-?\d+\s+"
                rf"\S+\s+\S+\s+\S+\s+\S\s+([\d.]+)\s+",
                result.stdout,
                re.MULTILINE,
            )
            if match:
                values[pid] = float(match.group(1))
        return values

    def process_memory(
        self,
        process: str,
        *,
        pid_override: str | None = None,
        cpu_percent_override: float | None = None,
    ) -> tuple[ProcessMemory, str]:
        if pid_override is None:
            pid, observed = self.pidof(process)
        else:
            pid, observed = pid_override, True
        if not observed:
            return ProcessMemory(), ""
        if not pid:
            return ProcessMemory(), ""
        meminfo, mem_error = self.shell("dumpsys", "meminfo", pid, timeout=45)
        status, status_error = self.shell("cat", f"/proc/{pid}/status", timeout=20)
        fd_result, fd_error = self.shell("ls", "-1", f"/proc/{pid}/fd", timeout=20)
        if mem_error == "observer_unavailable":
            return ProcessMemory(), pid
        mem_text = meminfo.stdout if meminfo is not None else ""

        def total(label: str) -> int:
            match = re.search(
                rf"^\s*{re.escape(label)}:\s*(\d+)",
                mem_text,
                re.MULTILINE | re.IGNORECASE,
            )
            return int(match.group(1)) if match else -1

        total_row = re.search(
            r"^\s*TOTAL\s+(\d+)\s+\d+\s+\d+\s+(\d+)\s+(\d+)",
            mem_text,
            re.MULTILINE,
        )

        def category(label: str) -> int:
            match = re.search(
                rf"^\s*{re.escape(label)}\s+(\d+)",
                mem_text,
                re.MULTILINE,
            )
            return int(match.group(1)) if match else -1

        pss = total("TOTAL PSS")
        rss = total("TOTAL RSS")
        swap = total("TOTAL SWAP PSS")
        if total_row:
            if pss < 0:
                pss = int(total_row.group(1))
            if swap < 0:
                swap = int(total_row.group(2))
            if rss < 0:
                rss = int(total_row.group(3))

        status_text = status.stdout if status is not None and not status_error else ""
        rss_match = re.search(r"^VmRSS:\s*(\d+)\s*kB", status_text, re.MULTILINE)
        threads_match = re.search(r"^Threads:\s*(\d+)", status_text, re.MULTILINE)
        if rss < 0 and rss_match:
            rss = int(rss_match.group(1))
        fd_entries = fd_result.stdout.splitlines() if fd_result is not None else []
        fd_count = (
            len(fd_entries)
            if not fd_error and fd_entries and all(entry.isdigit() for entry in fd_entries)
            else -1
        )
        cpu_percent = (
            cpu_percent_override
            if cpu_percent_override is not None
            else self.instantaneous_cpu((pid,)).get(pid, -1.0)
        )
        return (
            ProcessMemory(
                present=True,
                pss_kb=pss,
                rss_kb=rss,
                swap_pss_kb=swap,
                native_heap_pss_kb=category("Native Heap"),
                java_heap_pss_kb=max(
                    category("Dalvik Heap"),
                    category("Java Heap"),
                ),
                graphics_pss_kb=category("Graphics"),
                fd_count=fd_count,
                thread_count=int(threads_match.group(1)) if threads_match else -1,
                cpu_percent=cpu_percent,
            ),
            pid,
        )

    def battery_and_power(self) -> dict[str, Any]:
        battery, battery_error = self.shell("dumpsys", "battery", timeout=30)
        power, power_error = self.shell("dumpsys", "power", timeout=30)
        battery_text = (
            battery.stdout if battery is not None and not battery_error else ""
        )
        power_text = power.stdout if power is not None and not power_error else ""

        def number(label: str) -> int:
            match = re.search(
                rf"^\s*{re.escape(label)}:\s*(-?\d+)",
                battery_text,
                re.MULTILINE,
            )
            return int(match.group(1)) if match else -1

        active_wakelocks, wakelocks_observed = parse_active_partial_wakelocks(
            power_text
        )
        interactive = self.screen_interactive()
        return {
            "battery_level": number("level"),
            "battery_temp_c": (
                number("temperature") / 10.0 if number("temperature") >= 0 else -1.0
            ),
            "battery_status": number("status"),
            "app_partial_wakelocks": active_wakelocks,
            "app_partial_wakelocks_observed": wakelocks_observed,
            "screen_interactive": (
                interactive if interactive is not None else "unknown"
            ),
        }

    def process_instance(self, role: str, pid: str) -> int:
        if not pid:
            return -1
        start_ticks = self.process_start_ticks(pid)
        identity = f"{pid}:{start_ticks}" if start_ticks >= 0 else f"{pid}:unknown"
        instances = self.process_instances[role]
        if identity not in instances:
            instances[identity] = len(instances) + 1
        return instances[identity]

    def process_start_ticks(self, pid: str) -> int:
        if not pid.isdigit():
            return -1
        result, error = self.shell("cat", f"/proc/{pid}/stat", timeout=15)
        if error or result is None:
            return -1
        _, separator, tail = result.stdout.strip().rpartition(")")
        if not separator:
            return -1
        fields = tail.strip().split()
        return safe_int(fields[19]) if len(fields) > 19 else -1

    def memory_tick(self) -> None:
        power = self.battery_and_power()
        process_specs = (("main", MAIN_PROCESS), ("vpn", VPN_PROCESS))
        pids = {
            role: self.pidof(process)[0] for role, process in process_specs
        }
        cpu = self.instantaneous_cpu(tuple(pids.values()))
        for role, process in process_specs:
            pid = pids[role]
            memory, pid = self.process_memory(
                process,
                pid_override=pid,
                cpu_percent_override=cpu.get(pid),
            )
            row = {
                "timestamp_utc": utc_now(),
                "elapsed_s": self.elapsed_s(),
                "phase": self.current_slot.phase if self.current_slot else "preflight",
                "profile_token": (
                    self.current_profile.token if self.current_profile else ""
                ),
                "engine": (
                    self.current_profile.engine if self.current_profile else "unknown"
                ),
                "network": self.current_network,
                "expected_network": self.current_network,
                "observed_network": self.last_observed_network,
                "network_verified": (
                    self.last_network_observation_fresh
                    and self.last_observed_network == self.current_network
                    and self.last_observed_network in {"cellular", "wifi"}
                ),
                "process_role": role,
                "process_present": memory.present,
                "process_instance": self.process_instance(role, pid),
                **asdict(memory),
                **power,
            }
            self.append_csv("memory.csv", row)
            self.memory_records[role].append(row)

    def read_device_epoch(self) -> float | None:
        # logcat epoch timestamps use the phone clock, not the host clock.
        host_before = time.time()
        result, error = self.shell("date", "-u", "+%s.%N", timeout=10)
        host_after = time.time()
        raw = result.stdout.strip() if result is not None and not error else ""
        valid = re.fullmatch(r"[0-9]{1,12}\.[0-9]{1,9}", raw) is not None
        if not valid:
            self.device_clock_failures += 1
        self.observe_issue(
            "device_clock_unavailable",
            bad=not valid,
            observed=True,
            severity="observer",
        )
        epoch = float(raw) if valid else None
        self.event(
            "device_clock_sample",
            device_epoch=epoch,
            host_before_epoch=host_before,
            host_after_epoch=host_after,
            observed=valid,
        )
        return epoch

    def read_passive_counter_events(
        self,
        *,
        timeout_s: int = 20,
    ) -> tuple[list[PassiveCounterEvent] | None, str]:
        main_pid, pid_observed = self.pidof(MAIN_PROCESS)
        if not pid_observed:
            return None, "observer_unavailable"
        if not main_pid:
            return None, "main_process_absent"
        result, error = self.adb_run(
            "logcat",
            "-b",
            "main",
            "-d",
            "-v",
            "epoch",
            "--pid",
            main_pid,
            "-s",
            f"{SOAK_TAG}:I",
            "*:S",
            timeout=timeout_s,
        )
        if error or result is None:
            return None, (
                "observer_unavailable"
                if error == "observer_unavailable"
                else "counter_log_unavailable"
            )
        return parse_passive_counter_logs(result.stdout), ""

    def baseline_passive_counters(self) -> None:
        events: list[PassiveCounterEvent] | None = None
        error = "counter_log_unavailable"
        for attempt in range(2):
            events, error = self.read_passive_counter_events(timeout_s=45)
            if not error and events is not None:
                break
            if attempt == 0:
                time.sleep(1)
        if error or events is None:
            raise RuntimeError("counter_log_baseline_unavailable")
        self.seen_counter_event_ids.update(event.event_id for event in events)
        self.counter_previous = None
        self.counter_baseline_pending = False
        self.counter_baseline_not_before_epoch = None
        self.counter_baseline_started_monotonic = 0.0

    def begin_post_transition_counter_baseline(self) -> None:
        self.counter_previous = None
        self.counter_baseline_pending = True
        self.counter_baseline_started_monotonic = time.monotonic()
        self.counter_baseline_not_before_epoch = self.read_device_epoch()

    def counter_tick(self, *, device_observed: bool | None = None) -> None:
        profile = self.current_profile
        token = profile.token if profile else ""
        if device_observed is False:
            state = VpnState()
            events, error = None, "observer_unavailable"
        else:
            state = self.vpn_state()
            if self.counter_baseline_pending and self.counter_baseline_not_before_epoch is None:
                self.counter_baseline_not_before_epoch = self.read_device_epoch()
            events, error = self.read_passive_counter_events()
        self.last_network_observation_fresh = state.observed
        if state.observed:
            self.last_observed_network = state.network
        candidates: list[PassiveCounterEvent] = []
        if events is not None:
            for event in events:
                if event.event_id in self.seen_counter_event_ids:
                    continue
                self.seen_counter_event_ids.add(event.event_id)
                if event.token == token:
                    candidates.append(event)
        evaluation_candidates = candidates
        if self.counter_baseline_pending:
            evaluation_candidates = [
                event
                for event in candidates
                if self.counter_baseline_not_before_epoch is not None
                and event.epoch >= self.counter_baseline_not_before_epoch
            ]
        evaluation = evaluate_passive_counters(
            self.counter_previous,
            evaluation_candidates,
            self.payload_probe_epochs,
            establish_baseline=self.counter_baseline_pending,
        )
        current = evaluation.current
        baseline_was_pending = self.counter_baseline_pending
        baseline_age_s = (
            max(0.0, time.monotonic() - self.counter_baseline_started_monotonic)
            if baseline_was_pending
            else 0.0
        )
        baseline_grace = (
            baseline_was_pending
            and current is None
            and baseline_age_s <= COUNTER_BASELINE_GRACE_S
        )
        observed = current is not None and profile is not None
        traffic = current.display_bytes if current is not None else -1
        advanced: bool | str = (
            evaluation.advanced if evaluation.had_comparison else ""
        )
        if current is not None:
            self.counter_previous = current
            self.counter_baseline_pending = False
            self.counter_baseline_not_before_epoch = None
            self.counter_baseline_started_monotonic = 0.0
        self.counter_samples += 1
        if baseline_grace:
            self.counter_baseline_grace_samples += 1
        if observed:
            self.counter_observed_samples += 1
        self.append_csv(
            "counters.csv",
            {
                "timestamp_utc": utc_now(),
                "elapsed_s": self.elapsed_s(),
                "profile_token": token,
                "engine": profile.engine if profile else "unknown",
                "network": self.current_network,
                "expected_network": self.current_network,
                "observed_network": state.network,
                "network_verified": (
                    state.observed
                    and state.validated
                    and state.network == self.current_network
                ),
                "observed": observed,
                "generation": current.generation if current is not None else -1,
                "traffic_bytes": traffic,
                "traffic_delta": evaluation.display_delta,
                "native_delta": evaluation.native_delta,
                "uplink": -1,
                "downlink": -1,
                "session_total": (
                    current.native_bytes if current is not None else -1
                ),
                "probe_traffic_generated": evaluation.payload_between,
                "counter_advanced": advanced,
                "generation_changed": evaluation.generation_changed,
                "counter_reset": evaluation.reset,
                "counter_stalled": evaluation.stalled,
                "baseline_pending": baseline_was_pending,
                "baseline_grace": baseline_grace,
            },
        )
        if current is not None:
            self.payload_probe_epochs = [
                epoch for epoch in self.payload_probe_epochs if epoch > current.epoch
            ]
        if evaluation.stalled:
            self.counter_stalls += 1
        if evaluation.reset:
            self.counter_resets += 1
        if self.slot_metrics is not None:
            if observed and traffic >= 0:
                self.slot_metrics.counter_observed = True
            if evaluation.advanced:
                self.slot_metrics.counter_advanced = True
        self.observe_issue(
            "traffic_counter_stalled",
            bad=evaluation.stalled,
            observed=observed and evaluation.had_comparison,
            severity="app",
        )
        self.observe_issue(
            "traffic_counter_reset",
            bad=evaluation.reset,
            observed=evaluation.had_comparison,
            severity="app",
        )
        self.observe_issue(
            "passive_counter_observer_unavailable",
            bad=bool(error),
            observed=True,
            severity="observer",
        )
        self.observe_issue(
            "passive_counter_missing",
            bad=not observed and not error and not baseline_grace,
            observed=True,
            # This telemetry comes from Flutter in the UI process. Its absence
            # while cached/frozen does not prove a native traffic-counter fault.
            severity="observer",
        )

    def observe_issue(
        self,
        issue: str,
        *,
        bad: bool,
        observed: bool,
        severity: str,
    ) -> None:
        if not observed:
            return
        if not bad:
            self.observation_streaks[issue] = 0
            self.active_confirmed_issues.discard(issue)
            return
        streak = self.observation_streaks.get(issue, 0) + 1
        self.observation_streaks[issue] = streak
        if streak == 1:
            self.event("observation_suspect", issue=issue, severity=severity)
        if streak >= 2 and issue not in self.active_confirmed_issues:
            self.active_confirmed_issues.add(issue)
            self.confirmed_issue_counts[issue] = (
                self.confirmed_issue_counts.get(issue, 0) + 1
            )
            self.capture_incident(
                issue=issue,
                severity=severity,
                confirmation="two_consecutive_observations",
            )

    def capture_incident(
        self,
        *,
        issue: str,
        severity: str,
        confirmation: str,
        extra: Mapping[str, Any] | None = None,
    ) -> None:
        self.incident_sequence += 1
        incident_id = f"incident-{self.incident_sequence:04d}"
        main_memory, _ = self.process_memory(MAIN_PROCESS)
        vpn_memory, _ = self.process_memory(VPN_PROCESS)
        state = self.vpn_state()
        payload: dict[str, Any] = {
            "schema_version": 1,
            "incident_id": incident_id,
            "captured_utc": utc_now(),
            "elapsed_s": self.elapsed_s(),
            "issue": safe_enum(issue),
            "severity": safe_enum(severity),
            "confirmation": safe_enum(confirmation),
            "slot": {
                "index": self.current_slot.index if self.current_slot else -1,
                "phase": self.current_slot.phase if self.current_slot else "preflight",
                "profile_token": (
                    self.current_profile.token if self.current_profile else ""
                ),
                "engine": (
                    self.current_profile.engine if self.current_profile else "unknown"
                ),
                "expected_network": self.current_network,
            },
            "vpn_state": {
                "observed": state.observed,
                "validated": state.validated,
                "network": state.network,
                "runtime": state.runtime,
            },
            "processes": {
                "main": asdict(main_memory),
                "vpn": asdict(vpn_memory),
            },
            "observation_streak": self.observation_streaks.get(issue, 0),
            "automatic_recovery_attempted": False,
        }
        if extra:
            payload["evidence"] = {
                key: value
                for key, value in extra.items()
                if ENUM_RE.fullmatch(key)
                and (
                    isinstance(value, bool | int | float)
                    or (
                        isinstance(value, str)
                        and (
                            ENUM_RE.fullmatch(value) is not None
                            or TOKEN_RE.fullmatch(value) is not None
                        )
                    )
                )
            }
        self.atomic_json(f"incidents/{incident_id}.json", payload)
        incident_summary = {
            "incident_id": incident_id,
            "captured_utc": payload["captured_utc"],
            "elapsed_s": payload["elapsed_s"],
            "issue": payload["issue"],
            "severity": payload["severity"],
            "confirmation": payload["confirmation"],
        }
        self.incidents.append(incident_summary)
        self.event(
            "incident_captured",
            incident=incident_id,
            issue=issue,
            severity=severity,
        )
        self.write_live_summary()

    def health_tick(self) -> None:
        if not self.device_available():
            self.last_device_observed = False
            self.last_network_observation_fresh = False
            self.update_observer_streak(False)
            self.observer_unknown_samples += 1
            self.health_samples += 1
            phase = self.current_slot.phase if self.current_slot else "preflight"
            phase_counts = self.phase_health.setdefault(
                phase,
                {"samples": 0, "healthy": 0, "unknown": 0},
            )
            phase_counts["samples"] += 1
            phase_counts["unknown"] += 1
            self.last_health_summary = {
                "observed": False,
                "vpn_validated": False,
                "network": "unknown",
                "runtime": "unknown",
            }
            self.append_csv(
                "samples.csv",
                {
                    "timestamp_utc": utc_now(),
                    "elapsed_s": self.elapsed_s(),
                    "slot_index": self.current_slot.index if self.current_slot else -1,
                    "phase": self.current_slot.phase if self.current_slot else "preflight",
                    "profile_token": (
                        self.current_profile.token if self.current_profile else ""
                    ),
                    "engine": (
                        self.current_profile.engine if self.current_profile else "unknown"
                    ),
                    "expected_network": self.current_network,
                    "observed": False,
                    "vpn_validated": "",
                    "observed_network": "unknown",
                    "runtime": "unknown",
                    "main_process_present": "",
                    "vpn_process_present": "",
                    "health_ok": "",
                },
            )
            self.observe_issue(
                "observer_unavailable",
                bad=True,
                observed=True,
                severity="observer",
            )
            return

        self.last_device_observed = True
        self.observe_issue(
            "observer_unavailable",
            bad=False,
            observed=True,
            severity="observer",
        )
        state = self.vpn_state()
        self.last_network_observation_fresh = state.observed
        if state.observed:
            self.last_observed_network = state.network
        self.observe_issue(
            "vpn_state_observer_unavailable",
            bad=not state.observed,
            observed=True,
            severity="observer",
        )
        profile = self.current_profile
        main_pid, main_observed = self.pidof(MAIN_PROCESS)
        vpn_pid, vpn_observed = self.pidof(VPN_PROCESS)
        process_observed = main_observed and vpn_observed
        observation_known = state.observed and process_observed
        self.update_observer_streak(observation_known)
        if not observation_known:
            self.observer_unknown_samples += 1
        expected_runtime = profile.runtime if profile else "unknown"
        state_ok = (
            state.observed
            and state.validated
            and state.network == self.current_network
            and state.runtime == expected_runtime
        )
        health_ok = (
            observation_known and state_ok and bool(main_pid) and bool(vpn_pid)
        )
        self.health_samples += 1
        if health_ok:
            self.healthy_samples += 1
        if self.slot_metrics is not None and state.observed:
            self.slot_metrics.observed_samples += 1
            if health_ok:
                self.slot_metrics.healthy_samples += 1
        phase = self.current_slot.phase if self.current_slot else "preflight"
        phase_counts = self.phase_health.setdefault(
            phase,
            {"samples": 0, "healthy": 0, "unknown": 0},
        )
        phase_counts["samples"] += 1
        if health_ok:
            phase_counts["healthy"] += 1
        if not observation_known:
            phase_counts["unknown"] += 1
        self.last_health_summary = {
            "observed": observation_known,
            "vpn_validated": state.validated,
            "network": state.network,
            "runtime": state.runtime,
            "health_ok": health_ok,
        }
        self.append_csv(
            "samples.csv",
            {
                "timestamp_utc": utc_now(),
                "elapsed_s": self.elapsed_s(),
                "slot_index": self.current_slot.index if self.current_slot else -1,
                "phase": self.current_slot.phase if self.current_slot else "preflight",
                "profile_token": profile.token if profile else "",
                "engine": profile.engine if profile else "unknown",
                "expected_network": self.current_network,
                "observed": state.observed,
                "vpn_validated": state.validated if state.observed else "",
                "observed_network": state.network,
                "runtime": state.runtime,
                "main_process_present": bool(main_pid) if process_observed else "",
                "vpn_process_present": bool(vpn_pid) if process_observed else "",
                "health_ok": health_ok if state.observed and process_observed else "",
            },
        )
        self.observe_issue(
            "vpn_not_validated",
            bad=state.observed and not state.validated,
            observed=state.observed,
            severity="app",
        )
        self.observe_issue(
            "wrong_underlying_network",
            bad=state.observed
            and state.validated
            and state.network != self.current_network,
            observed=state.observed and state.validated,
            severity="app",
        )
        self.observe_issue(
            "wrong_runtime",
            bad=state.observed
            and state.validated
            and state.runtime != expected_runtime,
            observed=state.observed and state.validated,
            severity="app",
        )
        self.observe_issue(
            "vpn_process_missing",
            bad=not bool(vpn_pid),
            observed=vpn_observed,
            severity="app",
        )
        self.observe_issue(
            "main_process_missing",
            bad=not bool(main_pid),
            observed=main_observed,
            severity="app",
        )
        self.detect_process_change("main", main_pid)
        self.detect_process_change("vpn", vpn_pid)

    def detect_process_change(self, role: str, pid: str) -> None:
        previous = self.process_last_pid[role]
        if not pid:
            return
        if not previous or previous != pid:
            self.process_instance(role, pid)
        self.process_last_pid[role] = pid
        if not previous or previous == pid:
            if (
                role == "vpn"
                and self.planned_vpn_pid_change_pending
                and not self.planned_vpn_process_change_active
            ):
                # First reliable observation after an observer gap proves that
                # the expected transition did not produce a new PID.
                self.planned_vpn_pid_change_pending = False
            return
        expected_window = (
            role == "vpn"
            and self.planned_vpn_pid_change_pending
        )
        if expected_window:
            self.planned_vpn_pid_change_pending = False
        self.event(
            "process_instance_changed",
            role=role,
            expected_window=expected_window,
        )
        if not expected_window:
            self.definitive_failures["unexpected_exit"] += 1
            self.capture_incident(
                issue=f"unexpected_{role}_process_restart",
                severity="app",
                confirmation="process_identity_changed",
            )

    def begin_planned_vpn_process_change_window(
        self,
        *,
        required: bool,
        exit_boundary_observed: bool,
    ) -> None:
        self.planned_vpn_process_change_active = required
        self.planned_vpn_pid_change_pending = required
        self.planned_vpn_exit_event_pending = required and exit_boundary_observed
        self.planned_vpn_exit_event_ambiguous_pending = (
            required and not exit_boundary_observed
        )
        if self.planned_vpn_exit_event_ambiguous_pending:
            self.exit_transition_boundary_observer_failures += 1
            self.event(
                "exit_transition_boundary_unobserved",
                severity="observer",
            )

    def close_planned_vpn_process_change_window(self) -> None:
        if self.planned_vpn_process_change_active:
            vpn_pid, pid_observed = self.pidof(VPN_PROCESS)
            if pid_observed:
                self.detect_process_change("vpn", vpn_pid)
                # The transition is complete and the post-transition PID was
                # observed. Do not allow a later unrelated restart to consume
                # this one-shot expectation.
                self.planned_vpn_pid_change_pending = False
        exit_scan_observed = False
        try:
            # Exit-info is scanned while the explicit transition window is
            # still active; native crash/ANR/OOM classifications still fail.
            exit_scan_observed = self.scan_exit_info()
        finally:
            self.planned_vpn_process_change_active = False
        if exit_scan_observed:
            self.planned_vpn_exit_event_pending = False
            self.planned_vpn_exit_event_ambiguous_pending = False

    def read_exit_info(self) -> list[ExitEvent] | None:
        result, error = self.shell(
            "dumpsys",
            "activity",
            "exit-info",
            PACKAGE,
            timeout=60,
        )
        if error or result is None:
            return None
        return parse_exit_info(result.stdout)

    def write_exit_baseline(self) -> None:
        events = self.read_exit_info()
        if events is None:
            raise RuntimeError("exit_info_baseline_unavailable")
        self.baseline_exit_ids = {event.event_id for event in events}
        self.seen_exit_ids = set(self.baseline_exit_ids)
        counts: dict[str, int] = {}
        for event in events:
            key = f"{event.reason_code}_{event.reason_name}"
            counts[key] = counts.get(key, 0) + 1
        self.atomic_json(
            "exit-info-baseline.json",
            {
                "captured_utc": utc_now(),
                "entry_count": len(events),
                "reason_counts": counts,
                "raw_output_persisted": False,
            },
        )

    def classify_exit_event(self, event: ExitEvent) -> tuple[str, bool]:
        expected_window = (
            event.process_role == "vpn"
            and self.planned_vpn_exit_event_pending
        )
        ambiguous_window = (
            event.process_role == "vpn"
            and self.planned_vpn_exit_event_ambiguous_pending
        )
        if event.reason_code == 4:
            return "crash", True
        if event.reason_code == 2:
            if event.process_role == "vpn" and expected_window and event.status in {9, 15}:
                return "expected_vpn_signal", False
            if event.process_role == "vpn" and ambiguous_window and event.status in {-1, 9, 15}:
                return "ambiguous_vpn_signal", False
            # REASON_SIGNALED also includes SIGKILL and ordinary termination.
            # Android reports confirmed native crashes as REASON_CRASH_NATIVE.
            return "signaled_exit", True
        if event.reason_code == 5:
            return "native_crash", True
        if event.reason_code == 6:
            return "anr", True
        if event.reason_code == 3:
            return "oom", True
        if event.reason_code == 9:
            return "excessive_resource", True
        if event.reason_code == 1:
            expected = event.process_role == "vpn" and expected_window
            if event.process_role == "vpn" and ambiguous_window:
                return "ambiguous_vpn_exit", False
            return ("expected_vpn_exit" if expected else "unexpected_exit"), not expected
        if event.reason_code in {7, 10, 12, 15, 16}:
            return "unexpected_exit", True
        return "informational_exit", False

    def scan_exit_info(self) -> bool:
        events = self.read_exit_info()
        if events is None:
            self.observe_issue(
                "exit_info_observer_unavailable",
                bad=True,
                observed=True,
                severity="observer",
            )
            return False
        self.observe_issue(
            "exit_info_observer_unavailable",
            bad=False,
            observed=True,
            severity="observer",
        )
        for event in reversed(events):
            if event.event_id in self.seen_exit_ids:
                continue
            self.seen_exit_ids.add(event.event_id)
            if exit_event_is_pre_run(
                event.timestamp_local,
                self.diagnostic_started_device_local,
            ):
                self.baseline_exit_ids.add(event.event_id)
                self.event("delayed_pre_run_exit_ignored")
                continue
            expected_window = (
                event.process_role == "vpn"
                and self.planned_vpn_exit_event_pending
                and event.reason_code in {1, 2}
            )
            ambiguous_window = (
                event.process_role == "vpn"
                and self.planned_vpn_exit_event_ambiguous_pending
                and event.reason_code in {1, 2}
            )
            classification, failure = self.classify_exit_event(event)
            if expected_window and classification.startswith("expected_vpn_"):
                self.planned_vpn_exit_event_pending = False
            if ambiguous_window and classification.startswith("ambiguous_vpn_"):
                self.planned_vpn_exit_event_ambiguous_pending = False
            self.append_csv(
                "exit-events.csv",
                {
                    "detected_utc": utc_now(),
                    "event_timestamp_local": event.timestamp_local,
                    "process_role": event.process_role,
                    "reason_code": event.reason_code,
                    "reason_name": event.reason_name,
                    "subreason_code": event.subreason_code,
                    "subreason_name": event.subreason_name,
                    "status": event.status,
                    "pss_kb": event.pss_kb,
                    "rss_kb": event.rss_kb,
                    "classification": classification,
                    "expected_transition_window": expected_window,
                    "transition_boundary_ambiguous": ambiguous_window,
                },
            )
            self.append_jsonl(
                "logcat-sanitized.jsonl",
                {
                    "detected_utc": utc_now(),
                    "source": "exit_info",
                    "event_class": classification,
                    "process_role": event.process_role,
                    "reason_code": event.reason_code,
                    "subreason_code": event.subreason_code,
                    "status": event.status,
                },
            )
            if failure:
                failure_key = (
                    classification
                    if classification in self.definitive_failures
                    else "unexpected_exit"
                )
                self.definitive_failures[failure_key] += 1
                self.capture_incident(
                    issue=classification,
                    severity="app",
                    confirmation="android_exit_info",
                    extra={
                        "process_role": event.process_role,
                        "reason_code": event.reason_code,
                        "subreason_code": event.subreason_code,
                        "status": event.status,
                    },
                )
        if not self.planned_vpn_process_change_active:
            # A successful delayed scan is the boundary for the one-shot clean
            # process expectation. It cannot mask an unrelated future exit.
            self.planned_vpn_exit_event_pending = False
            self.planned_vpn_exit_event_ambiguous_pending = False
        return True

    def scan_runtime_isolation(self) -> None:
        current_core = (
            normalize_engine(self.current_profile.engine)
            if self.current_profile is not None
            else ""
        )
        if current_core and current_core in self.isolation_evidence:
            return
        result: subprocess.CompletedProcess[str] | None = None
        for attempt in range(6):
            vpn_pid, pid_observed = self.pidof(VPN_PROCESS)
            if pid_observed and vpn_pid:
                candidate, error = self.adb_run(
                    "logcat",
                    "-b",
                    "main",
                    "-d",
                    "-v",
                    "epoch",
                    "--pid",
                    vpn_pid,
                    timeout=30,
                )
                if (
                    not error
                    and candidate is not None
                    and "RUNTIME_ISOLATION" in candidate.stdout
                ):
                    result = candidate
                    break
            if attempt < 5:
                time.sleep(1)
        if result is None:
            return
        pattern = re.compile(
            r"^\s*(?P<epoch>\d+\.\d+).+RUNTIME_ISOLATION\s+"
            r"core=(?P<core>[A-Za-z0-9_-]+)\s+"
            r"libbox=(?P<libbox>true|false)\s+"
            r"libgojni=(?P<libgojni>true|false)\s+"
            r"safe=(?P<safe>true|false)",
            re.MULTILINE,
        )
        for match in pattern.finditer(result.stdout):
            core = normalize_engine(match.group("core"))
            libbox = match.group("libbox") == "true"
            libgojni = match.group("libgojni") == "true"
            safe = match.group("safe") == "true"
            identity = hashlib.sha256(
                (
                    f"{match.group('epoch')}|{core}|{libbox}|"
                    f"{libgojni}|{safe}"
                ).encode("utf-8")
            ).hexdigest()[:20]
            if identity in self.seen_runtime_log_ids:
                continue
            self.seen_runtime_log_ids.add(identity)
            self.isolation_evidence[core] = (
                self.isolation_evidence.get(core, True) and safe
            )
            row = {
                "detected_utc": utc_now(),
                "elapsed_s": self.elapsed_s(),
                "core": core,
                "libbox_loaded": libbox,
                "libgojni_loaded": libgojni,
                "safe": safe,
            }
            self.append_csv("runtime-isolation.csv", row)
            self.append_jsonl(
                "logcat-sanitized.jsonl",
                {
                    "detected_utc": row["detected_utc"],
                    "source": "runtime_isolation",
                    "event_class": "runtime_isolation",
                    "core": core,
                    "libbox_loaded": libbox,
                    "libgojni_loaded": libgojni,
                    "safe": safe,
                },
            )
            if not safe:
                self.definitive_failures["runtime_isolation"] += 1
                self.capture_incident(
                    issue="unsafe_native_runtime_isolation",
                    severity="app",
                    confirmation="native_runtime_guard",
                    extra={
                        "core": core,
                        "libbox_loaded": libbox,
                        "libgojni_loaded": libgojni,
                        "safe": safe,
                    },
                )

    def perform_switch(
        self,
        profile: Profile,
        *,
        kind: str = "activate",
        qualifying: bool = True,
    ) -> bool:
        previous = self.current_profile
        requires_clean_process = profile_switch_requires_clean_process(
            previous,
            profile,
        )
        exit_boundary_observed = self.scan_exit_info()
        self.begin_planned_vpn_process_change_window(
            required=requires_clean_process,
            exit_boundary_observed=exit_boundary_observed,
        )
        self.write_heartbeat()
        started = time.monotonic()
        payload, error = self.bridge_request("activate", profile.token)
        sla_started = self.last_bridge_control_dispatch_monotonic or started
        command_ok = (
            error == ""
            and payload is not None
            and bool(payload.get("ok"))
            and payload.get("profileToken") == profile.token
        )
        self.current_profile = profile
        self.current_profile_verified = False
        self.begin_post_transition_counter_baseline()
        ready_result = WaitReadyResult(False, VpnState(), 0, 0)
        if command_ok:
            ready_result = self.wait_ready(
                profile,
                self.current_network,
                SWITCH_READY_TIMEOUT_S,
            )
        ready = ready_result.ready
        duration_ms = int((time.monotonic() - sla_started) * 1_000)
        tcp = ProbeResult(False, False)
        https = ProbeResult(False, False)
        if ready:
            tcp, https = self.probe_tick(
                "preflight_switch" if not qualifying else "switch"
            )
        transition_ok = (
            command_ok
            and ready
            and self.last_probe_tunnel_verified
            and tcp.observed
            and tcp.ok
            and https.observed
            and https.ok
        )
        self.current_profile_verified = transition_ok
        if transition_ok and profile.token not in self.successful_profile_tokens:
            self.successful_profile_tokens.append(profile.token)
        error_code = ""
        if not command_ok:
            error_code = error or safe_enum(payload.get("error") if payload else None)
            if error_code == "unknown":
                error_code = "activate_failed"
        elif not ready:
            error_code = (
                "ready_timeout"
                if ready_result.sustained_observation
                else "ready_observer_unavailable"
            )
        elif not tcp.observed or not https.observed:
            error_code = "probe_unobserved"
        elif not tcp.ok:
            error_code = "tcp_failed"
        elif not https.ok:
            error_code = "https_failed"
        elif not self.last_probe_tunnel_verified:
            error_code = (
                "tunnel_changed_during_probe" if self.last_probe_tunnel_observed
                else "tunnel_probe_observer_unavailable"
            )
        row = {
            "timestamp_utc": utc_now(),
            "elapsed_s": self.elapsed_s(),
            "kind": kind,
            "from_profile_token": previous.token if previous else "",
            "to_profile_token": profile.token,
            "engine": profile.engine,
            "network": self.current_network,
            "command_ok": command_ok,
            "ready": ready,
            "ready_observed_samples": ready_result.observed_samples,
            "ready_unobserved_samples": ready_result.unobserved_samples,
            "tcp_ok": tcp.ok if tcp.observed else "",
            "https_ok": https.ok if https.observed else "",
            "duration_ms": duration_ms,
            "sla_max_ok": duration_ms <= SWITCH_MAX_SLA_MS,
            "error_code": error_code,
            "qualifying": qualifying,
            "_qualifying": qualifying,
        }
        self.append_csv("switches.csv", row)
        self.switch_records.append(row)
        self.event(
            "profile_switch_finished",
            kind=kind,
            profile=profile.token,
            engine=profile.engine,
            ok=transition_ok,
        )
        self.scan_runtime_isolation()
        self.close_planned_vpn_process_change_window()
        if qualifying and not transition_ok:
            self.capture_incident(
                issue="profile_switch_failed",
                severity="app",
                confirmation="scheduled_transition_result",
                extra={
                    "profile_token": profile.token,
                    "engine": profile.engine,
                    "error_code": error_code,
                    "duration_ms": duration_ms,
                },
            )
        self.write_live_summary()
        return transition_ok

    def perform_reconnect(self) -> bool:
        profile = self.current_profile
        if profile is None:
            return False
        self.scan_exit_info()
        # A reconnect keeps the same runtime core. Any process exit here is an
        # app recovery/regression, not an expected protocol-switch teardown.
        self.planned_vpn_process_change_active = False
        self.planned_vpn_pid_change_pending = False
        self.planned_vpn_exit_event_pending = False
        self.planned_vpn_exit_event_ambiguous_pending = False
        self.write_heartbeat()
        started = time.monotonic()
        payload, error = self.bridge_request("reconnect")
        sla_started = self.last_bridge_control_dispatch_monotonic or started
        command_ok = (
            error == ""
            and payload is not None
            and bool(payload.get("ok"))
            and payload.get("profileToken") == profile.token
        )
        ready_result = WaitReadyResult(False, VpnState(), 0, 0)
        if command_ok:
            ready_result = self.wait_ready(
                profile,
                self.current_network,
                SWITCH_READY_TIMEOUT_S,
            )
        ready = ready_result.ready
        duration_ms = int((time.monotonic() - sla_started) * 1_000)
        tcp = ProbeResult(False, False)
        https = ProbeResult(False, False)
        if ready:
            tcp, https = self.probe_tick("reconnect")
        reconnect_ok = (
            command_ok
            and ready
            and self.last_probe_tunnel_verified
            and tcp.observed
            and tcp.ok
            and https.observed
            and https.ok
        )
        self.current_profile_verified = reconnect_ok
        error_code = ""
        if not command_ok:
            error_code = error or safe_enum(payload.get("error") if payload else None)
            if error_code == "unknown":
                error_code = "reconnect_failed"
        elif not ready:
            error_code = (
                "ready_timeout"
                if ready_result.sustained_observation
                else "ready_observer_unavailable"
            )
        elif not tcp.observed or not https.observed:
            error_code = "probe_unobserved"
        elif not tcp.ok:
            error_code = "tcp_failed"
        elif not https.ok:
            error_code = "https_failed"
        elif not self.last_probe_tunnel_verified:
            error_code = (
                "tunnel_changed_during_probe" if self.last_probe_tunnel_observed
                else "tunnel_probe_observer_unavailable"
            )
        row = {
            "timestamp_utc": utc_now(),
            "elapsed_s": self.elapsed_s(),
            "kind": "reconnect",
            "from_profile_token": profile.token,
            "to_profile_token": profile.token,
            "engine": profile.engine,
            "network": self.current_network,
            "command_ok": command_ok,
            "ready": ready,
            "ready_observed_samples": ready_result.observed_samples,
            "ready_unobserved_samples": ready_result.unobserved_samples,
            "tcp_ok": tcp.ok if tcp.observed else "",
            "https_ok": https.ok if https.observed else "",
            "duration_ms": duration_ms,
            "sla_max_ok": duration_ms <= SWITCH_MAX_SLA_MS,
            "error_code": error_code,
            "qualifying": True,
            "_qualifying": True,
        }
        self.append_csv("switches.csv", row)
        self.switch_records.append(row)
        self.begin_post_transition_counter_baseline()
        self.event(
            "profile_reconnect_finished",
            profile=profile.token,
            engine=profile.engine,
            ok=reconnect_ok,
        )
        self.scan_runtime_isolation()
        self.scan_exit_info()
        if not reconnect_ok:
            self.capture_incident(
                issue="profile_reconnect_failed",
                severity="app",
                confirmation="scheduled_transition_result",
                extra={
                    "profile_token": profile.token,
                    "engine": profile.engine,
                    "error_code": error_code,
                    "duration_ms": duration_ms,
                },
            )
        self.write_live_summary()
        return reconnect_ok

    def perform_handover(
        self,
        network: str,
        *,
        qualifying: bool = True,
    ) -> bool:
        profile = self.current_profile
        previous_network = self.current_network
        exit_boundary_observed = self.scan_exit_info()
        self.begin_planned_vpn_process_change_window(
            required=profile is not None and profile.runtime == "xray",
            exit_boundary_observed=exit_boundary_observed,
        )
        started = time.monotonic()
        self.write_heartbeat()
        radio_ok = self.set_radios(network)
        # A live underlying-network handover must preserve the VPN session and
        # its counters. Keeping the cursor makes generation changes, resets,
        # and native/display stalls observable after the handover probe.
        self.current_network = network
        self.last_network_observation_fresh = False
        ready_result = WaitReadyResult(False, VpnState(), 0, 0)
        if radio_ok and profile is not None:
            ready_result = self.wait_ready(
                profile,
                network,
                HANDOVER_READY_TIMEOUT_S,
            )
        ready = ready_result.ready
        duration_ms = int((time.monotonic() - started) * 1_000)
        tcp = ProbeResult(False, False)
        https = ProbeResult(False, False)
        if ready:
            tcp, https = self.probe_tick(
                "preflight_handover" if not qualifying else "handover"
            )
        handover_ok = (
            radio_ok
            and ready
            and self.last_probe_tunnel_verified
            and tcp.observed
            and tcp.ok
            and https.observed
            and https.ok
        )
        error_code = ""
        if not radio_ok:
            error_code = "radio_command_failed"
        elif profile is None:
            error_code = "no_active_profile"
        elif not ready:
            error_code = (
                "ready_timeout"
                if ready_result.sustained_observation
                else "ready_observer_unavailable"
            )
        elif not tcp.observed or not https.observed:
            error_code = "probe_unobserved"
        elif not tcp.ok:
            error_code = "tcp_failed"
        elif not https.ok:
            error_code = "https_failed"
        elif not self.last_probe_tunnel_verified:
            error_code = (
                "tunnel_changed_during_probe" if self.last_probe_tunnel_observed
                else "tunnel_probe_observer_unavailable"
            )
        row = {
            "timestamp_utc": utc_now(),
            "elapsed_s": self.elapsed_s(),
            "slot_index": self.current_slot.index if self.current_slot else -1,
            "phase": self.current_slot.phase if self.current_slot else "preflight",
            "from_network": previous_network,
            "to_network": network,
            "profile_token": profile.token if profile else "",
            "engine": profile.engine if profile else "unknown",
            "radio_command_ok": radio_ok,
            "ready": ready,
            "ready_observed_samples": ready_result.observed_samples,
            "ready_unobserved_samples": ready_result.unobserved_samples,
            "tcp_ok": tcp.ok if tcp.observed else "",
            "https_ok": https.ok if https.observed else "",
            "duration_ms": duration_ms,
            "sla_max_ok": duration_ms <= HANDOVER_MAX_SLA_MS,
            "error_code": error_code,
            "qualifying": qualifying,
            "_qualifying": qualifying,
        }
        self.append_csv("handovers.csv", row)
        self.handover_records.append(row)
        self.event(
            "network_handover_finished",
            from_network=previous_network,
            to_network=network,
            ok=handover_ok,
        )
        self.scan_runtime_isolation()
        self.close_planned_vpn_process_change_window()
        if qualifying and not handover_ok:
            self.capture_incident(
                issue="network_handover_failed",
                severity="app",
                confirmation="scheduled_transition_result",
                extra={
                    "from_network": previous_network,
                    "to_network": network,
                    "error_code": error_code,
                    "duration_ms": duration_ms,
                },
            )
        self.write_live_summary()
        return handover_ok

    def perform_radio_only(self, network: str, *, source: str = "preflight") -> bool:
        started = time.monotonic()
        radio_ok = self.set_radios(network)
        self.begin_post_transition_counter_baseline()
        self.current_network = network
        self.last_network_observation_fresh = False
        if radio_ok:
            time.sleep(2)
        self.event(
            "radio_only_set",
            source=source,
            network=network,
            ok=radio_ok,
            duration_ms=int((time.monotonic() - started) * 1_000),
        )
        return radio_ok

    def preflight(self) -> None:
        xray_candidates = [
            profile for profile in self.profiles if profile.runtime == "xray"
        ]
        if not self.perform_radio_only("cellular"):
            raise RuntimeError("cellular_radio_preflight_failed")
        cellular_xray: Profile | None = None
        cross_network_xray: Profile | None = None
        wifi_environment_available = False
        wifi_tcp_pass = False
        wifi_https_pass = False
        for candidate in xray_candidates:
            if self.current_network != "cellular":
                if not self.perform_radio_only("cellular"):
                    raise RuntimeError("cellular_radio_preflight_failed")
            if not self.perform_switch(
                candidate,
                kind="preflight_xray_candidate",
                qualifying=False,
            ):
                continue
            if cellular_xray is None:
                cellular_xray = candidate
            handover_pass = self.perform_handover("wifi", qualifying=False)
            if self.handover_records:
                handover_record = self.handover_records[-1]
                wifi_tcp_pass = (
                    wifi_tcp_pass or bool(handover_record.get("tcp_ok"))
                )
                wifi_https_pass = (
                    wifi_https_pass or bool(handover_record.get("https_ok"))
                )
            if handover_pass:
                cross_network_xray = candidate
                wifi_environment_available = True
                break
            wifi_connected = self.wifi_connected()
            if wifi_connected is False:
                raise RuntimeError("wifi_environment_unavailable")
            if wifi_connected is None:
                raise RuntimeError("wifi_environment_observer_unavailable")
            wifi_environment_available = True
        selected_xray, cross_network_pass = select_preflight_xray(
            cellular_xray,
            cross_network_xray,
        )
        if selected_xray is None:
            raise RuntimeError("xray_cellular_preflight_failed")
        self.scan_runtime_isolation()
        self.scan_exit_info()
        if any(self.definitive_failures.values()):
            raise RuntimeError("preflight_runtime_failure")
        if self.require_isolation_evidence:
            if self.isolation_evidence.get("xray") is not True:
                raise RuntimeError("xray_isolation_evidence_missing")
        if not cross_network_pass:
            issue = "xray_cross_network_preflight_failed"
            self.confirmed_issue_counts[issue] = (
                self.confirmed_issue_counts.get(issue, 0) + 1
            )
            self.capture_incident(
                issue=issue,
                severity="app",
                confirmation="all_xray_candidates_checked",
                extra={
                    "cellular_profile_token": selected_xray.token,
                    "wifi_environment_available": wifi_environment_available,
                },
            )
            self.event(
                "preflight_profile_failure_recorded",
                issue=issue,
                matrix_continues=True,
            )
        self.atomic_json(
            "preflight.json",
            {
                "completed": True,
                "completed_utc": utc_now(),
                "profile_count": len(self.profiles),
                "cellular": cellular_xray is not None,
                "wifi": wifi_environment_available,
                "tcp": wifi_tcp_pass,
                "https": wifi_https_pass,
                "cellular_data_plane_pass": cellular_xray is not None,
                "wifi_environment_available": wifi_environment_available,
                "cross_network_pass": cross_network_pass,
                "runtime_isolation": {
                    "singbox": "deferred_to_matrix",
                    "xray": self.isolation_evidence.get("xray"),
                },
                "selected_xray_profile_token": selected_xray.token,
                "raw_diagnostics_persisted": False,
            },
        )

    def resolve_endurance_schedule(self) -> None:
        if self.endurance_schedule_resolved:
            return
        passing_by_runtime: dict[str, list[Profile]] = {
            "singbox": [],
            "xray": [],
        }
        seen: set[str] = set()
        for record in self.matrix_records:
            token = str(record["profile_token"])
            profile = self.profile_by_token[token]
            connected = (
                bool(record["entry_ok"])
                and safe_int(record["healthy_samples"], 0) > 0
            )
            if connected and token not in seen:
                passing_by_runtime[profile.runtime].append(profile)
                seen.add(token)

        scored = sorted(
            self.profiles,
            key=lambda profile: (
                -sum(
                    (
                        100_000 if bool(record["coverage_ok"]) else 0
                    )
                    + safe_int(record["healthy_samples"], 0)
                    for record in self.matrix_records
                    if record["profile_token"] == profile.token
                ),
                self.profiles.index(profile),
            ),
        )
        known_good = [
            self.profile_by_token[token]
            for token in self.successful_profile_tokens
            if token in self.profile_by_token
        ]
        fallback = next(
            (
                profile
                for profile in scored
                if any(
                    record["profile_token"] == profile.token
                    and safe_int(record["healthy_samples"], 0) > 0
                    for record in self.matrix_records
                )
            ),
            known_good[0] if known_good else self.profiles[0],
        )

        selected: dict[str, Profile] = {}
        for runtime in ("singbox", "xray"):
            if passing_by_runtime[runtime]:
                selected[runtime] = passing_by_runtime[runtime][0]
                continue
            selected[runtime] = fallback
            self.definitive_failures["missing_engine_dwell"] += 1
            self.capture_incident(
                issue=f"missing_{runtime}_engine_dwell",
                severity="app",
                confirmation="profile_matrix_result",
                extra={
                    "requested_runtime": runtime,
                    "fallback_profile_token": fallback.token,
                    "fallback_engine": fallback.engine,
                },
            )

        resolved: list[Slot] = []
        for slot in self.schedule:
            if slot.phase == "dwell-singbox-cellular":
                profile = selected["singbox"]
                phase = (
                    slot.phase
                    if profile.runtime == "singbox"
                    else "dwell-fallback-cellular-missing-singbox"
                )
                slot = replace(
                    slot,
                    phase=phase,
                    profile_token=profile.token,
                    kind=profile.kind,
                    engine=profile.engine,
                )
            elif slot.phase.startswith("dwell-xray") or slot.phase.startswith(
                "handover-xray"
            ):
                profile = selected["xray"]
                phase = (
                    slot.phase
                    if profile.runtime == "xray"
                    else slot.phase.replace("xray", "fallback-missing-xray")
                )
                slot = replace(
                    slot,
                    phase=phase,
                    profile_token=profile.token,
                    kind=profile.kind,
                    engine=profile.engine,
                )
            resolved.append(slot)
        self.schedule[:] = resolved
        self.endurance_profiles = {
            "singbox_role": selected["singbox"].token,
            "xray_role": selected["xray"].token,
        }
        self.endurance_schedule_resolved = True
        self.atomic_json(
            "schedule-resolved.json",
            {
                "resolved_utc": utc_now(),
                "selection_policy": "first_matrix_connected_per_engine",
                "fallback_policy": "best_observed_data_plane_profile",
                "engine_profiles": self.endurance_profiles,
                "missing_engine_failure": (
                    self.definitive_failures["missing_engine_dwell"] > 0
                ),
                "slots": [asdict(slot) for slot in self.schedule],
            },
        )
        self.event(
            "endurance_schedule_resolved",
            singbox_profile=selected["singbox"].token,
            xray_profile=selected["xray"].token,
            missing_engine=(
                self.definitive_failures["missing_engine_dwell"] > 0
            ),
        )

    def advance_due(self, attribute: str, interval_s: int, elapsed: float) -> None:
        due = float(getattr(self, attribute))
        while due <= elapsed:
            due += interval_s
        setattr(self, attribute, due)

    def service_due_tasks(self) -> None:
        elapsed = time.monotonic() - self.started_monotonic
        if elapsed >= self.next_health_at:
            self.record_scheduled_health_tick(elapsed)
            self.health_tick()
            self.advance_due(
                "next_health_at",
                HEALTH_INTERVAL_S,
                time.monotonic() - self.started_monotonic,
            )

        elapsed = time.monotonic() - self.started_monotonic
        if self.last_device_observed and elapsed >= self.next_probe_at:
            self.probe_tick()
        if elapsed >= self.next_probe_at:
            self.advance_due(
                "next_probe_at",
                PROBE_INTERVAL_S,
                time.monotonic() - self.started_monotonic,
            )

        elapsed = time.monotonic() - self.started_monotonic
        counter_settled = (
            self.last_probe_completed_monotonic <= 0
            or time.monotonic() - self.last_probe_completed_monotonic >= 3.0
        )
        if elapsed >= self.next_counter_at and counter_settled:
            self.counter_tick(device_observed=self.last_device_observed)
        if elapsed >= self.next_counter_at and counter_settled:
            self.advance_due(
                "next_counter_at",
                COUNTER_INTERVAL_S,
                time.monotonic() - self.started_monotonic,
            )

        elapsed = time.monotonic() - self.started_monotonic
        if self.last_device_observed and elapsed >= self.next_memory_at:
            self.memory_tick()
            print(
                "SOAK24 "
                f"elapsed={self.elapsed_s()}/{self.duration_target_s} "
                f"phase={self.current_slot.phase if self.current_slot else 'starting'} "
                f"profile={self.current_profile.token if self.current_profile else 'none'} "
                f"network={self.current_network} "
                f"healthy={self.healthy_samples}/{self.health_samples} "
                f"incidents={len(self.incidents)}",
                flush=True,
            )
        if elapsed >= self.next_memory_at:
            self.advance_due(
                "next_memory_at",
                MEMORY_INTERVAL_S,
                time.monotonic() - self.started_monotonic,
            )

        elapsed = time.monotonic() - self.started_monotonic
        if self.last_device_observed and elapsed >= self.next_exit_info_at:
            self.scan_exit_info()
            self.scan_runtime_isolation()
            self.write_live_summary()
        if elapsed >= self.next_exit_info_at:
            self.advance_due(
                "next_exit_info_at",
                EXIT_INFO_INTERVAL_S,
                time.monotonic() - self.started_monotonic,
            )

        self.write_heartbeat()

    def sleep_until_next(self, slot_end_s: int) -> None:
        elapsed = time.monotonic() - self.started_monotonic
        counter_due = self.next_counter_at
        if (
            counter_due <= elapsed
            and self.last_probe_completed_monotonic > 0
            and time.monotonic() - self.last_probe_completed_monotonic < 3.0
        ):
            counter_due = elapsed + (
                3.0 - (time.monotonic() - self.last_probe_completed_monotonic)
            )
        next_due = min(
            self.next_health_at,
            self.next_probe_at,
            counter_due,
            self.next_memory_at,
            self.next_exit_info_at,
            float(slot_end_s),
            float(self.duration_target_s),
        )
        time.sleep(max(0.05, min(0.5, next_due - elapsed)))

    def enter_slot(self, slot: Slot) -> None:
        self.current_slot = slot
        self.slot_metrics = SlotMetrics()
        target = self.profile_by_token[slot.profile_token]
        before = self.vpn_state()
        if self.current_network != slot.network:
            active_tunnel = (
                self.current_profile is not None
                and before.observed
                and before.validated
                and before.runtime == self.current_profile.runtime
            )
            if active_tunnel:
                # A failed real handover remains its own incident. Matrix entry is
                # evaluated from the final target tunnel below.
                self.perform_handover(slot.network)
            else:
                # There is no tunnel to hand over. Change radios, then make an
                # explicit target activation even if the token is unchanged.
                self.perform_radio_only(slot.network, source="slot_entry")
                self.current_network = slot.network
        entry_ok = False
        if (
            self.current_profile is None
            or self.current_profile.token != target.token
            or not self.current_profile_verified
        ):
            entry_ok = self.perform_switch(target)
        else:
            ready_result = self.wait_ready(target, slot.network, 10)
            entry_ok = (
                ready_result.ready
                if ready_result.ready
                else self.perform_switch(target)
            )
        self.current_profile = target
        self.current_network = slot.network
        self.slot_metrics.entry_ok = entry_ok
        self.event(
            "slot_started",
            slot=slot.index,
            phase=slot.phase,
            profile=slot.profile_token,
            engine=slot.engine,
            network=slot.network,
            entry_ok=entry_ok,
        )
        self.write_live_summary()

    def finish_slot(self, slot: Slot) -> None:
        metrics = self.slot_metrics or SlotMetrics()
        if slot.phase.startswith("matrix-"):
            coverage_ok = (
                metrics.entry_ok
                and metrics.reconnect_attempted
                and metrics.reconnect_ok
                and metrics.counter_observed
                and metrics.counter_advanced
                and metrics.payload_probe_success
                and metrics.observed_samples > 0
                and metrics.healthy_samples > 0
            )
            row = {
                "slot_index": slot.index,
                "profile_token": slot.profile_token,
                "kind": slot.kind,
                "engine": slot.engine,
                "network": slot.network,
                "started_elapsed_s": slot.planned_start_s,
                "finished_elapsed_s": min(self.elapsed_s(), slot.planned_end_s),
                "entry_ok": metrics.entry_ok,
                "reconnect_attempted": metrics.reconnect_attempted,
                "reconnect_ok": metrics.reconnect_ok,
                "counter_observed": metrics.counter_observed,
                "counter_advanced": metrics.counter_advanced,
                "payload_probe_success": metrics.payload_probe_success,
                "healthy_samples": metrics.healthy_samples,
                "observed_samples": metrics.observed_samples,
                "coverage_ok": coverage_ok,
            }
            self.append_csv("profile-matrix.csv", row)
            self.matrix_records.append(row)
        self.event(
            "slot_finished",
            slot=slot.index,
            phase=slot.phase,
            healthy_samples=metrics.healthy_samples,
            observed_samples=metrics.observed_samples,
        )
        self.finished_slot_indexes.add(slot.index)
        self.write_live_summary()

    def run_schedule(self) -> None:
        self.verify_inventory_snapshot("qualification_start")
        self.started_monotonic = time.monotonic()
        self.started_epoch = time.time()
        self.started_utc = utc_now()
        self.completion_reason = "running"
        self.next_health_at = 0.0
        self.next_probe_at = 0.0
        self.next_counter_at = 3.0
        # Offset memory/CPU snapshots from the minute counter bridge so the
        # observer's own Activity intent does not inflate CPU samples.
        self.next_memory_at = 30.0
        self.next_exit_info_at = 0.0
        self.last_heartbeat_monotonic = 0.0
        self.shell("input", "keyevent", "KEYCODE_SLEEP", timeout=10)
        self.event("qualification_started", duration_s=self.duration_target_s)
        self.write_runner_process(completed=False)
        self.write_live_summary()

        for ordinal in range(len(self.schedule)):
            if self.stop_requested:
                break
            slot = self.schedule[ordinal]
            if (
                not slot.phase.startswith("matrix-")
                and not self.endurance_schedule_resolved
            ):
                self.verify_inventory_snapshot("matrix_complete")
                self.resolve_endurance_schedule()
                slot = self.schedule[ordinal]
            while (
                time.monotonic() - self.started_monotonic < slot.planned_start_s
                and not self.stop_requested
            ):
                self.service_due_tasks()
                self.sleep_until_next(slot.planned_start_s)
            if self.stop_requested or self.elapsed_s() >= self.duration_target_s:
                break

            self.enter_slot(slot)
            reconnect_done = False
            reconnect_due = (
                slot.planned_start_s + slot.reconnect_at_s
                if slot.reconnect_at_s is not None
                else None
            )
            while (
                time.monotonic() - self.started_monotonic < slot.planned_end_s
                and not self.stop_requested
            ):
                elapsed = time.monotonic() - self.started_monotonic
                if (
                    reconnect_due is not None
                    and not reconnect_done
                    and elapsed >= reconnect_due
                ):
                    reconnect_done = True
                    if self.slot_metrics is not None:
                        self.slot_metrics.reconnect_attempted = True
                        self.slot_metrics.reconnect_ok = self.perform_reconnect()
                    continue
                self.service_due_tasks()
                self.sleep_until_next(slot.planned_end_s)
            self.finish_slot(slot)

        if not self.stop_requested:
            self.verify_inventory_snapshot("terminal")
        if not self.stop_requested and self.elapsed_s() >= self.duration_target_s:
            self.completed = True
            self.completion_reason = "duration_reached"
        elif self.stop_requested:
            self.completion_reason = "interrupted"
        else:
            self.completion_reason = "schedule_ended_early"

    def memory_summary(self, role: str) -> dict[str, Any]:
        records = self.memory_records[role]
        by_instance: dict[tuple[int, str], list[dict[str, Any]]] = {}
        slope_limit = (
            MAIN_PSS_SLOPE_LIMIT_KB_H
            if role == "main"
            else VPN_PSS_SLOPE_LIMIT_KB_H
        )
        for record in records:
            instance = safe_int(record.get("process_instance"))
            phase = str(record.get("phase") or "")
            engine = strict_runtime(str(record.get("engine") or ""))
            if (
                instance > 0
                and safe_int(record.get("pss_kb")) >= 0
                and phase
                and phase != "preflight"
                and not phase.startswith("matrix-")
                and engine in {"singbox", "xray"}
            ):
                by_instance.setdefault((instance, engine), []).append(record)

        instance_results: list[dict[str, Any]] = []
        for (instance, engine), instance_records in sorted(by_instance.items()):
            instance_records.sort(key=lambda item: safe_int(item.get("elapsed_s")))
            started_s = safe_int(instance_records[0]["elapsed_s"])
            finished_s = safe_int(instance_records[-1]["elapsed_s"])
            warmup_cutoff_s = started_s + 1_800
            usable = [
                record
                for record in instance_records
                if safe_int(record.get("elapsed_s")) >= warmup_cutoff_s
            ]
            pss_points = [
                (safe_int(record["elapsed_s"]), safe_int(record["pss_kb"]))
                for record in usable
                if safe_int(record["pss_kb"]) >= 0
            ]
            fd_points = [
                (safe_int(record["elapsed_s"]), safe_int(record["fd_count"]))
                for record in usable
                if safe_int(record["fd_count"]) >= 0
            ]
            thread_points = [
                (safe_int(record["elapsed_s"]), safe_int(record["thread_count"]))
                for record in usable
                if safe_int(record["thread_count"]) >= 0
            ]
            max_elapsed = max((point[0] for point in pss_points), default=-1)
            first_hour = [
                point[1]
                for point in pss_points
                if warmup_cutoff_s <= point[0] < warmup_cutoff_s + 3_600
            ]
            last_hour = [
                point[1]
                for point in pss_points
                if max_elapsed >= 0 and point[0] >= max_elapsed - 3_600
            ]
            first_median = (
                float(statistics.median(first_hour)) if first_hour else -1.0
            )
            last_median = (
                float(statistics.median(last_hour)) if last_hour else -1.0
            )
            pss_growth = (
                last_median - first_median
                if first_median >= 0 and last_median >= 0
                else -1.0
            )
            pss_budget = (
                max(PSS_GROWTH_FLOOR_KB, first_median * 0.20)
                if first_median >= 0
                else -1.0
            )

            def edge_growth(
                points: Sequence[tuple[int, int]],
                floor: int,
            ) -> tuple[float, float, float]:
                if len(points) < 3:
                    return -1.0, -1.0, -1.0
                first = float(
                    statistics.median(value for _, value in points[:12])
                )
                last = float(
                    statistics.median(value for _, value in points[-12:])
                )
                return (
                    last - first,
                    max(float(floor), first * 0.20),
                    linear_slope_per_hour(points),
                )

            fd_growth, fd_budget, fd_slope = edge_growth(
                fd_points,
                FD_GROWTH_FLOOR,
            )
            thread_growth, thread_budget, thread_slope = edge_growth(
                thread_points,
                THREAD_GROWTH_FLOOR,
            )
            pss_slope = linear_slope_per_hour(pss_points)
            eligible = (
                len(pss_points) >= 60
                and finished_s - started_s >= 18_000
                and len(first_hour) >= 10
                and len(last_hour) >= 10
                and len(fd_points) >= 60
                and len(thread_points) >= 60
            )
            passed = (
                eligible
                and pss_slope <= slope_limit
                and pss_growth <= pss_budget
                and (fd_growth < 0 or fd_growth <= fd_budget)
                and (thread_growth < 0 or thread_growth <= thread_budget)
            )
            instance_results.append(
                {
                    "process_instance": instance,
                    "engine": engine,
                    "started_elapsed_s": started_s,
                    "finished_elapsed_s": finished_s,
                    "span_s": finished_s - started_s,
                    "warmup_relative_s": 1_800,
                    "samples": len(instance_records),
                    "stable_samples": len(pss_points),
                    "fd_samples": len(fd_points),
                    "fd_observed": len(fd_points) >= 3,
                    "thread_samples": len(thread_points),
                    "eligible": eligible,
                    "pss_min_kb": min(
                        (point[1] for point in pss_points),
                        default=-1,
                    ),
                    "pss_max_kb": max(
                        (point[1] for point in pss_points),
                        default=-1,
                    ),
                    "pss_slope_kb_per_hour": round(pss_slope, 2),
                    "pss_slope_limit_kb_per_hour": slope_limit,
                    "first_stable_hour_median_pss_kb": round(first_median, 2),
                    "last_hour_median_pss_kb": round(last_median, 2),
                    "pss_growth_kb": round(pss_growth, 2),
                    "pss_growth_budget_kb": round(pss_budget, 2),
                    "fd_growth": round(fd_growth, 2),
                    "fd_growth_budget": round(fd_budget, 2),
                    "fd_slope_per_hour": round(fd_slope, 2),
                    "thread_growth": round(thread_growth, 2),
                    "thread_growth_budget": round(thread_budget, 2),
                    "thread_slope_per_hour": round(thread_slope, 2),
                    "pass": passed if eligible else None,
                }
            )

        eligible_results = [
            result for result in instance_results if bool(result["eligible"])
        ]
        selected_tokens = set(self.endurance_profiles.values())
        required_engines = {
            self.profile_by_token[token].runtime
            for token in selected_tokens
            if token in self.profile_by_token
        }
        if not required_engines and self.completed:
            required_engines = {"singbox", "xray"}
        covered_engines = {result["engine"] for result in eligible_results}
        engine_instance_counts = {
            engine: len(
                {
                    result["process_instance"]
                    for result in instance_results
                    if result["engine"] == engine
                }
            )
            for engine in {"singbox", "xray"}
        }
        failed_instances = [
            {
                "process_instance": result["process_instance"],
                "engine": result["engine"],
            }
            for result in eligible_results
            if result["pass"] is not True
        ]
        passed = (
            bool(required_engines)
            and required_engines.issubset(covered_engines)
            and bool(eligible_results)
            and not failed_instances
            and all(
                engine_instance_counts.get(engine) == 1
                for engine in required_engines
            )
        )
        return {
            "samples": len(records),
            "process_instances": len(self.process_instances[role]),
            "required_engines": sorted(required_engines),
            "covered_engines": sorted(covered_engines),
            "engine_instance_counts": engine_instance_counts,
            "required_stable_samples_per_engine": 60,
            "required_span_s_per_engine": 18_000,
            "eligible_instances": len(eligible_results),
            "failed_instances": failed_instances,
            "instances": instance_results,
            "pass": passed,
        }

    def transition_summary(
        self,
        records: Sequence[Mapping[str, Any]],
        *,
        max_sla_ms: int,
        p95_sla_ms: int,
    ) -> dict[str, Any]:
        qualifying = [
            record for record in records if bool(record.get("_qualifying", True))
        ]
        successful = [
            record
            for record in qualifying
            if bool(record.get("ready"))
            and bool(record.get("tcp_ok"))
            and bool(record.get("https_ok"))
            and not record.get("error_code")
        ]
        failed = [record for record in qualifying if record not in successful]
        observer_failed = [
            record for record in failed if transition_error_is_observer_only(record)
        ]
        confirmed_failed = [
            record for record in failed if record not in observer_failed
        ]
        measured = [
            record for record in qualifying if record not in observer_failed
        ]
        durations = [float(record["duration_ms"]) for record in measured]
        p95 = percentile(durations, 0.95)
        maximum = max(durations, default=-1.0)
        return {
            "attempts": len(qualifying),
            "measured_attempts": len(measured),
            "successful": len(successful),
            "failed": len(failed),
            "observer_failed": len(observer_failed),
            "confirmed_failed": len(confirmed_failed),
            "p50_ms": round(percentile(durations, 0.50), 2),
            "p95_ms": round(p95, 2),
            "max_ms": round(maximum, 2),
            "p95_sla_ms": p95_sla_ms,
            "max_sla_ms": max_sla_ms,
            "pass": (
                bool(qualifying)
                and len(successful) == len(qualifying)
                and p95 <= p95_sla_ms
                and maximum <= max_sla_ms
            ),
        }

    def optimization_summary(self) -> dict[str, Any]:
        records = self.memory_records["main"]
        wakelock_records = [
            record
            for record in records
            if record.get("app_partial_wakelocks_observed") is True
            and safe_int(record.get("app_partial_wakelocks")) >= 0
        ]
        wakelock_samples = sum(
            safe_int(record.get("app_partial_wakelocks"), 0) > 0
            for record in wakelock_records
        )
        interactive_samples = sum(
            record.get("screen_interactive") is True for record in records
        )
        wake_ratio = (
            wakelock_samples / len(wakelock_records)
            if wakelock_records
            else -1.0
        )
        wakelock_observer_coverage = (
            len(wakelock_records) / len(records) if records else 0.0
        )
        cpu_by_role: dict[str, dict[str, float]] = {}
        for role, role_records in self.memory_records.items():
            cpu = [
                float(record["cpu_percent"])
                for record in role_records
                if float(record.get("cpu_percent", -1)) >= 0
            ]
            cpu_by_role[role] = {
                "samples": len(cpu),
                "median_percent": round(percentile(cpu, 0.50), 2),
                "p95_percent": round(percentile(cpu, 0.95), 2),
                "max_percent": round(max(cpu, default=-1.0), 2),
                "p95_limit_percent": (
                    MAIN_CPU_P95_LIMIT_PERCENT
                    if role == "main"
                    else VPN_CPU_P95_LIMIT_PERCENT
                ),
                "pass": (
                    len(cpu) >= 12
                    and percentile(cpu, 0.95)
                    <= (
                        MAIN_CPU_P95_LIMIT_PERCENT
                        if role == "main"
                        else VPN_CPU_P95_LIMIT_PERCENT
                    )
                ),
            }
        battery_levels = [
            safe_int(record.get("battery_level"))
            for record in records
            if safe_int(record.get("battery_level")) >= 0
        ]
        temperatures = [
            float(record["battery_temp_c"])
            for record in records
            if float(record.get("battery_temp_c", -1)) >= 0
        ]
        temperature_max = max(temperatures, default=-1.0)
        thermal_pass = bool(temperatures) and (
            temperature_max <= BATTERY_TEMPERATURE_LIMIT_C
        )
        return {
            "samples": len(records),
            "partial_wakelock_held_samples": wakelock_samples,
            "partial_wakelock_held_ratio": round(wake_ratio, 4),
            "partial_wakelock_ratio_limit": 0.10,
            "partial_wakelock_observed_samples": len(wakelock_records),
            "partial_wakelock_observer_coverage_ratio": round(
                wakelock_observer_coverage,
                6,
            ),
            "screen_interactive_samples": interactive_samples,
            "battery_level_start": battery_levels[0] if battery_levels else -1,
            "battery_level_end": battery_levels[-1] if battery_levels else -1,
            "battery_temperature_max_c": round(temperature_max, 1),
            "battery_temperature_limit_c": BATTERY_TEMPERATURE_LIMIT_C,
            "thermal_pass": thermal_pass,
            "cpu": cpu_by_role,
            "pass": (
                bool(records)
                and wakelock_observer_coverage >= OBSERVER_COVERAGE_MIN
                and wake_ratio <= 0.10
                and thermal_pass
                and cpu_by_role["main"]["pass"]
                and cpu_by_role["vpn"]["pass"]
            ),
        }

    def summary(self) -> dict[str, Any]:
        qualifying_switches = [
            record
            for record in self.switch_records
            if bool(record.get("_qualifying", True))
        ]
        activate_records = [
            record for record in qualifying_switches if record["kind"] == "activate"
        ]
        reconnect_records = [
            record for record in qualifying_switches if record["kind"] == "reconnect"
        ]
        handover_records = [
            record
            for record in self.handover_records
            if bool(record.get("_qualifying", True))
        ]
        switches = self.transition_summary(
            activate_records,
            max_sla_ms=SWITCH_MAX_SLA_MS,
            p95_sla_ms=SWITCH_P95_SLA_MS,
        )
        reconnects = self.transition_summary(
            reconnect_records,
            max_sla_ms=SWITCH_MAX_SLA_MS,
            p95_sla_ms=SWITCH_P95_SLA_MS,
        )
        handovers = self.transition_summary(
            handover_records,
            max_sla_ms=HANDOVER_MAX_SLA_MS,
            p95_sla_ms=HANDOVER_P95_SLA_MS,
        )
        handover_coverage = dedicated_handover_coverage(
            self.schedule,
            handover_records,
        )
        handovers["dedicated_coverage"] = handover_coverage
        main_memory = self.memory_summary("main")
        vpn_memory = self.memory_summary("vpn")
        optimization = self.optimization_summary()
        measured_resource_failure = has_measured_resource_failure(
            main_memory,
            vpn_memory,
            optimization,
        )
        matrix_pairs = {
            (record["profile_token"], record["network"])
            for record in self.matrix_records
            if bool(record["coverage_ok"])
        }
        expected_pairs = {
            (profile.token, network)
            for profile in self.profiles
            for network in ("cellular", "wifi")
        }
        expected_matrix_cells = self.inventory_snapshot_count * 2
        inventory_snapshot_valid = (
            self.inventory_snapshot_locked
            and self.inventory_snapshot_count > 0
            and self.inventory_snapshot_count == len(self.profiles)
            and self.inventory_snapshot_sha256
            == inventory_snapshot_sha256(self.profiles)
        )
        matrix_pass = (
            inventory_snapshot_valid
            and self.inventory_requirement_met
            and not self.inventory_drift_detected
            and len(self.matrix_records) == expected_matrix_cells
            and matrix_pairs == expected_pairs
        )
        confirmed_app_issues = sum(
            count
            for issue, count in self.confirmed_issue_counts.items()
            if issue != "observer_unavailable"
            and not issue.endswith("_observer_unavailable")
        )
        confirmed_observer_issues = sum(
            count
            for issue, count in self.confirmed_issue_counts.items()
            if issue == "observer_unavailable"
            or issue.endswith("_observer_unavailable")
        )
        definitive_count = sum(self.definitive_failures.values())
        confirmed_transition_failure = any(
            transition_has_confirmed_failure(transition)
            for transition in (switches, reconnects, handovers)
        )
        confirmed_app_failure = (
            definitive_count > 0
            or confirmed_app_issues > 0
            or confirmed_transition_failure
            or measured_resource_failure
        )
        observed_health_samples = max(
            0,
            self.health_samples - self.observer_unknown_samples,
        )
        health_rate = (
            self.healthy_samples / observed_health_samples
            if observed_health_samples
            else 0.0
        )
        observer_coverage = (
            observed_health_samples / self.health_samples
            if self.health_samples
            else 0.0
        )
        isolation_pass = (
            self.isolation_evidence.get("singbox") is True
            and self.isolation_evidence.get("xray") is True
        )
        all_slots_finished = bool(self.schedule) and (
            len(self.finished_slot_indexes) == len(self.schedule)
        )
        health_cadence = self.health_cadence_summary()
        counter_coverage = self.counter_coverage_summary()
        observation_gates = observation_quality_gates(
            tcp_failures=self.tcp_failures,
            https_failures=self.https_failures,
            counter_stalls=self.counter_stalls,
            counter_resets=self.counter_resets,
        )
        confirmed_app_failure = (
            confirmed_app_failure or not all(observation_gates.values())
        )
        transition_observer_failures = sum(
            safe_int(transition.get("observer_failed"), 0)
            for transition in (switches, reconnects, handovers)
        )
        app_gates = {
            "duration_complete": (
                self.completed and self.elapsed_s() >= self.duration_target_s
            ),
            "all_schedule_slots_finished": all_slots_finished,
            "inventory_snapshot_valid": inventory_snapshot_valid,
            "inventory_count_requirement": self.inventory_requirement_met,
            "inventory_immutable": not self.inventory_drift_detected,
            "profile_matrix": matrix_pass,
            "profile_switch_sla": bool(switches["pass"]),
            "reconnect_sla": bool(reconnects["pass"]),
            "network_handover_sla": (
                bool(handovers["pass"])
                and bool(handover_coverage["pass"])
            ),
            "no_definitive_process_failures": definitive_count == 0,
            "no_confirmed_app_issues": confirmed_app_issues == 0,
            "observed_health_rate": health_rate >= 0.995,
            "counter_observer_coverage": (
                counter_coverage["eligible_expected_ticks"] > 0
                and counter_coverage["observed_ratio"] >= 0.99
            ),
            "main_memory": bool(main_memory["pass"]),
            "vpn_memory": bool(vpn_memory["pass"]),
            "optimization": bool(optimization["pass"]),
            "runtime_isolation": isolation_pass,
            **observation_gates,
        }
        observer_gates = {
            "device_clock_integrity": self.device_clock_failures == 0,
            "observer_coverage": observer_coverage >= OBSERVER_COVERAGE_MIN,
            "observer_max_unknown_streak": (
                self.observer_max_unknown_streak_s
                <= OBSERVER_MAX_UNKNOWN_STREAK_S
            ),
            "health_sampling_cadence": bool(health_cadence["pass"]),
            "counter_sampling_cadence": (
                counter_coverage["expected_ticks"] > 0
                and counter_coverage["attempted_ratio"] >= 0.99
            ),
            "wakelock_observer_coverage": (
                optimization["partial_wakelock_observer_coverage_ratio"]
                >= OBSERVER_COVERAGE_MIN
            ),
            "no_confirmed_observer_issues": confirmed_observer_issues == 0,
            "transition_observer_integrity": transition_observer_failures == 0,
            "exit_transition_boundary_integrity": (
                self.exit_transition_boundary_observer_failures == 0
            ),
            "inventory_terminal_verification": (
                self.inventory_final_verification_observed
            ),
        }
        verdict_gates = {**app_gates, **observer_gates}
        observer_blocked = self.completed and not all(observer_gates.values())
        app_pass = all(app_gates.values())
        if not self.completed:
            qualification_status = (
                "incomplete" if self.finished_utc else "running"
            )
            qualification_pass: bool | None = None
        elif confirmed_app_failure:
            qualification_status = "failed"
            qualification_pass = False
        elif observer_blocked:
            qualification_status = "inconclusive"
            qualification_pass = None
        elif app_pass:
            qualification_status = "passed"
            qualification_pass = True
        else:
            qualification_status = "failed"
            qualification_pass = False
        return {
            "schema_version": 2,
            "completed": self.completed,
            "pass": qualification_pass,
            "qualification_status": qualification_status,
            "completion_reason": self.completion_reason,
            "started_utc": self.started_utc or None,
            "finished_utc": self.finished_utc or None,
            "duration_target_s": self.duration_target_s,
            "duration_hours": self.duration_hours,
            "device_clock_failures": self.device_clock_failures,
            "elapsed_s": self.elapsed_s(),
            "verdict": {
                "gates": verdict_gates,
                "app_gates": app_gates,
                "observer_gates": observer_gates,
                "confirmed_app_failure": confirmed_app_failure,
                "measured_resource_failure": measured_resource_failure,
                "observer_degradation_present": observer_blocked,
                "blocked_by_observer": (
                    observer_blocked and not confirmed_app_failure
                ),
                "failed_gates": [
                    gate for gate, passed in verdict_gates.items() if not passed
                ],
                "isolated_failure_tolerance": {
                    "tcp": MAX_ISOLATED_PROBE_FAILURES,
                    "https": MAX_ISOLATED_PROBE_FAILURES,
                    "counter_stalls": MAX_ISOLATED_COUNTER_STALLS,
                    "counter_resets": 0,
                    "rationale": (
                        "one isolated observation remains suspect; repeated, "
                        "alternating, or systematic failures cannot pass"
                    ),
                },
            },
            "current": {
                "slot_index": self.current_slot.index if self.current_slot else -1,
                "phase": self.current_slot.phase if self.current_slot else "preflight",
                "profile_token": (
                    self.current_profile.token if self.current_profile else ""
                ),
                "engine": (
                    self.current_profile.engine if self.current_profile else "unknown"
                ),
                "network": self.current_network,
                "expected_network": self.current_network,
                "observed_network": self.last_observed_network,
                "network_observation_fresh": self.last_network_observation_fresh,
                "last_health": self.last_health_summary,
            },
            "inventory": {
                "mode": (
                    "strict_expected"
                    if self.expected_profile_count is not None
                    else "observed_snapshot"
                ),
                "requested_expected": self.expected_profile_count,
                "observed": self.inventory_snapshot_count,
                "runnable": self.inventory_snapshot_count,
                "snapshot_sha256": self.inventory_snapshot_sha256,
                "snapshot_locked": self.inventory_snapshot_locked,
                "snapshot_valid": inventory_snapshot_valid,
                "count_requirement_met": self.inventory_requirement_met,
                "drift_detected": self.inventory_drift_detected,
                "verification_attempts": self.inventory_verification_attempts,
                "verification_observed": self.inventory_verification_observed,
                "final_verification_observed": (
                    self.inventory_final_verification_observed
                ),
                "last_verification_error": self.inventory_last_verification_error,
            },
            "schedule": {
                "slots_total": len(self.schedule),
                "slots_finished": len(self.finished_slot_indexes),
                "all_slots_finished": all_slots_finished,
                "endurance_resolved": self.endurance_schedule_resolved,
                "endurance_profiles": self.endurance_profiles,
                "phase_health": self.phase_health,
            },
            "profile_matrix": {
                "expected_cells": expected_matrix_cells,
                "completed_cells": len(self.matrix_records),
                "passing_cells": len(matrix_pairs),
                "cellular_profiles_passing": len(
                    {
                        token
                        for token, network in matrix_pairs
                        if network == "cellular"
                    }
                ),
                "wifi_profiles_passing": len(
                    {token for token, network in matrix_pairs if network == "wifi"}
                ),
                "pass": matrix_pass,
            },
            "switches": switches,
            "reconnects": reconnects,
            "handovers": handovers,
            "health": {
                "samples": self.health_samples,
                "healthy": self.healthy_samples,
                "healthy_ratio": round(health_rate, 6),
                "observer_unknown": self.observer_unknown_samples,
                "observer_coverage_ratio": round(observer_coverage, 6),
                "observer_max_unknown_streak_s": round(
                    self.observer_max_unknown_streak_s,
                    3,
                ),
                "cadence": health_cadence,
                "confirmed_app_issues": confirmed_app_issues,
                "confirmed_observer_issues": confirmed_observer_issues,
                "exit_transition_boundary_observer_failures": (
                    self.exit_transition_boundary_observer_failures
                ),
                "issue_counts": self.confirmed_issue_counts,
            },
            "probes": {
                "samples": self.probe_samples,
                "tcp_failures": self.tcp_failures,
                "https_failures": self.https_failures,
            },
            "counters": {
                "samples": self.counter_samples,
                "observed_samples": self.counter_observed_samples,
                **counter_coverage,
                "stalled_observations": self.counter_stalls,
                "reset_observations": self.counter_resets,
                "confirmed_stall_incidents": self.confirmed_issue_counts.get(
                    "traffic_counter_stalled",
                    0,
                ),
            },
            "runtime_isolation": {
                "singbox_safe": self.isolation_evidence.get("singbox"),
                "xray_safe": self.isolation_evidence.get("xray"),
                "pass": isolation_pass,
            },
            "process_exit_evidence": {
                **self.definitive_failures,
                "total_failures": definitive_count,
                "baseline_entries": len(self.baseline_exit_ids),
                "new_entries": len(self.seen_exit_ids - self.baseline_exit_ids),
            },
            "memory": {
                "main": main_memory,
                "vpn": vpn_memory,
            },
            "optimization": optimization,
            "incidents": {
                "count": len(self.incidents),
                "items": self.incidents[-100:],
            },
            "runner_errors": self.runner_errors[-20:],
            "raw_profile_data_persisted": False,
            "raw_adb_diagnostics_persisted": False,
            "automatic_recovery_attempts": 0,
            "foreground_bridge_fallbacks": self.bridge_foreground_fallbacks,
            "checkpoint_resume": {
                "supported": False,
                "policy": "new_run_required_after_host_interruption",
            },
        }

    def write_live_summary(self) -> None:
        self.atomic_json("summary-live.json", self.summary())

    def write_heartbeat(self, force: bool = False) -> None:
        if not self.output_writable:
            return
        now = time.monotonic()
        if (
            not force
            and self.last_heartbeat_monotonic > 0
            and now - self.last_heartbeat_monotonic < HEARTBEAT_INTERVAL_S
        ):
            return
        self.last_heartbeat_monotonic = now
        self.atomic_json(
            "heartbeat.json",
            {
                "timestamp_utc": utc_now(),
                "elapsed_s": self.elapsed_s(),
                "duration_target_s": self.duration_target_s,
                "duration_hours": self.duration_hours,
                "completed": self.completed,
                "runner_pid": os.getpid(),
                "inventory_snapshot_count": self.inventory_snapshot_count,
                "inventory_snapshot_sha256": self.inventory_snapshot_sha256,
                "inventory_drift_detected": self.inventory_drift_detected,
                "device_observed": self.last_device_observed,
                "phase": self.current_slot.phase if self.current_slot else "preflight",
                "slot_index": self.current_slot.index if self.current_slot else -1,
                "profile_token": (
                    self.current_profile.token if self.current_profile else ""
                ),
                "engine": (
                    self.current_profile.engine if self.current_profile else "unknown"
                ),
                "network": self.current_network,
                "expected_network": self.current_network,
                "observed_network": self.last_observed_network,
                "network_observation_fresh": self.last_network_observation_fresh,
                "network_verified": (
                    self.last_network_observation_fresh
                    and self.last_observed_network == self.current_network
                    and self.last_observed_network in {"cellular", "wifi"}
                ),
                "vpn_validated": self.last_health_summary.get(
                    "vpn_validated",
                    False,
                ),
                "tcp_failures": self.tcp_failures,
                "https_failures": self.https_failures,
                "confirmed_incidents": len(self.incidents),
                "automatic_recovery_attempts": 0,
                "host_keep_awake_active": self.host_keep_awake_active,
                "foreground_bridge_fallbacks": self.bridge_foreground_fallbacks,
                "checkpoint_resume_supported": False,
            },
        )

    def write_runner_process(self, completed: bool) -> None:
        payload: dict[str, Any] = {
            "pid": os.getpid(),
            "started_utc": self.started_utc or None,
            "completed": completed,
            "duration_hours": self.duration_hours,
            "duration_target_s": self.duration_target_s,
            "expected_profile_count": self.expected_profile_count,
            "inventory_snapshot_count": self.inventory_snapshot_count,
            "inventory_snapshot_sha256": self.inventory_snapshot_sha256,
            "checkpoint_resume_supported": False,
        }
        if completed or self.finished_utc:
            payload["finished_utc"] = self.finished_utc or utc_now()
        self.atomic_json("runner-process.json", payload)

    def package_version(self) -> dict[str, Any]:
        result, error = self.shell("dumpsys", "package", PACKAGE, timeout=45)
        if error or result is None:
            return {"version_name": "unknown", "version_code": -1}
        name_match = re.search(r"\bversionName=([A-Za-z0-9_.-]+)", result.stdout)
        code_match = re.search(r"\bversionCode=(\d+)", result.stdout)
        return {
            "version_name": (
                safe_enum(name_match.group(1)) if name_match else "unknown"
            ),
            "version_code": int(code_match.group(1)) if code_match else -1,
        }

    def write_manifest_and_schedule(self) -> None:
        if self.plan is None or not self.inventory_snapshot_locked:
            raise RuntimeError("inventory_snapshot_not_locked")
        schedule_payload = {
            "schema_version": 2,
            "duration_s": self.duration_target_s,
            "duration_hours": self.duration_hours,
            "inventory_snapshot_sha256": self.inventory_snapshot_sha256,
            "matrix": {
                "profile_count": self.inventory_snapshot_count,
                "networks": ["cellular", "wifi"],
                "slot_duration_s": MATRIX_SLOT_S,
                "reconnect_at_s": MATRIX_RECONNECT_AT_S,
                "cells": self.inventory_snapshot_count * 2,
            },
            "endurance": {
                "singbox_cellular_s": self.plan.engine_dwell_s,
                "xray_wifi_s": self.plan.engine_dwell_s,
                "xray_handover_segment_durations_s": list(
                    self.plan.handover_segment_durations_s
                ),
                "xray_handover_segments": len(
                    self.plan.handover_segment_durations_s
                ),
            },
            "slots": [asdict(slot) for slot in self.schedule],
        }
        serialized_schedule = json.dumps(
            schedule_payload,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        self.atomic_json("schedule.json", schedule_payload)
        self.atomic_json(
            "manifest-sanitized.json",
            {
                "schema_version": 2,
                "runner": "yurich_android_vpn_soak_matrix",
                "package": PACKAGE,
                "build_variant": "soak",
                "package_version": self.package_version(),
                "device": {
                    "opaque_token": opaque_device_token(self.serial),
                    "manufacturer": self.read_property("ro.product.manufacturer"),
                    "model": self.read_property("ro.product.model"),
                    "android_release": self.read_property("ro.build.version.release"),
                    "sdk": safe_int(
                        self.read_property("ro.build.version.sdk"),
                    ),
                    "serial_persisted": False,
                },
                "qualification_duration_s": self.duration_target_s,
                "qualification_duration_hours": self.duration_hours,
                "inventory": {
                    "mode": (
                        "strict_expected"
                        if self.expected_profile_count is not None
                        else "observed_snapshot"
                    ),
                    "requested_expected_count": self.expected_profile_count,
                    "count": self.inventory_snapshot_count,
                    "runnable_count": self.inventory_snapshot_count,
                    "count_requirement_met": self.inventory_requirement_met,
                    "snapshot_sha256": self.inventory_snapshot_sha256,
                    "snapshot_locked": self.inventory_snapshot_locked,
                    "profiles": [asdict(profile) for profile in self.profiles],
                },
                "initial_device_state": {
                    "wifi_enabled": self.initial_wifi_enabled,
                    "mobile_data_enabled": self.initial_mobile_enabled,
                    "screen_interactive": self.initial_screen_interactive,
                },
                "intervals_s": {
                    "health": HEALTH_INTERVAL_S,
                    "probes": PROBE_INTERVAL_S,
                    "counters": COUNTER_INTERVAL_S,
                    "counter_baseline_grace": COUNTER_BASELINE_GRACE_S,
                    "memory": MEMORY_INTERVAL_S,
                    "exit_info": EXIT_INFO_INTERVAL_S,
                    "heartbeat": HEARTBEAT_INTERVAL_S,
                },
                "thresholds": {
                    "observation_confirmation_count": 2,
                    "switch_p95_ms": SWITCH_P95_SLA_MS,
                    "switch_max_ms": SWITCH_MAX_SLA_MS,
                    "handover_p95_ms": HANDOVER_P95_SLA_MS,
                    "handover_max_ms": HANDOVER_MAX_SLA_MS,
                    "main_pss_slope_kb_per_hour": MAIN_PSS_SLOPE_LIMIT_KB_H,
                    "vpn_pss_slope_kb_per_hour": VPN_PSS_SLOPE_LIMIT_KB_H,
                    "pss_last_vs_first_growth_percent": 20,
                    "pss_growth_floor_kb": PSS_GROWTH_FLOOR_KB,
                    "max_isolated_tcp_failures": MAX_ISOLATED_PROBE_FAILURES,
                    "max_isolated_https_failures": MAX_ISOLATED_PROBE_FAILURES,
                    "max_isolated_counter_stalls": MAX_ISOLATED_COUNTER_STALLS,
                    "max_counter_resets": 0,
                    "observer_coverage_min": OBSERVER_COVERAGE_MIN,
                    "sampling_cadence_coverage_min": OBSERVER_COVERAGE_MIN,
                    "observer_max_unknown_streak_s": (
                        OBSERVER_MAX_UNKNOWN_STREAK_S
                    ),
                },
                "probe_ids": [
                    "tcp_public_443",
                    "https_payload_primary",
                    "https_204_fallback",
                ],
                "schedule_sha256": hashlib.sha256(
                    serialized_schedule.encode("utf-8")
                ).hexdigest(),
                "privacy": {
                    "profile_names": False,
                    "profile_ids": False,
                    "profile_endpoints": False,
                    "profile_configs": False,
                    "ssid_bssid_ip": False,
                    "raw_dumpsys": False,
                    "raw_logcat": False,
                    "raw_command_errors": False,
                },
                "automatic_recovery_policy": "disabled",
                "checkpoint_resume": {
                    "supported": False,
                    "policy": "new_run_required_after_host_interruption",
                    "reason": "strict_continuity_cannot_be_reconstructed_safely",
                },
                "counter_observer": {
                    "interval_s": COUNTER_INTERVAL_S,
                    "source": "passive_sanitized_app_telemetry",
                    "tag": SOAK_TAG,
                    "host_broadcasts_per_interval": 0,
                    "starts_or_foregrounds_activity": False,
                    "raw_logcat_persisted": False,
                    "fields": [
                        "opaque_profile_token",
                        "session_generation",
                        "native_bytes",
                        "display_bytes",
                        "generation_changed",
                        "native_delta",
                        "display_delta",
                        "counter_reset",
                        "counter_stalled",
                        "baseline_pending",
                        "baseline_grace",
                    ],
                },
                "host_keep_awake": {
                    "scope": "runner_process",
                    "system_required": self.host_keep_awake_active,
                    "display_required": False,
                },
            },
        )

    def ensure_output_is_safe(self) -> None:
        self.out_dir.mkdir(parents=True, exist_ok=True)
        conflicts = (
            "manifest-sanitized.json",
            "schedule.json",
            "inventory-snapshot.json",
            "summary.json",
            "events.jsonl",
            "samples.csv",
        )
        if any((self.out_dir / name).exists() for name in conflicts):
            raise RuntimeError("output_directory_contains_prior_run")
        self.output_writable = True

    def run(self) -> int:
        signal.signal(signal.SIGINT, self.request_stop)
        if hasattr(signal, "SIGTERM"):
            signal.signal(signal.SIGTERM, self.request_stop)
        try:
            self.ensure_output_is_safe()
            self.write_runner_process(completed=False)
            if not self.set_host_keep_awake(True):
                raise RuntimeError("host_keep_awake_unavailable")
            self.event("host_keep_awake_enabled", active=True)
            if not Path(self.adb).is_file():
                raise RuntimeError("adb_not_found")
            if not self.device_available():
                raise RuntimeError("device_unavailable")

            wifi = self.detect_wifi_enabled()
            mobile = self.detect_mobile_enabled()
            interactive = self.screen_interactive()
            if wifi is None or mobile is None or interactive is None:
                raise RuntimeError("device_state_baseline_unavailable")
            self.initial_wifi_enabled = wifi
            self.initial_mobile_enabled = mobile
            self.initial_screen_interactive = interactive
            self.radio_baseline_observed = True
            self.diagnostic_started_device_local = self.device_local_timestamp()
            if not self.diagnostic_started_device_local:
                raise RuntimeError("device_time_baseline_unavailable")
            self.write_exit_baseline()
            self.load_inventory()
            self.observe_initial_profile()
            self.write_manifest_and_schedule()
            self.event(
                "preflight_started",
                profile_count=len(self.profiles),
            )
            self.preflight()
            if self.stop_requested:
                self.completion_reason = "interrupted"
            else:
                self.baseline_passive_counters()
                self.run_schedule()
        except RuntimeError as error:
            code = str(error)
            safe_code = code if ENUM_RE.fullmatch(code) else "runner_preflight_error"
            self.runner_errors.append(safe_code)
            self.completion_reason = (
                "interrupted" if self.stop_requested else safe_code
            )
            self.event("runner_error", code=safe_code)
        except Exception:
            self.runner_errors.append("unexpected_runner_exception")
            self.completion_reason = (
                "interrupted" if self.stop_requested else "unexpected_runner_exception"
            )
            self.event("runner_error", code="unexpected_runner_exception")
        finally:
            if self.output_writable:
                if self.last_device_observed or self.device_available():
                    if self.started_monotonic > 0:
                        self.health_tick()
                        self.probe_tick("final")
                        self.memory_tick()
                    self.scan_exit_info()
                    self.scan_runtime_isolation()
                self.finished_utc = utc_now()
                self.restore_device_state()
                self.write_live_summary()
                self.atomic_json("summary.json", self.summary())
                self.write_heartbeat(force=True)
                self.write_runner_process(completed=self.completed)
                self.event(
                    "runner_finished",
                    completed=self.completed,
                    result=self.summary().get("qualification_status", "incomplete"),
                )
            if self.host_keep_awake_active:
                restored = self.set_host_keep_awake(False)
                self.event("host_keep_awake_restored", ok=restored)

        final = self.summary()
        print(
            "SOAK24_COMPLETE "
            f"completed={final['completed']} pass={final['pass']} "
            f"status={final['qualification_status']} "
            f"elapsed={final['elapsed_s']} incidents={final['incidents']['count']} "
            f"reason={final['completion_reason']}",
            flush=True,
        )
        if final["completed"] and final["pass"] is True:
            return 0
        if final["completed"] and final["pass"] is None:
            return 5
        if final["completed"]:
            return 4
        return 2


def self_test() -> None:
    reference_profile_count = REFERENCE_PROFILE_COUNT
    profiles = [
        Profile(
            token=f"p{index:04d}",
            kind=(
                "vlessXhttp"
                if index in {12, 15, 18}
                else ("naive" if index <= 5 else "hysteria2")
            ),
            engine="xray" if index in {12, 15, 18} else "singBox",
        )
        for index in range(1, reference_profile_count + 1)
    ]
    assert not profile_switch_requires_clean_process(None, profiles[0])
    assert not profile_switch_requires_clean_process(profiles[0], profiles[1])
    assert profile_switch_requires_clean_process(profiles[0], profiles[11])
    assert profile_switch_requires_clean_process(profiles[11], profiles[0])
    plan_24h = qualification_plan(24, len(profiles))
    schedule = build_schedule(profiles, plan_24h)
    assert len(schedule) == 41
    assert schedule[-1].planned_end_s == 86_400
    matrix = [slot for slot in schedule if slot.phase.startswith("matrix-")]
    assert len(matrix) == reference_profile_count * 2
    assert {
        slot.profile_token for slot in matrix if slot.network == "cellular"
    } == {profile.token for profile in profiles}
    assert {
        slot.profile_token for slot in matrix if slot.network == "wifi"
    } == {profile.token for profile in profiles}
    assert all(slot.reconnect_at_s == MATRIX_RECONNECT_AT_S for slot in matrix)
    handover_slots = [
        slot for slot in schedule if slot.phase.startswith("handover-")
    ]
    assert len(handover_slots) == 3
    missing_handover_coverage = dedicated_handover_coverage(schedule, [])
    assert missing_handover_coverage["pass"] is False
    complete_handover_coverage = dedicated_handover_coverage(
        schedule,
        [
            {"slot_index": slot.index, "phase": slot.phase}
            for slot in handover_slots
        ],
    )
    assert complete_handover_coverage["pass"] is True
    assert complete_handover_coverage["observed_dedicated_slots"] == 3

    dynamic_profiles = tuple(
        Profile(
            token=f"p{index:04d}",
            kind="vlessXhttp" if index in {7, 8} else "hysteria2",
            engine="xray" if index in {7, 8} else "singBox",
        )
        for index in range(1, 9)
    )
    dynamic_plan_24h = qualification_plan(24, len(dynamic_profiles))
    dynamic_schedule_24h = build_schedule(dynamic_profiles, dynamic_plan_24h)
    dynamic_matrix = [
        slot
        for slot in dynamic_schedule_24h
        if slot.phase.startswith("matrix-")
    ]
    assert len(dynamic_matrix) == 16
    assert dynamic_plan_24h.matrix_duration_s == 9_600
    assert dynamic_plan_24h.engine_dwell_s == 25_600
    assert dynamic_plan_24h.handover_segment_durations_s == (8_533, 8_533, 8_534)
    assert dynamic_schedule_24h[-1].planned_end_s == 86_400
    assert all(
        current.planned_end_s == following.planned_start_s
        for current, following in zip(
            dynamic_schedule_24h,
            dynamic_schedule_24h[1:],
        )
    )

    dynamic_payload = {
        "ok": True,
        "count": len(dynamic_profiles),
        "profiles": [
            {
                "profileToken": profile.token,
                "kind": profile.kind,
                "engine": profile.engine,
                "runnable": True,
            }
            for profile in dynamic_profiles
        ],
    }
    dynamic_runner = SoakRunner("adb", "serial", Path("unused"))
    dynamic_snapshot_writes: list[tuple[str, Mapping[str, Any]]] = []
    dynamic_runner.atomic_json = (  # type: ignore[method-assign]
        lambda name, payload: dynamic_snapshot_writes.append((name, payload))
    )
    dynamic_runner.bridge_request = (  # type: ignore[method-assign]
        lambda command: (dynamic_payload, "")
    )
    dynamic_runner.load_inventory()
    assert dynamic_runner.inventory_snapshot_locked
    assert dynamic_runner.inventory_snapshot_count == 8
    assert len(dynamic_runner.schedule) == 21
    assert dynamic_snapshot_writes[0][0] == "inventory-snapshot.json"
    assert dynamic_snapshot_writes[0][1]["observed_count"] == 8
    assert dynamic_snapshot_writes[0][1]["count_requirement_met"] is True
    assert len(dynamic_runner.inventory_snapshot_sha256) == 64
    assert inventory_snapshot_sha256(dynamic_profiles) == (
        dynamic_runner.inventory_snapshot_sha256
    )
    assert inventory_snapshot_sha256(tuple(reversed(dynamic_profiles))) != (
        dynamic_runner.inventory_snapshot_sha256
    )

    dynamic_runner.matrix_records = [
        {
            "profile_token": profile.token,
            "network": network,
            "coverage_ok": True,
        }
        for profile in dynamic_profiles
        for network in ("cellular", "wifi")
    ]
    dynamic_matrix_summary = dynamic_runner.summary()["profile_matrix"]
    assert dynamic_matrix_summary["expected_cells"] == 16
    assert dynamic_matrix_summary["pass"] is True
    dynamic_runner.matrix_records[-1] = dynamic_runner.matrix_records[0].copy()
    assert dynamic_runner.summary()["profile_matrix"]["pass"] is False
    dynamic_runner.matrix_records = [
        {
            "profile_token": profile.token,
            "network": network,
            "coverage_ok": True,
        }
        for profile in dynamic_profiles
        for network in ("cellular", "wifi")
    ]
    assert dynamic_runner.verify_inventory_snapshot("terminal") is True
    assert dynamic_runner.inventory_final_verification_observed
    drift_payload = {
        **dynamic_payload,
        "profiles": [dict(profile) for profile in dynamic_payload["profiles"]],
    }
    drift_payload["profiles"][0]["kind"] = "naive"
    dynamic_runner.bridge_request = (  # type: ignore[method-assign]
        lambda command: (drift_payload, "")
    )
    dynamic_runner.capture_incident = (  # type: ignore[method-assign]
        lambda **kwargs: None
    )
    assert dynamic_runner.verify_inventory_snapshot("matrix_complete") is False
    assert dynamic_runner.inventory_drift_detected
    assert dynamic_runner.definitive_failures["inventory_drift"] == 1
    assert dynamic_runner.summary()["profile_matrix"]["pass"] is False

    strict_runner = SoakRunner(
        "adb",
        "serial",
        Path("unused"),
        expected_profile_count=REFERENCE_PROFILE_COUNT,
    )
    strict_snapshot_writes: list[tuple[str, Mapping[str, Any]]] = []
    strict_runner.atomic_json = (  # type: ignore[method-assign]
        lambda name, payload: strict_snapshot_writes.append((name, payload))
    )
    strict_runner.bridge_request = (  # type: ignore[method-assign]
        lambda command: (dynamic_payload, "")
    )
    try:
        strict_runner.load_inventory()
        raise AssertionError("strict inventory mismatch was accepted")
    except RuntimeError as error:
        assert str(error) == "unexpected_profile_count"
    assert strict_runner.inventory_snapshot_count == 8
    assert strict_runner.inventory_snapshot_locked
    assert strict_runner.inventory_requirement_met is False
    assert strict_snapshot_writes[0][0] == "inventory-snapshot.json"
    assert strict_snapshot_writes[0][1]["requested_expected_count"] == 18
    assert strict_runner.summary()["pass"] is None

    reference_payload = {
        "ok": True,
        "count": len(profiles),
        "profiles": [
            {
                "profileToken": profile.token,
                "kind": profile.kind,
                "engine": profile.engine,
                "runnable": True,
            }
            for profile in profiles
        ],
    }
    strict_reference_runner = SoakRunner(
        "adb",
        "serial",
        Path("unused"),
        expected_profile_count=REFERENCE_PROFILE_COUNT,
    )
    strict_reference_runner.atomic_json = (  # type: ignore[method-assign]
        lambda name, payload: None
    )
    strict_reference_runner.bridge_request = (  # type: ignore[method-assign]
        lambda command: (reference_payload, "")
    )
    strict_reference_runner.load_inventory()
    assert strict_reference_runner.inventory_requirement_met
    assert len(strict_reference_runner.schedule) == 41
    assert not transition_has_confirmed_failure(
        {
            "attempts": 0,
            "measured_attempts": 0,
            "failed": 0,
            "confirmed_failed": 0,
            "p95_ms": -1,
            "p95_sla_ms": SWITCH_P95_SLA_MS,
            "max_ms": -1,
            "max_sla_ms": SWITCH_MAX_SLA_MS,
        }
    )
    assert transition_has_confirmed_failure(
        {
            "attempts": 1,
            "measured_attempts": 1,
            "failed": 1,
            "confirmed_failed": 1,
            "p95_ms": 1,
            "p95_sla_ms": SWITCH_P95_SLA_MS,
            "max_ms": 1,
            "max_sla_ms": SWITCH_MAX_SLA_MS,
        }
    )
    observer_transition = SoakRunner(
        "adb",
        "serial",
        Path("unused"),
    ).transition_summary(
        [
            {
                "duration_ms": 180_000,
                "ready": False,
                "tcp_ok": "",
                "https_ok": "",
                "error_code": "observer_unavailable",
                "_qualifying": True,
            }
        ],
        max_sla_ms=SWITCH_MAX_SLA_MS,
        p95_sla_ms=SWITCH_P95_SLA_MS,
    )
    assert observer_transition["observer_failed"] == 1
    assert observer_transition["confirmed_failed"] == 0
    assert not transition_has_confirmed_failure(observer_transition)
    assert WaitReadyResult(False, VpnState(observed=True), 20, 1).sustained_observation
    assert not WaitReadyResult(
        False,
        VpnState(observed=True),
        1,
        20,
    ).sustained_observation
    measured_resource_failure = has_measured_resource_failure(
        {"failed_instances": [{"process_instance": "opaque"}]},
        {"failed_instances": []},
        {"cpu": {}},
    )
    assert measured_resource_failure
    assert not has_measured_resource_failure(
        {"failed_instances": []},
        {"failed_instances": []},
        {
            "cpu": {
                "main": {
                    "samples": 1,
                    "p95_percent": 99,
                    "p95_limit_percent": 15,
                }
            },
            "battery_temperature_max_c": -1,
            "partial_wakelock_observer_coverage_ratio": 0,
        },
    )
    plan_48h = qualification_plan(48, len(profiles))
    schedule_48h = build_schedule(profiles, plan_48h)
    matrix_48h = [
        slot for slot in schedule_48h if slot.phase.startswith("matrix-")
    ]
    assert len(schedule_48h) == len(schedule)
    assert len(matrix_48h) == reference_profile_count * 2
    assert schedule_48h[-1].planned_end_s == 172_800
    assert plan_48h.engine_dwell_s == 50_400
    assert plan_48h.handover_segment_durations_s == (16_800, 16_800, 16_800)
    assert [
        (slot.profile_token, slot.network) for slot in matrix_48h
    ] == [(slot.profile_token, slot.network) for slot in matrix]
    dynamic_plan_48h = qualification_plan(48, len(dynamic_profiles))
    dynamic_schedule_48h = build_schedule(dynamic_profiles, dynamic_plan_48h)
    assert dynamic_schedule_48h[-1].planned_end_s == 172_800
    assert dynamic_plan_48h.engine_dwell_s == 54_400
    assert dynamic_plan_48h.handover_segment_durations_s == (
        18_133,
        18_133,
        18_134,
    )
    selected_preflight, cross_network_pass = select_preflight_xray(
        profiles[11],
        None,
    )
    assert selected_preflight == profiles[11]
    assert cross_network_pass is False
    selected_preflight, cross_network_pass = select_preflight_xray(
        profiles[11],
        profiles[14],
    )
    assert selected_preflight == profiles[14]
    assert cross_network_pass is True
    assert select_preflight_xray(None, None) == (None, False)

    contaminated_vpn_dump = f"""
NetworkAgentInfo{{network{{1}} ni{{VPN CONNECTED extra: VPN:{PACKAGE}}} Score(Policies : IS_VPN) nc{{[ Transports: CELLULAR|VPN Capabilities: INTERNET TransportInfo: <VpnTransportInfo{{sessionId=sing-box}}> ]}}
    Requests: REQUEST:1 total:1
      NetworkRequest [ Transports: WIFI|VPN Capabilities: VALIDATED sessionId=xray ]
}}
NetworkAgentInfo{{network{{2}} ni{{VPN CONNECTED extra: VPN:another.package}} Score(Policies : IS_VPN&IS_VALIDATED) nc{{[ Transports: WIFI|VPN Capabilities: VALIDATED TransportInfo: <VpnTransportInfo{{sessionId=xray}}> ]}}}}
"""
    parsed_vpn_state = parse_vpn_state(contaminated_vpn_dump)
    assert parsed_vpn_state.observed
    assert not parsed_vpn_state.validated
    assert parsed_vpn_state.network == "cellular"
    assert parsed_vpn_state.runtime == "singbox"

    exit_sample = """
        ApplicationExitInfo #0:
          timestamp=2026-07-26 17:44:53.812 pid=1 realUid=2
          process=online.dnsai.ivanvpn:vpn reason=5 (CRASH NATIVE) subreason=0 (UNKNOWN) status=0
          importance=125 pss=12MB rss=152MB description=redacted
    """
    parsed = parse_exit_info(exit_sample)
    assert len(parsed) == 1
    assert parsed[0].process_role == "vpn"
    assert parsed[0].reason_code == 5
    assert parsed[0].pss_kb == 12 * 1024
    assert parsed[0].rss_kb == 152 * 1024
    assert exit_event_is_pre_run(
        "2026-07-26 17:44:53.812",
        "2026-07-26T17:44:54.000",
    )
    assert not exit_event_is_pre_run(
        "2026-07-26 17:44:54.001",
        "2026-07-26T17:44:54.000",
    )
    assert not exit_event_is_pre_run("invalid", "2026-07-26T17:44:54.000")
    assert round(percentile([1, 2, 3, 4, 5], 0.95), 1) == 4.8
    assert round(linear_slope_per_hour([(0, 100), (1800, 150), (3600, 200)])) == 100

    query_args = status_query_args("self_test_1")
    assert query_args[:3] == ("shell", "am", "broadcast")
    assert SOAK_QUERY_ACTION in query_args
    assert "-p" in query_args and PACKAGE in query_args
    assert "start" not in query_args and "-n" not in query_args
    control_args = control_broadcast_args("self_test_2", "activate", "p0001")
    assert control_args[:3] == ("shell", "am", "broadcast")
    assert SOAK_ACTION in control_args
    assert "start" not in control_args and "-n" not in control_args

    background_runner = SoakRunner("adb", "serial", Path("unused"))
    background_calls: list[tuple[str, ...]] = []
    background_runner.pidof = lambda process: (  # type: ignore[method-assign]
        "123",
        True,
    )
    background_runner.query_status = (  # type: ignore[method-assign]
        lambda timeout_s=5: ({"ok": True}, "")
    )
    background_runner.adb_run = (  # type: ignore[method-assign]
        lambda *arguments, **kwargs: (background_calls.append(arguments), "")
    )
    background_runner.poll_bridge_result = (  # type: ignore[method-assign]
        lambda request_id, command, timeout_s: (
            {"ok": True, "profileToken": "p0001"},
            "",
        )
    )
    _, background_error = background_runner.bridge_request(
        "activate",
        "p0001",
        timeout_s=1,
    )
    assert background_error == ""
    assert background_runner.bridge_foreground_fallbacks == 0
    assert background_runner.last_bridge_control_dispatch_monotonic > 0
    assert background_calls[0][:3] == ("shell", "am", "broadcast")

    timeout_runner = SoakRunner("adb", "serial", Path("unused"))
    timeout_calls: list[tuple[str, ...]] = []
    timeout_runner.pidof = lambda process: (  # type: ignore[method-assign]
        "123",
        True,
    )
    timeout_runner.query_status = (  # type: ignore[method-assign]
        lambda timeout_s=5: ({"ok": True}, "")
    )
    timeout_runner.adb_run = (  # type: ignore[method-assign]
        lambda *arguments, **kwargs: (timeout_calls.append(arguments), "")
    )
    timeout_runner.poll_bridge_result = (  # type: ignore[method-assign]
        lambda request_id, command, timeout_s: (None, "bridge_timeout")
    )
    _, timeout_error = timeout_runner.bridge_request(
        "reconnect",
        "p0001",
        timeout_s=1,
    )
    assert timeout_error == "bridge_timeout"
    assert timeout_runner.bridge_foreground_fallbacks == 0
    assert all("start" not in call for call in timeout_calls)

    ambiguous_runner = SoakRunner("adb", "serial", Path("unused"))
    ambiguous_calls: list[tuple[str, ...]] = []
    ambiguous_runner.pidof = lambda process: (  # type: ignore[method-assign]
        "123",
        True,
    )
    ambiguous_runner.query_status = (  # type: ignore[method-assign]
        lambda timeout_s=5: ({"ok": True}, "")
    )
    ambiguous_runner.adb_run = (  # type: ignore[method-assign]
        lambda *arguments, **kwargs: (
            ambiguous_calls.append(arguments),
            "observer_unavailable",
        )
    )
    _, ambiguous_error = ambiguous_runner.bridge_request(
        "reconnect",
        "p0001",
        timeout_s=1,
    )
    assert ambiguous_error == "observer_unavailable"
    assert ambiguous_runner.bridge_foreground_fallbacks == 0
    assert len(ambiguous_calls) == 1
    assert ambiguous_calls[0][:3] == ("shell", "am", "broadcast")

    fallback_runner = SoakRunner("adb", "serial", Path("unused"))
    fallback_calls: list[tuple[str, ...]] = []
    fallback_runner.pidof = lambda process: (  # type: ignore[method-assign]
        "123",
        True,
    )
    fallback_status_results = iter(
        [
            (None, "status_query_failed"),
            ({"ok": True}, ""),
        ]
    )
    fallback_runner.query_status = (  # type: ignore[method-assign]
        lambda timeout_s=5: next(fallback_status_results)
    )
    fallback_runner.adb_run = (  # type: ignore[method-assign]
        lambda *arguments, **kwargs: (fallback_calls.append(arguments), "")
    )
    fallback_runner.poll_bridge_result = (  # type: ignore[method-assign]
        lambda request_id, command, timeout_s: ({"ok": True}, "")
    )
    _, fallback_error = fallback_runner.bridge_request("inventory", timeout_s=1)
    assert fallback_error == ""
    assert fallback_runner.bridge_foreground_fallbacks == 1
    assert fallback_runner.last_bridge_control_dispatch_monotonic > 0
    assert fallback_calls[0][:3] == ("shell", "am", "start")
    assert SOAK_ACTION not in fallback_calls[0]
    assert "soakCommand" not in fallback_calls[0]
    assert fallback_calls[1][:3] == ("shell", "am", "broadcast")
    assert SOAK_ACTION in fallback_calls[1]
    assert SOAK_ACTION not in foreground_bootstrap_args()
    assert "query_status" not in SoakRunner.counter_tick.__code__.co_names
    assert "bridge_request" not in SoakRunner.counter_tick.__code__.co_names
    assert (
        "begin_post_transition_counter_baseline"
        not in SoakRunner.perform_handover.__code__.co_names
    )

    planned_pid_runner = SoakRunner("adb", "serial", Path("unused"))
    planned_pid_runner.process_last_pid["vpn"] = "101"
    planned_pid_runner.planned_vpn_process_change_active = True
    planned_pid_runner.planned_vpn_pid_change_pending = True
    planned_pid_runner.pidof = lambda process: ("202", True)  # type: ignore[method-assign]
    planned_pid_runner.event = lambda *args, **kwargs: None  # type: ignore[method-assign]
    planned_pid_runner.scan_exit_info = lambda: None  # type: ignore[method-assign]
    planned_pid_runner.close_planned_vpn_process_change_window()
    assert planned_pid_runner.process_last_pid["vpn"] == "202"
    assert not planned_pid_runner.planned_vpn_process_change_active
    assert not planned_pid_runner.planned_vpn_pid_change_pending
    assert planned_pid_runner.definitive_failures["unexpected_exit"] == 0

    delayed_exit_runner = SoakRunner("adb", "serial", Path("unused"))
    delayed_exit_runner.planned_vpn_process_change_active = True
    delayed_exit_runner.planned_vpn_pid_change_pending = True
    delayed_exit_runner.planned_vpn_exit_event_pending = True
    delayed_exit_runner.pidof = lambda process: ("", False)  # type: ignore[method-assign]
    delayed_exit_runner.scan_exit_info = lambda: False  # type: ignore[method-assign]
    delayed_exit_runner.close_planned_vpn_process_change_window()
    assert not delayed_exit_runner.planned_vpn_process_change_active
    assert delayed_exit_runner.planned_vpn_exit_event_pending
    expected_exit = ExitEvent(
        event_id="expected_cross_core_exit",
        timestamp_local="2026-08-11 00:00:00.000",
        process_role="vpn",
        reason_code=1,
        reason_name="exit_self",
        subreason_code=0,
        subreason_name="unknown",
        pss_kb=1,
        rss_kb=1,
    )
    delayed_exit_runner.read_exit_info = lambda: [expected_exit]  # type: ignore[method-assign]
    delayed_exit_runner.observe_issue = lambda *args, **kwargs: None  # type: ignore[method-assign]
    delayed_exit_runner.append_csv = lambda *args, **kwargs: None  # type: ignore[method-assign]
    delayed_exit_runner.append_jsonl = lambda *args, **kwargs: None  # type: ignore[method-assign]
    delayed_exit_runner.capture_incident = lambda *args, **kwargs: None  # type: ignore[method-assign]
    assert SoakRunner.scan_exit_info(delayed_exit_runner)
    assert not delayed_exit_runner.planned_vpn_exit_event_pending
    assert delayed_exit_runner.definitive_failures["unexpected_exit"] == 0

    unknown_boundary_runner = SoakRunner("adb", "serial", Path("unused"))
    unknown_boundary_runner.event = lambda *args, **kwargs: None  # type: ignore[method-assign]
    unknown_boundary_runner.begin_planned_vpn_process_change_window(
        required=True,
        exit_boundary_observed=False,
    )
    assert unknown_boundary_runner.exit_transition_boundary_observer_failures == 1
    assert unknown_boundary_runner.planned_vpn_exit_event_ambiguous_pending
    ambiguous_exit = replace(
        expected_exit,
        event_id="ambiguous_cross_core_signal",
        reason_code=2,
        reason_name="signaled",
    )
    classification, failure = unknown_boundary_runner.classify_exit_event(
        ambiguous_exit
    )
    assert classification == "ambiguous_vpn_signal"
    assert not failure

    historical_only_power = f"""
Wake Locks: size=0
Wake Lock Log
  07-26 12:00:00.000 - 1000 - ACQ YurichConnect:VpnKeeper
  07-26 12:00:01.000 - 1000 - ACQ {PACKAGE} PARTIAL_WAKE_LOCK
"""
    assert parse_active_partial_wakelocks(historical_only_power) == (0, True)
    active_power = f"""
Wake Locks: size=2
  PARTIAL_WAKE_LOCK 'YurichConnect:VpnKeeper' ACQ=-2m (uid=1000)
  PARTIAL_WAKE_LOCK 'other' ACQ=-1m (uid=1001)
Suspend Blockers: size=1
  PowerManagerService.WakeLocks
Wake Lock Log
  07-26 12:00:00.000 - 1000 - ACQ YurichConnect:VpnKeeper
"""
    assert parse_active_partial_wakelocks(active_power) == (1, True)
    truncated_active_power = """
Wake Locks: size=2
  PARTIAL_WAKE_LOCK 'one' ACQ=-1m (uid=1001)
Suspend Blockers: size=1
"""
    assert parse_active_partial_wakelocks(truncated_active_power) == (-1, False)
    assert parse_active_partial_wakelocks("Power Manager State: ready") == (
        -1,
        False,
    )

    counter_log = """
      1785064000.100 100 101 I YurichSoakBridge: SOAK_QA_COUNTER token=p0001 generation=7 native=4096 display=4096
      1785064055.200 100 101 I YurichSoakBridge: SOAK_QA_COUNTER token=p0001 generation=7 native=8192 display=8192
    """
    counter_events = parse_passive_counter_logs(counter_log)
    assert len(counter_events) == 2
    assert counter_events[-1].token == "p0001"
    assert counter_events[-1].native_bytes == 8192
    assert counter_events[-1].display_bytes == 8192

    previous_counter = PassiveCounterEvent(
        "previous",
        100.0,
        "p0001",
        7,
        4_096,
        4_096,
    )
    both_frozen = PassiveCounterEvent(
        "both_frozen",
        110.0,
        "p0001",
        7,
        4_096,
        4_096,
    )
    native_only = PassiveCounterEvent(
        "native_only",
        110.0,
        "p0001",
        7,
        8_192,
        4_096,
    )
    assert evaluate_passive_counters(
        previous_counter,
        [both_frozen],
        [105.0],
    ).stalled
    assert evaluate_passive_counters(
        previous_counter,
        [native_only],
        [],
    ).stalled
    fallback_only = evaluate_passive_counters(
        previous_counter,
        [both_frozen],
        [],
    )
    assert not fallback_only.payload_between and not fallback_only.stalled
    event_before_probe = evaluate_passive_counters(
        previous_counter,
        [both_frozen],
        [111.0],
    )
    assert not event_before_probe.payload_between
    assert not event_before_probe.stalled
    old_after_reconnect = PassiveCounterEvent(
        "old_after_reconnect",
        120.0,
        "p0001",
        7,
        12_288,
        12_288,
    )
    new_after_reconnect = PassiveCounterEvent(
        "new_after_reconnect",
        121.0,
        "p0001",
        8,
        0,
        0,
    )
    reconnect_baseline = evaluate_passive_counters(
        None,
        [old_after_reconnect, new_after_reconnect],
        [],
        establish_baseline=True,
    )
    assert reconnect_baseline.current == new_after_reconnect
    assert not reconnect_baseline.had_comparison
    assert not reconnect_baseline.reset
    warmup_runner = SoakRunner("adb", "serial", Path("unused"))
    warmup_runner.current_profile = Profile("p0001", "naive", "singBox")
    warmup_runner.counter_baseline_pending = True
    warmup_runner.counter_baseline_not_before_epoch = time.time()
    warmup_runner.counter_baseline_started_monotonic = time.monotonic()
    warmup_runner.vpn_state = lambda: VpnState(  # type: ignore[method-assign]
        observed=True,
        validated=True,
        network="cellular",
        runtime="singbox",
    )
    captured_counter_rows: list[dict[str, Any]] = []
    warmup_runner.append_csv = (  # type: ignore[method-assign]
        lambda name, row: captured_counter_rows.append(dict(row))
        if name == "counters.csv"
        else None
    )
    warmup_runner.read_passive_counter_events = lambda: (  # type: ignore[method-assign]
        [old_after_reconnect],
        "",
    )
    warmup_runner.counter_tick()
    assert warmup_runner.counter_samples == 1
    assert warmup_runner.counter_observed_samples == 0
    assert warmup_runner.counter_baseline_grace_samples == 1
    assert warmup_runner.counter_stalls == 0
    assert warmup_runner.counter_resets == 0
    assert warmup_runner.observation_streaks.get("passive_counter_missing") == 0
    assert warmup_runner.counter_baseline_pending
    assert captured_counter_rows[-1]["baseline_pending"] is True
    assert captured_counter_rows[-1]["baseline_grace"] is True
    warmup_runner.counter_baseline_started_monotonic = (
        time.monotonic() - COUNTER_BASELINE_GRACE_S - 1
    )
    warmup_runner.counter_tick()
    assert warmup_runner.counter_samples == 2
    assert warmup_runner.observation_streaks["passive_counter_missing"] == 1
    assert captured_counter_rows[-1]["baseline_grace"] is False

    cursor_runner = SoakRunner("adb", "serial", Path("unused"))
    cursor_runner.current_profile = Profile("p0001", "naive", "singBox")
    cursor_runner.current_network = "cellular"
    cursor_runner.counter_previous = previous_counter
    cursor_runner.vpn_state = lambda: VpnState(  # type: ignore[method-assign]
        observed=True,
        validated=True,
        network="cellular",
        runtime="singbox",
    )
    cursor_runner.read_passive_counter_events = lambda: (  # type: ignore[method-assign]
        None,
        "observer_unavailable",
    )
    cursor_runner.append_csv = lambda *args, **kwargs: None  # type: ignore[method-assign]
    cursor_runner.observe_issue = lambda *args, **kwargs: None  # type: ignore[method-assign]
    cursor_runner.counter_tick()
    assert cursor_runner.counter_previous is previous_counter

    coverage_runner = SoakRunner("adb", "serial", Path("unused"))
    coverage_runner.started_monotonic = time.monotonic() - 183
    coverage_runner.counter_samples = 1
    coverage_runner.counter_observed_samples = 0
    coverage_runner.counter_baseline_grace_samples = 1
    incomplete_counter_coverage = coverage_runner.counter_coverage_summary()
    assert incomplete_counter_coverage["expected_ticks"] == 4
    assert incomplete_counter_coverage["missed_ticks"] == 3
    assert incomplete_counter_coverage["pass"] is False
    coverage_runner.counter_samples = 4
    coverage_runner.counter_observed_samples = 3
    complete_counter_coverage = coverage_runner.counter_coverage_summary()
    assert complete_counter_coverage["observed_ratio"] == 1.0
    assert complete_counter_coverage["pass"] is True
    unexpected_generation = evaluate_passive_counters(
        previous_counter,
        [new_after_reconnect],
        [],
    )
    assert unexpected_generation.generation_changed
    assert unexpected_generation.reset

    tolerant = observation_quality_gates(
        tcp_failures=1,
        https_failures=1,
        counter_stalls=1,
        counter_resets=0,
    )
    assert all(tolerant.values())
    systematic = observation_quality_gates(
        tcp_failures=2,
        https_failures=3,
        counter_stalls=2,
        counter_resets=1,
    )
    assert not any(systematic.values())

    observer_runner = SoakRunner("adb", "serial", Path("unused"))
    observer_runner.plan = qualification_plan(24, REFERENCE_PROFILE_COUNT)
    observer_runner.inventory_final_verification_observed = True
    observer_runner.update_observer_streak(False, now_monotonic=100.0)
    observer_runner.update_observer_streak(True, now_monotonic=130.0)
    assert observer_runner.observer_max_unknown_streak_s == 30.0
    observer_runner.completed = True
    observer_runner.started_monotonic = 1.0
    observer_runner.elapsed_s = (  # type: ignore[method-assign]
        lambda: observer_runner.plan.duration_s
    )
    expected_health_ticks = observer_runner.expected_periodic_ticks(
        0,
        HEALTH_INTERVAL_S,
    )
    expected_counter_ticks = observer_runner.expected_periodic_ticks(
        3,
        COUNTER_INTERVAL_S,
    )
    observer_runner.health_scheduled_samples = expected_health_ticks
    observer_runner.health_last_scheduled_elapsed = float(
        observer_runner.plan.duration_s
    )
    observer_runner.counter_samples = expected_counter_ticks
    observer_runner.counter_observed_samples = expected_counter_ticks
    observer_runner.health_samples = 200
    observer_runner.healthy_samples = 199
    observer_runner.observer_unknown_samples = 1
    observer_runner.memory_records["main"] = [
        {
            "app_partial_wakelocks": 0,
            "app_partial_wakelocks_observed": True,
            "screen_interactive": False,
            "battery_level": 100,
            "battery_temp_c": 30.0,
            "cpu_percent": 0.0,
        }
    ]
    assert observer_runner.summary()["qualification_status"] == "failed"
    observer_runner.observer_max_unknown_streak_s = 150.0
    blocked_summary = observer_runner.summary()
    assert blocked_summary["qualification_status"] == "inconclusive"
    assert blocked_summary["pass"] is None
    assert blocked_summary["verdict"]["blocked_by_observer"] is True
    observer_runner.definitive_failures["crash"] = 1
    failed_with_observer_gap = observer_runner.summary()
    assert failed_with_observer_gap["qualification_status"] == "failed"
    assert failed_with_observer_gap["pass"] is False
    assert failed_with_observer_gap["verdict"]["confirmed_app_failure"] is True
    assert failed_with_observer_gap["verdict"]["blocked_by_observer"] is False
    observer_runner.definitive_failures.clear()
    observer_runner.counter_resets = 1
    reset_with_observer_gap = observer_runner.summary()
    assert reset_with_observer_gap["qualification_status"] == "failed"
    assert reset_with_observer_gap["verdict"]["confirmed_app_failure"] is True
    observer_runner.counter_resets = 0
    observer_runner.memory_summary = (  # type: ignore[method-assign]
        lambda role: {
            "pass": role != "main",
            "failed_instances": (
                [{"process_instance": "opaque", "engine": "singbox"}]
                if role == "main"
                else []
            ),
        }
    )
    resource_with_observer_gap = observer_runner.summary()
    assert resource_with_observer_gap["qualification_status"] == "failed"
    assert resource_with_observer_gap["verdict"]["measured_resource_failure"]
    del observer_runner.memory_summary
    observer_runner.observer_max_unknown_streak_s = 30.0
    observer_runner.confirmed_issue_counts[BRIDGE_CONTROL_OBSERVER_ISSUE] = 1
    confirmed_observer_summary = observer_runner.summary()
    assert confirmed_observer_summary["qualification_status"] == "inconclusive"
    assert confirmed_observer_summary["health"]["confirmed_app_issues"] == 0
    assert not confirmed_observer_summary["verdict"]["observer_gates"][
        "no_confirmed_observer_issues"
    ]
    observer_runner.confirmed_issue_counts.clear()
    observer_runner.health_scheduled_samples = expected_health_ticks - 3
    observer_runner.health_last_scheduled_elapsed = (
        observer_runner.plan.duration_s - 211
    )
    cadence_summary = observer_runner.summary()
    assert cadence_summary["health"]["cadence"]["missed_samples"] == 3
    assert cadence_summary["health"]["cadence"]["max_scheduled_gap_s"] == 211.0
    assert not cadence_summary["verdict"]["observer_gates"][
        "health_sampling_cadence"
    ]
    assert cadence_summary["qualification_status"] == "inconclusive"
    terminal_incomplete_runner = SoakRunner(
        "adb",
        "serial",
        Path("unused"),
    )
    terminal_incomplete_runner.finished_utc = utc_now()
    terminal_incomplete_summary = terminal_incomplete_runner.summary()
    assert terminal_incomplete_summary["qualification_status"] == "incomplete"
    assert terminal_incomplete_summary["pass"] is None

    memory_runner = SoakRunner("adb", "serial", Path("unused"))
    singbox_profile = Profile("p0001", "naive", "singBox")
    xray_profile = Profile("p0012", "vlessXhttp", "xray")
    memory_runner.profiles = [singbox_profile, xray_profile]
    memory_runner.profile_by_token = {
        profile.token: profile for profile in memory_runner.profiles
    }
    memory_runner.endurance_profiles = {
        "singbox_role": singbox_profile.token,
        "xray_role": xray_profile.token,
    }
    memory_runner.process_instances["vpn"] = {"a": 1, "b": 2}

    def synthetic_memory(
        instance: int,
        engine: str,
        start_s: int,
        pss_step_kb: int,
    ) -> list[dict[str, Any]]:
        return [
            {
                "elapsed_s": start_s + index * MEMORY_INTERVAL_S,
                "phase": f"dwell-{engine}",
                "engine": engine,
                "process_instance": instance,
                "pss_kb": 100_000 + index * pss_step_kb,
                "fd_count": 50,
                "thread_count": 40,
            }
            for index in range(72)
        ]

    memory_runner.memory_records["vpn"] = (
        synthetic_memory(1, "singBox", 21_600, 10)
        + synthetic_memory(2, "xray", 43_200, 500)
    )
    bad_memory = memory_runner.memory_summary("vpn")
    assert bad_memory["eligible_instances"] == 2
    assert bad_memory["pass"] is False
    assert {"process_instance": 2, "engine": "xray"} in bad_memory[
        "failed_instances"
    ]
    memory_runner.memory_records["vpn"] = (
        synthetic_memory(1, "singBox", 21_600, 10)
        + synthetic_memory(2, "xray", 43_200, 10)
    )
    good_memory = memory_runner.memory_summary("vpn")
    assert good_memory["pass"] is True
    assert parse_args(["--self-test"]).expected_profile_count is None
    assert (
        parse_args(
            ["--self-test", "--expected-profile-count", "18"],
        ).expected_profile_count
        == REFERENCE_PROFILE_COUNT
    )

    print(
        "SELF_TEST_OK schedules=24h,48h profiles=8,18 matrix_cells=16,36 "
        "inventory_snapshot=true strict_expected=true "
        "passive_counter=true active_wakelock=true cadence_gates=true "
        "background_control=true per_core_memory=true",
        flush=True,
    )


def profile_count_argument(value: str) -> int:
    try:
        count = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be an integer") from error
    if not 1 <= count <= 9_999:
        raise argparse.ArgumentTypeError("must be between 1 and 9999")
    return count


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run the 24/48-hour Yurich Connect Android soak matrix.",
    )
    parser.add_argument("--adb", help="Absolute path to adb")
    parser.add_argument("--serial", help="adb device serial; never persisted raw")
    parser.add_argument("--out", type=Path, help="New run artifact directory")
    parser.add_argument(
        "--duration-hours",
        type=int,
        choices=SUPPORTED_DURATION_HOURS,
        default=DEFAULT_DURATION_HOURS,
        help=(
            "Qualification duration. The 48-hour plan keeps one exact N x 2 "
            "matrix and extends endurance phases."
        ),
    )
    parser.add_argument(
        "--expected-profile-count",
        type=profile_count_argument,
        default=None,
        help=(
            "Optional strict runnable inventory count. Omit to lock and test "
            "the validated observed inventory; release qualification normally "
            "uses 18."
        ),
    )
    parser.add_argument(
        "--allow-missing-isolation-evidence",
        action="store_true",
        help="Do not require both native runtime guard tags during preflight",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Validate parsers and the exact 24/48-hour plans without adb",
    )
    args = parser.parse_args(argv)
    if not args.self_test:
        missing = [
            flag
            for flag, value in (
                ("--adb", args.adb),
                ("--serial", args.serial),
                ("--out", args.out),
            )
            if not value
        ]
        if missing:
            parser.error(f"required arguments: {', '.join(missing)}")
    return args


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    return SoakRunner(
        adb=args.adb,
        serial=args.serial,
        out_dir=args.out,
        require_isolation_evidence=not args.allow_missing_isolation_evidence,
        duration_hours=args.duration_hours,
        expected_profile_count=args.expected_profile_count,
    ).run()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
