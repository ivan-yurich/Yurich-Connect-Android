"""Shared profile controls and fail-closed native payload qualification."""

import time

from tooling.soak.native_observer import native_payload_probe, read_native_snapshot
from tooling.soak.native_profile_binding import NativeBindingRegistry


class ControlQueueNotQuiescent(RuntimeError):
    def __init__(self):
        super().__init__("control_queue_not_quiescent")


class BoundChecks:
    def __init__(self, runner, *, screen_off=True):
        self.runner = runner
        self.registry = NativeBindingRegistry()
        self.screen_off = screen_off
        self.control_verified = False
        self.pending_control = False

    def wait_for_control_completion(self, timeout_s=180):
        if not self.pending_control:
            return
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            status, error = self.runner.query_status(timeout_s=5)
            idle = bool(not error and isinstance(status, dict) and status.get("ok") is True
                        and status.get("busy") is False and status.get("queueActive") is False)
            self.runner.append_jsonl("control-queue.jsonl", {
                "idle": idle, "observed": bool(not error and status and status.get("ok") is True),
                "busy": status.get("busy") if isinstance(status, dict) else None,
                "queue_active": status.get("queueActive") if isinstance(status, dict) else None,
                "elapsed_s": self.runner.elapsed_s(),
            })
            if idle and time.monotonic() <= deadline:
                self.pending_control = False
                return
            time.sleep(min(2, max(0, deadline - time.monotonic())))
        raise ControlQueueNotQuiescent()

    def command(self, profile, command="activate", timeout_s=90):
        r = self.runner
        self.control_verified = False
        # A transport timeout does not cancel the app's asynchronous operation.
        # Never dispatch a new profile/reconnect until the previous one is idle.
        self.wait_for_control_completion()
        prior, _ = read_native_snapshot(r, version=3)
        r.current_profile = profile
        started = time.monotonic()
        fallbacks = r.bridge_foreground_fallbacks
        self.pending_control = True
        payload, error = r.bridge_request(
            command, profile.token if command == "activate" else None,
            timeout_s=timeout_s,
        )
        if self.screen_off:
            # Only control boundaries may bootstrap Flutter. Never do this in sample().
            r.shell("input", "keyevent", "KEYCODE_HOME")
            r.shell("input", "keyevent", "KEYCODE_SLEEP")
        binding_error = "command_failed"
        command_ok = not error and payload is not None and payload.get("ok") is True
        if command_ok:
            deadline = started + timeout_s
            while time.monotonic() < deadline:
                before, before_error = read_native_snapshot(r, version=3)
                if before and before.ready and not before_error:
                    status, status_error = r.query_status(timeout_s=5)
                    after, after_error = read_native_snapshot(r, version=3)
                    if not status_error and not after_error:
                        binding, binding_error = self.registry.accept(profile, before, status, after)
                        if binding is not None:
                            if time.monotonic() > deadline:
                                binding_error = "control_deadline_exceeded"
                            elif command == "reconnect" and prior and prior.identity == after.identity:
                                binding_error = "reconnect_session_unchanged"
                            else:
                                self.control_verified = True
                            break
                        if binding_error in {"profile_config_changed", "ambiguous_config_ownership"}:
                            break
                time.sleep(2)
        return {"command": command, "profile": profile.token, "kind": profile.kind,
                "network": r.current_network, "command_ok": command_ok,
                "control_error": error or (payload or {}).get("error", ""),
                "binding_verified": self.control_verified,
                "error": "" if self.control_verified else binding_error,
                "command_ms": round((time.monotonic() - started) * 1000),
                "foreground_fallbacks": r.bridge_foreground_fallbacks - fallbacks}

    def sample(self, source):
        binding = self.registry.get(self.runner.current_profile)
        row = native_payload_probe(self.runner, source, binding=binding)
        row["config_binding_required"] = True
        row["control_verified"] = self.control_verified
        if binding is None or not self.control_verified:
            row["pass"] = False
            row["config_binding_verified"] = False
            row["error"] = row["error"] or "profile_binding_unavailable"
        return row
