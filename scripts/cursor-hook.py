#!/usr/bin/env python3
"""Record minimal Cursor Agent lifecycle data without changing Agent behavior."""

import fcntl
import hashlib
import json
import os
import sys
import tempfile
import time
from pathlib import Path


EVENTS = {
    "beforeSubmitPrompt", "postToolUse", "afterAgentThought",
    "afterAgentResponse", "stop", "sessionEnd",
}


def clean_title(value):
    if not isinstance(value, str):
        return "Cursor Agent 任务"
    title = " ".join(value.split())[:96]
    return title or "Cursor Agent 任务"


def handle(payload):
    event = payload.get("hook_event_name")
    conversation_id = payload.get("conversation_id") or payload.get("session_id")
    if (event not in EVENTS or not isinstance(conversation_id, str)
            or not conversation_id or len(conversation_id) > 128):
        return
    generation_id = payload.get("generation_id")
    if not isinstance(generation_id, str) or not generation_id or len(generation_id) > 128:
        return
    directory = Path.home() / "Library/Application Support/YaYaStatus/cursor/sessions"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    basename = hashlib.sha256((conversation_id + ":" + generation_id).encode("utf-8")).hexdigest()
    target = directory / (basename + ".json")
    lock = directory / (basename + ".lock")
    with lock.open("a+b") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        try:
            previous = json.loads(target.read_text(encoding="utf-8"))
            if not isinstance(previous, dict):
                previous = {}
        except (OSError, ValueError):
            previous = {}
        now = time.time()
        old_state = previous.get("state")
        if event == "beforeSubmitPrompt":
            state = "working"
            started_at = now
            title = clean_title(payload.get("prompt"))
        elif event == "stop":
            state = {"completed": "completed", "aborted": "interrupted",
                     "error": "failed"}.get(payload.get("status"), "unknown")
            started_at = previous.get("startedAt")
            title = previous.get("title") or "Cursor Agent 任务"
        elif event == "sessionEnd":
            if old_state in ("completed", "interrupted", "failed"):
                return
            state = "unknown"
            started_at = previous.get("startedAt")
            title = previous.get("title") or "Cursor Agent 任务"
        else:
            if old_state in ("completed", "interrupted", "failed"):
                return
            state = "working"
            started_at = previous.get("startedAt") or now
            title = previous.get("title") or "Cursor Agent 任务"
        roots = payload.get("workspace_roots")
        workspace = previous.get("workspace") or ""
        if isinstance(roots, list) and roots and isinstance(roots[0], str):
            workspace = Path(roots[0]).name[:60]
        record = {
            "conversationID": conversation_id,
            "generationID": generation_id,
            "title": title,
            "workspace": workspace,
            "state": state,
            "recordedAt": now,
            "startedAt": started_at,
            "endedAt": now if state in ("completed", "interrupted", "failed") else None,
        }
        fd, temporary = tempfile.mkstemp(prefix=".yayastatus-cursor-", dir=directory)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as output:
                json.dump(record, output, ensure_ascii=False, separators=(",", ":"))
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)


if __name__ == "__main__":
    response = {}
    try:
        payload = json.loads(sys.stdin.buffer.read(262_144) or b"{}")
        if isinstance(payload, dict):
            response = {"continue": True} if payload.get("hook_event_name") == "beforeSubmitPrompt" else {}
            handle(payload)
    except Exception:
        pass  # Monitoring must never interrupt Cursor.
    print(json.dumps(response), flush=True)
