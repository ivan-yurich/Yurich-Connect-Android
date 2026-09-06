"""Whitelisted curl measurements; no URLs, IPs, headers or stderr in evidence."""

import json
import math
from dataclasses import dataclass, field, replace


ENDPOINTS = {
    "payload": ("https://speed.cloudflare.com/__down?bytes=65536", 65536),
    "fallback": ("https://www.gstatic.com/generate_204", None),
    "health_cloudflare": ("https://www.cloudflare.com/cdn-cgi/trace", None),
    "health_gstatic": ("https://connectivitycheck.gstatic.com/generate_204", None),
    "health_google": ("https://www.google.com/generate_204", None),
}
EXPECTED_STATUS = {
    "payload": 200, "fallback": 204, "health_cloudflare": 200,
    "health_gstatic": 204, "health_google": 204,
}
TIMINGS = ("time_namelookup", "time_connect", "time_appconnect", "time_starttransfer", "time_total")


@dataclass(frozen=True)
class HttpAttempt:
    endpoint: str
    observed: bool = False
    ok: bool = False
    exit_code: int = -1
    http_code: int = -1
    size_download: int = -1
    ssl_verify_result: int = -1
    failure: str = "metadata_unavailable"
    timings_ms: dict[str, float] = field(default_factory=dict)
    path: str = "system_route"


def parse_attempt(endpoint, result, error):
    if endpoint not in ENDPOINTS:
        raise ValueError("unsupported_diagnostic_endpoint")
    if result is None or error not in {"", "nonzero"}:
        return HttpAttempt(endpoint)
    if len(result.stdout) > 100_000:
        return HttpAttempt(endpoint)
    try:
        raw = json.loads(result.stdout)
    except (ValueError, TypeError):
        return HttpAttempt(endpoint)
    if not isinstance(raw, dict):
        return HttpAttempt(endpoint)
    for key in ("exitcode", "http_code", "size_download", "ssl_verify_result"):
        if type(raw.get(key)) is not int or not 0 <= raw[key] <= 2**63 - 1:
            return HttpAttempt(endpoint)
    if raw["exitcode"] != result.returncode or raw["http_code"] > 599:
        return HttpAttempt(endpoint)
    timings = {}
    for key in TIMINGS:
        value = raw.get(key)
        if type(value) not in {float, int} or not 0 <= value <= 3600 or not math.isfinite(value):
            return HttpAttempt(endpoint)
        timings[key] = round(value * 1000, 3)
    code = result.returncode
    failure = {6: "dns", 7: "connect", 22: "http_status", 28: "timeout",
               35: "tls", 51: "certificate", 60: "certificate"}.get(code, "curl_error")
    if code == 0:
        expected_size = ENDPOINTS[endpoint][1]
        if raw["ssl_verify_result"] != 0:
            failure = "certificate"
        elif raw["http_code"] != EXPECTED_STATUS[endpoint]:
            failure = "http_status"
        elif expected_size is not None and raw["size_download"] != expected_size:
            failure = "payload_size"
        else:
            failure = "none"
    return HttpAttempt(endpoint, True, failure == "none", code, raw["http_code"],
                       raw["size_download"], raw["ssl_verify_result"], failure, timings)


def measure_https(runner, endpoint, *, via_native_proxy=False):
    url, _ = ENDPOINTS[endpoint]
    proxy = ("--proxy", "http://127.0.0.1:20808") if via_native_proxy else ()
    result, error = runner.shell(
        "curl", "-fsS", "--max-time", "15", "-o", "/dev/null",
        "--write-out", "%{json}", *proxy, url, timeout=22,
    )
    return replace(parse_attempt(endpoint, result, error),
                   path="native_proxy" if via_native_proxy else "system_route")
