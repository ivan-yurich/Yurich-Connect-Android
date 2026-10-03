"""Analyze the opt-in on-device report without extracting arbitrary ZIP paths."""

import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import json
from pathlib import Path
from zipfile import ZipFile

MAX_EVENTS = 40_000
MAX_ARCHIVE_BYTES = 64 * 1024 * 1024


def utc(ms):
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).isoformat()


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
        if code == "exit":
            exits[data.get("reason", -1)] += 1
        if code == "sample":
            samples[data.get("role", "unknown")].append(data)
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
