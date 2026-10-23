"""Analyze the opt-in on-device report without extracting arbitrary ZIP paths."""

import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import json
from pathlib import Path
from zipfile import ZipFile

MAX_EVENTS = 40_000
MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
NETWORK_PRESENT = 1
NETWORK_CAPABILITIES_OBSERVED = 2
NETWORK_VPN = 4
NETWORK_WIFI = 8
NETWORK_CELLULAR = 16


def utc(ms):
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).isoformat()


def network_transport(flags):
    """Decode only coarse transports; flags never contain SSID, IP or network ids."""
    if type(flags) is not int or flags < 0:
        return "unknown"
    if not flags & NETWORK_PRESENT:
        return "none" if flags == 0 else "unknown"
    if not flags & NETWORK_CAPABILITIES_OBSERVED:
        return "unknown"
    wifi = bool(flags & NETWORK_WIFI)
    cellular = bool(flags & NETWORK_CELLULAR)
    if wifi and cellular:
        return "multiple"
    if wifi:
        return "wifi"
    if cellular:
        return "cellular"
    return "other"


def analyze(path):
    events = []
    with ZipFile(path) as archive:
        if len(archive.infolist()) != 2 or set(archive.namelist()) != {"metadata.json", "events.jsonl"}:
            raise ValueError("unexpected_archive_entries")
        if archive.getinfo("metadata.json").file_size > 16_384:
            raise ValueError("oversized_metadata")
        if archive.getinfo("events.jsonl").file_size > MAX_ARCHIVE_BYTES:
            raise ValueError("oversized_events")
        metadata = json.loads(archive.read("metadata.json"))
        if not isinstance(metadata, dict) or metadata.get("schema") != 1:
            raise ValueError("unsupported_schema")
        with archive.open("events.jsonl") as stream:
            for line in stream:
                if len(line) > 8192 or len(events) >= MAX_EVENTS:
                    raise ValueError("oversized_event_history")
                event = json.loads(line)
                if not isinstance(event, dict) or not isinstance(event.get("data"), dict):
                    raise ValueError("invalid_event")
                if type(event.get("wallMs")) is not int or type(event.get("elapsedMs")) is not int:
                    raise ValueError("invalid_event_time")
                if not isinstance(event.get("event"), str):
                    raise ValueError("invalid_event_code")
                events.append(event)
    if metadata.get("exportedEvents") != len(events):
        raise ValueError("incomplete_event_snapshot")

    counts = Counter(e["event"] for e in events)
    instances = set()
    samples = defaultdict(list)
    profile_checks = defaultdict(Counter)
    profile_protocols = {}
    exits = Counter()
    network_sources = Counter()
    network_transports = Counter()
    quorum_transports = defaultdict(Counter)
    probe_failure_stages = Counter()
    probe_failure_reasons = Counter()
    probe_failures_by_attempt = Counter()
    completed_probe_attempts = set()
    uncorrelated_probe_failures = 0
    counter_events = counter_identity_events = counter_mismatches = counter_resets = 0
    previous_counters = {}
    streak = maximum_streak = passed = failed = stale = tun_anomalies = 0
    observer_drops = defaultdict(int)
    write_failures = defaultdict(int)
    durations = []
    last_quorum_by_instance = {}
    max_observation_gap_ms = 0
    for event in events:
        data, code = event["data"], event["event"]
        identity = (data.get("pid"), data.get("instanceMs"))
        if data.get("instanceMs") is not None:
            instances.add(identity)
        pid = data.get("pid", -1)
        observer_drops[pid] = max(observer_drops[pid], data.get("droppedQueue", 0))
        write_failures[pid] = max(write_failures[pid], data.get("writeFailures", 0))
        if data.get("phase") == "Connected" and data.get("desired") == 1 and data.get("tun") == 0:
            tun_anomalies += 1
        if code == "network":
            network_sources[data.get("source", "unknown")] += 1
            network_transports[network_transport(data.get("trackedNet"))] += 1
        if code == "probe_failure":
            probe_failure_stages[data.get("stage", "unknown")] += 1
            probe_failure_reasons[data.get("failure", "unknown")] += 1
            probe_id = data.get("probeId")
            if type(probe_id) is int and probe_id >= 0:
                probe_failures_by_attempt[(pid, data.get("instanceMs"), probe_id)] += 1
            else:
                uncorrelated_probe_failures += 1
        if code == "exit":
            exits[data.get("reason", -1)] += 1
        if code == "sample":
            samples[data.get("role", "unknown")].append(data)
        if code == "counter":
            native = data.get("nativeSessionBytes")
            display = data.get("displayBytes")
            generation = data.get("uiGeneration")
            if all(type(value) is int and value >= 0 for value in (native, display, generation)):
                counter_events += 1
                if native != display:
                    counter_mismatches += 1
                instance = data.get("instanceMs")
                if all(type(value) is int and value >= 0 for value in (pid, instance)):
                    counter_identity_events += 1
                    counter_key = (pid, instance, generation)
                    previous = previous_counters.get(counter_key)
                    if previous is not None and (native < previous[0] or display < previous[1]):
                        counter_resets += 1
                    previous_counters[counter_key] = (native, display)
        if code != "quorum":
            continue
        if data.get("current") != 1 or data.get("desired") != 1:
            stale += 1
            continue
        success, total = data.get("success", -1), data.get("total", -1)
        if type(success) is not int or type(total) is not int or not 0 <= success <= total == 3:
            raise ValueError("invalid_quorum")
        duration = data.get("durationMs", -1)
        if type(duration) is not int:
            raise ValueError("invalid_duration")
        if duration >= 0:
            durations.append(duration)
        elapsed = event["elapsedMs"]
        previous = last_quorum_by_instance.get(identity)
        if previous is not None and elapsed >= previous:
            max_observation_gap_ms = max(max_observation_gap_ms, elapsed - previous)
        last_quorum_by_instance[identity] = elapsed
        healthy = success >= 2
        transport = network_transport(data.get("trackedNet"))
        quorum_transports[transport]["passed" if healthy else "failed"] += 1
        probe_id = data.get("probeId")
        if type(probe_id) is int and probe_id >= 0:
            completed_probe_attempts.add((pid, data.get("instanceMs"), probe_id))
        key = data.get("profile", "unbound")
        profile_protocols[key] = data.get("protocol", "unknown")
        profile_checks[key]["passed" if healthy else "failed"] += 1
        if healthy:
            passed += 1
            streak = 0
        else:
            failed += 1
            streak += 1
            maximum_streak = max(maximum_streak, streak)

    def extrema(values, key):
        observed = [s[key] for s in values if type(s.get(key)) is int and s[key] >= 0]
        return {"min": min(observed), "max": max(observed)} if observed else None

    return {
        "schema": 1, "app_version": metadata.get("appVersion"),
        "recording_active_at_export": metadata.get("active"),
        "started_utc": utc(metadata["startedAtMs"]),
        "deadline_utc": utc(metadata["endsAtMs"]), "events": len(events),
        "event_counts": dict(counts), "quorum_passed": passed, "quorum_failed": failed,
        "max_consecutive_failed_quorums": maximum_streak,
        "stale_or_nonrunning_quorums_excluded": stale,
        "max_probe_duration_ms": max(durations) if durations else None,
        "observed_vpn_instances": len(instances),
        "observed_vpn_instance_changes": max(0, len(instances) - 1),
        "runtime_restart_requests": counts["restart"], "tun_anomaly_events": tun_anomalies,
        "exit_reason_counts": dict(exits), "crash_exits": exits[4] + exits[5], "anr_exits": exits[6],
        "network_event_sources": dict(network_sources),
        "network_event_transports": dict(network_transports),
        "quorum_transports": {key: dict(value) for key, value in quorum_transports.items()},
        "probe_failure_stages": dict(probe_failure_stages),
        "probe_failure_reasons": dict(probe_failure_reasons),
        "endpoint_failures_excluding_cancellation": sum(
            count for reason, count in probe_failure_reasons.items()
            if reason != "cancelled"
        ),
        "probe_attempts_with_id": len(completed_probe_attempts),
        "probe_failures_for_completed_attempts": sum(
            count for key, count in probe_failures_by_attempt.items()
            if key in completed_probe_attempts
        ),
        "probe_failures_without_completed_attempt": sum(
            count for key, count in probe_failures_by_attempt.items()
            if key not in completed_probe_attempts
        ),
        "uncorrelated_probe_failures": uncorrelated_probe_failures,
        "counter_integrity": {
            "events": counter_events,
            "status": "not_observed" if counter_events == 0 else
                ("mismatch" if counter_mismatches != 0 or counter_resets != 0 else
                 ("matched" if counter_identity_events == counter_events else
                  "matched_legacy_identity_unverified")),
            "native_display_mismatches": counter_mismatches,
            "same_generation_resets": counter_resets,
            "stable_identity_events": counter_identity_events,
            "reset_tracking_complete": counter_identity_events == counter_events,
        },
        "profile_quorums": {key: dict(value) for key, value in profile_checks.items()},
        "profile_protocols": profile_protocols,
        "resource_samples": {role: {"count": len(values),
            "pss_kb": extrema(values, "pssKb"), "temperature_tenths_c": extrema(values, "tempTenthsC"),
            "screen_off_samples": sum(s.get("screen") == 0 for s in values),
            "doze_samples": sum(s.get("idle") == 1 for s in values)} for role, values in samples.items()},
        "observer_queue_drops": sum(observer_drops.values()),
        "observer_write_failures": sum(write_failures.values()),
        "rotated_events": metadata.get("rotatedEvents", 0),
        "max_observed_quorum_gap_ms": max_observation_gap_ms,
        "limitations": ["No observations while processes are stopped or suspended.",
            "System exit history is bounded; absent entries do not prove absence of crashes.",
            "Queue drops, rotation and missing observations are not successful checks.",
            "This report is not a 24/7 stability certification."],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = analyze(args.archive)
    text = json.dumps(report, indent=2, ensure_ascii=False)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text + "\n", encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main()
