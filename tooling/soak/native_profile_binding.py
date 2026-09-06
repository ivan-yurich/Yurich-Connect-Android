"""Bind a setup-confirmed profile to config content, never infer it from runtime alone."""

import re
from dataclasses import dataclass

from tooling.soak.native_observer import NativeSnapshot
from tooling.soak.run_24h_matrix import Profile


@dataclass(frozen=True)
class NativeProfileBinding:
    profile: Profile
    fingerprint: str

    def __post_init__(self):
        if not isinstance(self.fingerprint, str) or not re.fullmatch(r"[0-9a-f]{64}", self.fingerprint):
            raise ValueError("valid_config_fingerprint_required")

    @classmethod
    def establish(cls, profile, before, status, after):
        if (not isinstance(before, NativeSnapshot) or not isinstance(after, NativeSnapshot)
                or not isinstance(status, dict) or status.get("ok") is not True
                or status.get("profileToken") != profile.token
                or status.get("kind") != profile.kind
                or str(status.get("engine", "")).lower() != profile.runtime
                or status.get("busy") is not False or status.get("queueActive") is not False
                or status.get("connectionState") != "connected"
                or status.get("vpnStatus") != "Started"
                or before.identity != after.identity or after.elapsed < before.elapsed):
            return None
        fingerprint = before.config_fingerprint
        if not isinstance(fingerprint, str) or not re.fullmatch(r"[0-9a-f]{64}", fingerprint):
            return None
        value = cls(profile, fingerprint)
        return value if value.matches(before) and value.matches(after) else None

    def matches(self, snapshot):
        # A new PID/generation may load the same config after native recovery.
        # Counter deltas still must be measured within one unchanged session.
        return bool(isinstance(snapshot, NativeSnapshot) and snapshot.format_version == 3
                    and snapshot.ready and snapshot.runtime == self.profile.runtime
                    and snapshot.config_fingerprint == self.fingerprint)


class NativeBindingRegistry:
    """Keep the first setup binding; a later selection cannot silently replace it."""

    def __init__(self):
        self.bindings = {}
        self.ambiguous_tokens = set()

    def accept(self, profile, before, status, after):
        candidate = NativeProfileBinding.establish(profile, before, status, after)
        if candidate is None:
            return None, "setup_binding_unverified"
        previous = self.bindings.get(profile.token)
        if previous is not None and previous != candidate:
            return None, "profile_config_changed"
        self.bindings[profile.token] = candidate
        duplicates = {token for token, binding in self.bindings.items()
                      if binding.fingerprint == candidate.fingerprint}
        if len(duplicates) > 1:
            self.ambiguous_tokens.update(duplicates)
        if profile.token in self.ambiguous_tokens:
            return None, "ambiguous_config_ownership"
        return candidate, ""

    def get(self, profile):
        if profile is None or profile.token in self.ambiguous_tokens:
            return None
        binding = self.bindings.get(profile.token)
        return binding if binding is not None and binding.profile == profile else None
