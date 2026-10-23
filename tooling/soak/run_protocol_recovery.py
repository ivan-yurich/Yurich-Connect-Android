"""Bounded config-bound handovers/outage for one existing profile, screen off."""

import argparse
import hashlib
from dataclasses import asdict
from pathlib import Path

from tooling.soak.http_diagnostics import measure_https
from tooling.soak.native_observer import read_native_snapshot
from tooling.soak.run_native_soak import NativeSoak, NativeSoakTransport


class ProtocolRecovery(NativeSoak):
    def __init__(self, runner, token):
        super().__init__(runner, preflight_only=True)
        self.token = token
        self.report["requested_profile"] = token

    def setup(self):
        super().setup()
        self.report["controller_sha256"][Path(__file__).name] = hashlib.sha256(
            Path(__file__).read_bytes()).hexdigest()

    def diagnostics(self, source):
        # Same endpoints as BoxService, but curl is a different TLS client.
        # These sequential measurements never qualify recovery or prove a cause.
        for endpoint in ("health_cloudflare", "health_gstatic", "health_google"):
            before, before_error = read_native_snapshot(self.r, version=3)
            attempt = measure_https(self.r, endpoint, via_native_proxy=True)
            after, after_error = read_native_snapshot(self.r, version=3)
            self.r.append_jsonl("same-endpoint-diagnostics.jsonl", {
                "source": source, "http": asdict(attempt),
                "network": self.r.current_network,
                "before": asdict(before) if before else None,
                "after": asdict(after) if after else None,
                "before_error": before_error, "after_error": after_error,
                "qualification": "diagnostic_only",
            })

    def preflight_phase(self):
        profile = next((p for p in self.r.profiles if p.token == self.token), None)
        if profile is None:
            raise ValueError("requested_profile_not_found")
        self.report["phase"] = "protocol_setup"
        self.network("wifi")
        control = self.command(profile)
        if not control["binding_verified"]:
            return
        baseline = self.sample("protocol_wifi_baseline")
        self.diagnostics("wifi_baseline")
        if not baseline["pass"]:
            self.report["scenario_skips"] += 3
            return
        self.handover("cellular")
        self.diagnostics("after_cellular_handover_or_skip")
        self.handover("wifi")
        self.diagnostics("after_wifi_handover_or_skip")
        self.outage()
        self.sample("protocol_final")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    if args.out.exists():
        parser.error("new_output_directory_required")
    runner = NativeSoakTransport(args.adb, args.serial, args.out)
    return ProtocolRecovery(runner, args.profile).run()


if __name__ == "__main__":
    raise SystemExit(main())
