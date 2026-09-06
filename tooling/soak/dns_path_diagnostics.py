"""Compare one public HTTPS endpoint without retaining DNS addresses or stderr."""

import ipaddress
import json
import re
from dataclasses import asdict, replace

from tooling.soak.http_diagnostics import ENDPOINTS, parse_attempt


HOST = "speed.cloudflare.com"
DOH_URL = "https://dns.google/resolve?name=speed.cloudflare.com"
FAKE_V4 = ipaddress.ip_network("198.18.0.0/15")


def parse_public_answers(raw):
    """Addresses stay in memory and must never be serialized to evidence."""
    if not isinstance(raw, str) or len(raw) > 16384:
        return []
    try:
        value = json.loads(raw)
        if (not isinstance(value, dict) or type(value.get("Status")) is not int
                or value["Status"] != 0 or value.get("TC") is not False):
            return []
        question = value.get("Question")
        if (not isinstance(question, list) or len(question) != 1
                or not isinstance(question[0], dict)
                or question[0].get("name", "").rstrip(".").lower() != HOST
                or type(question[0].get("type")) is not int or question[0]["type"] != 1):
            return []
        answers = value.get("Answer")
        if not isinstance(answers, list) or len(answers) > 32:
            return []
        result = []
        for answer in answers:
            if not isinstance(answer, dict):
                return []
            if answer.get("type") != 1:
                continue
            if (type(answer["type"]) is not int
                    or answer.get("name", "").rstrip(".").lower() != HOST
                    or not isinstance(answer.get("data"), str)):
                return []
            address = ipaddress.ip_address(answer["data"])
            if address.version != 4 or not address.is_global:
                return []
            if str(address) not in result:
                result.append(str(address))
        return result
    except (ValueError, TypeError, AttributeError):
        return []


def classify_connection(stderr, expected_address=None):
    if not isinstance(stderr, str) or len(stderr) > 100000:
        return {"observed": False}
    addresses = []
    for candidate in re.findall(r"^\*\s+Trying (\d{1,3}(?:\.\d{1,3}){3}):443\.\.\.$", stderr, re.M):
        try:
            addresses.append(ipaddress.ip_address(candidate))
        except ValueError:
            return {"observed": False}
    return {
        "observed": bool(addresses),
        "attempt_count": len(addresses),
        "fake_ip": all(a in FAKE_V4 for a in addresses) if addresses else None,
        "public_ip": all(a.is_global for a in addresses) if addresses else None,
        "matches_override": (bool(addresses) and all(str(a) == expected_address for a in addresses)
                             if expected_address is not None else None),
        "hostname_mismatch": "no alternative certificate subject name" in stderr.lower(),
    }


def measure_path(runner, path, address=None):
    options = ()
    if path == "native_proxy_domain":
        options = ("--proxy", "http://127.0.0.1:20808")
    elif path == "system_doh_address":
        try:
            parsed = ipaddress.ip_address(address)
        except (ValueError, TypeError):
            raise ValueError("public_ipv4_required") from None
        if parsed.version != 4 or not parsed.is_global:
            raise ValueError("public_ipv4_required")
        options = ("--resolve", f"{HOST}:443:{parsed}")
    elif path != "system_dns":
        raise ValueError("unsupported_diagnostic_path")
    result, error = runner.shell(
        "curl", "-vfsS", "--max-time", "15", "-o", "/dev/null", "--write-out", "%{json}",
        *options, ENDPOINTS["payload"][0], timeout=22,
    )
    attempt = replace(parse_attempt("payload", result, error), path=path)
    return {"http": asdict(attempt),
            "connection": classify_connection(result.stderr, address)
            if result is not None and error in {"", "nonzero"} else {"observed": False}}


def measure_paths(runner):
    system = measure_path(runner, "system_dns")
    proxy = measure_path(runner, "native_proxy_domain")
    response, error = runner.shell(
        "curl", "-fsS", "--max-time", "15", "--max-filesize", "16384",
        "--proxy", "http://127.0.0.1:20808", DOH_URL, timeout=22,
    )
    addresses = parse_public_answers(response.stdout) if response is not None and not error else []
    # Pin each returned A record, retaining TLS SNI/hostname validation for HOST.
    pinned = [measure_path(runner, "system_doh_address", address) for address in addresses[:4]]
    return {"system": system, "proxy": proxy, "doh": {
        "valid_public_answers": bool(addresses), "answer_count": len(addresses),
        "tested_count": len(pinned), "query_success": response is not None and not error,
    }, "pinned": pinned}
