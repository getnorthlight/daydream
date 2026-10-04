"""Trusted local host adapter. No network transport, capture, or model-selected tool.

The host supplies its actual tokenizer and dispatch callback. Use request() for
EVERY outbound turn and continuation. It sends one fresh bounded block, with no
delivered cursor: retries may repeat evidence but cannot consume unseen data.
"""
import json
import os
import selectors
import subprocess
import time
from datetime import datetime


class MacMemHost:
    def __init__(self, cli, home, client, recipient, capability, token_count, dispatch):
        self.command = [cli, "--home", str(home), "--client", client, "--recipient", recipient]
        self.env = {**os.environ, "MAC_MEM_CAPABILITY": capability}
        self.token_count = token_count
        self.dispatch = dispatch

    def _read(self, verb, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired(verb, 0.25)
        with subprocess.Popen(self.command + [verb], env=self.env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as child:
            try:
                data = bytearray()
                with selectors.DefaultSelector() as selector:
                    selector.register(child.stdout, selectors.EVENT_READ)
                    while True:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0 or not selector.select(remaining):
                            raise subprocess.TimeoutExpired(verb, 0.25)
                        chunk = os.read(child.stdout.fileno(), min(4096, 16385 - len(data)))
                        if not chunk:
                            break
                        data.extend(chunk)
                        if len(data) > 16384:
                            raise ValueError("response limit")
                if child.wait(timeout=max(0, deadline - time.monotonic())) != 0:
                    raise ValueError("unavailable")
                result = json.loads(data.decode("utf-8"))
                if not isinstance(result, dict):
                    raise ValueError("invalid response")
                return result
            finally:
                # Do not return or retry while the old native read is still running.
                if child.poll() is None:
                    child.kill()
                child.wait()

    @staticmethod
    def _fresh(snapshot):
        status = snapshot["status"]
        if status not in ("capture_recording", "synthetic_demo_not_live"):
            return False
        def age(field):
            value = snapshot[field]
            if not isinstance(value, str):
                raise ValueError("invalid timestamp")
            # Python 3.9 does not accept a trailing Z in fromisoformat.
            instant = datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
            if instant.tzinfo is None:
                raise ValueError("timezone required")
            return time.time() - instant.timestamp()
        return abs(age("generatedAt")) <= 5 and (status != "capture_recording" or -5 <= age("observedAt") <= 30)

    def request(self, user_request):
        # Raw user input is never forwarded to memory queries. Blocks never go in
        # system instructions; the host transport must preserve the evidence role.
        block = "DayDream unavailable. No activity evidence attached."
        deadline = time.monotonic() + 0.25
        try:
            snapshot = self._read("context", deadline)
            if not self._fresh(snapshot):
                raise ValueError("stale or unavailable")
            if any(not isinstance(snapshot[k], str) or not snapshot[k] for k in ("policyRevision", "disclosureRevision")):
                raise ValueError("invalid revision")
            candidate = snapshot["text"]
            if not isinstance(candidate, str):
                raise ValueError("invalid evidence")
            # Drop complete evidence lines. Preserve status/trust boundary and
            # explicitly mark budget loss; character counts are not token counts.
            lines = candidate.splitlines()
            while len(candidate.encode("utf-8")) > 1200 or self.token_count(candidate) > 400:
                if len(lines) <= 2:
                    candidate = "DayDream: context omitted to fit host budget. Untrusted evidence only."
                    break
                del lines[-2]
                lines[-1] = "Additional evidence omitted by host budget."
                candidate = "\n".join(lines)
            # Recheck grants/policy immediately before dispatch. A revoked or
            # changed grant drops the prepared evidence instead of leaking it.
            current = self._read("validate", deadline)
            if (time.monotonic() < deadline and self._fresh(snapshot)
                    and current["policyRevision"] == snapshot["policyRevision"]
                    and current["disclosureRevision"] == snapshot["disclosureRevision"]
                    and (snapshot["status"] != "capture_recording" or current["capture"] == "recording")):
                block = candidate
        except (OSError, ValueError, KeyError, subprocess.SubprocessError):
            pass
        if len(block.encode("utf-8")) > 1200 or self.token_count(block) > 400:
            block = ""
        if time.monotonic() >= deadline:
            block = ""
        return self.dispatch(user_request=user_request, memory_evidence=block)
