#!/usr/bin/env python3
"""Record only Devin task lifecycle metadata for YaYa Status."""

import hashlib
import json
import os
import sys
import tempfile
import time
from pathlib import Path


def main():
    event = json.load(sys.stdin)
    name = event.get("hook_event_name")
    if name not in {"UserPromptSubmit", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd"}:
        return
    session_id = event.get("session_id")
    if not isinstance(session_id, str) or not 0 < len(session_id) < 128:
        return
    directory = Path.home() / "Library/Application Support/YaYaStatus/devin/sessions"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    file = directory / (hashlib.sha256(session_id.encode()).hexdigest() + ".json")
    try:
        previous = json.loads(file.read_text())
    except (OSError, ValueError):
        previous = {}
    prompt_id = event.get("prompt_id") or previous.get("prompt_id") or "session"
    if not isinstance(prompt_id, str) or not 0 < len(prompt_id) < 128:
        return
    now = time.time()
    same_turn = previous.get("prompt_id") == prompt_id
    if name in {"PostToolUse", "PermissionRequest"} and (not same_turn or previous.get("state") not in {"working", "waiting"}):
        return
    if name == "UserPromptSubmit":
        state = "working"
        started_at = previous.get("started_at") if same_turn else now
        ended_at = None
    elif name in {"PostToolUse", "PermissionRequest"}:
        state = "waiting" if name == "PermissionRequest" else "working"
        started_at = previous.get("started_at")
        ended_at = None
    else:
        state = "completed" if name == "Stop" else "ended"
        started_at = previous.get("started_at") if same_turn else None
        ended_at = now
    snapshot = {
        "session_id": session_id,
        "prompt_id": prompt_id,
        "state": state,
        "recorded_at": now,
        "started_at": started_at,
        "ended_at": ended_at,
    }
    descriptor, temporary = tempfile.mkstemp(prefix=".yayastatus-", dir=directory)
    try:
        with os.fdopen(descriptor, "w") as output:
            json.dump(snapshot, output, separators=(",", ":"))
        os.chmod(temporary, 0o600)
        os.replace(temporary, file)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Monitoring must never interrupt Devin's task.
        pass
