#!/usr/bin/python3
"""Persist minimal WorkBuddy lifecycle state for YaYa Status. Never block WorkBuddy."""

import hashlib
import json
import os
import sys
import tempfile
import time
from pathlib import Path

ALLOWED_EVENTS = {
    "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
    "PermissionRequest", "Notification", "Stop", "SessionEnd", "Interrupt",
}


def state_for(payload):
    event = payload.get("hook_event_name") or payload.get("hookEventName")
    if event not in ALLOWED_EVENTS:
        return None
    tool = str(payload.get("tool_name") or payload.get("toolName") or "")
    if event == "Stop":
        return "completed"
    if event == "SessionEnd":
        return "unknown"
    if event == "Interrupt":
        return "interrupted"
    if event == "PermissionRequest":
        return "waiting"
    if event == "Notification":
        kind = str(payload.get("notification_type") or payload.get("notificationType") or "").lower()
        return "waiting" if any(word in kind for word in ("permission", "approval", "confirm", "credential")) else None
    if event == "PreToolUse" and any(word in tool for word in ("request_user_input", "AskUserQuestion")):
        return "waiting"
    if event == "PostToolUse" and "request_user_input_async" in tool:
        return None
    return "working"


def main():
    try:
        payload = json.loads(sys.stdin.buffer.read(65536) or b"{}")
        if not isinstance(payload, dict):
            return
        session_id = payload.get("session_id") or payload.get("sessionId")
        state = state_for(payload)
        if not isinstance(session_id, str) or not session_id or len(session_id) > 255 or state is None:
            return
        directory = Path.home() / "Library/Application Support/YaYaStatus/workbuddy-sessions"
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        filename = hashlib.sha256(session_id.encode("utf-8")).hexdigest() + ".json"
        target = directory / filename
        try:
            previous = json.loads(target.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            previous = {}
        event = payload.get("hook_event_name") or payload.get("hookEventName")
        if event == "SessionEnd" and previous.get("state") in ("completed", "failed", "interrupted"):
            return
        now = time.time()
        previous_active = previous.get("state") in ("working", "waiting")
        started_at = previous.get("started_at") if previous_active else None
        if not isinstance(started_at, (int, float)) or event == "UserPromptSubmit":
            started_at = now if state in ("working", "waiting") else None
        record = {
            "session_id": session_id, "state": state, "recorded_at": now,
            "started_at": started_at,
            "ended_at": now if state in ("completed", "failed", "interrupted") else None,
        }
        data = json.dumps(record, separators=(",", ":"))
        fd, temporary = tempfile.mkstemp(prefix=".yayastatus-", dir=directory)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as output:
                output.write(data)
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    except Exception:
        pass


if __name__ == "__main__":
    print("{}", flush=True)
    main()
