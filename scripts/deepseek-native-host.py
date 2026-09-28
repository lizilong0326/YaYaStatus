#!/usr/bin/env python3
"""Chrome native messaging host: persist only DeepSeek tab metadata locally."""

import json
import os
import re
import struct
import sys
import tempfile
import time
from pathlib import Path

directory = Path.home() / "Library/Application Support/YaYaStatus/deepseek/tabs"
uuid_pattern = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


def read_exact(count):
    result = bytearray()
    while len(result) < count:
        chunk = sys.stdin.buffer.read(count - len(result))
        if not chunk:
            return None
        result.extend(chunk)
    return bytes(result)


def respond(ok):
    payload = json.dumps({"ok": ok}).encode("utf-8")
    sys.stdout.buffer.write(struct.pack("<I", len(payload)) + payload)
    sys.stdout.buffer.flush()


def handle(message):
    tab_id = message.get("tabID")
    if type(tab_id) is not int or not 0 < tab_id < 2**31:
        return False
    target = directory / f"{tab_id}.json"
    if message.get("kind") == "close":
        target.unlink(missing_ok=True)
        return True
    if message.get("kind") != "snapshot":
        return False
    conversation_id = message.get("conversationID")
    title = message.get("title")
    state = message.get("state")
    if not isinstance(conversation_id, str) or not uuid_pattern.fullmatch(conversation_id):
        return False
    if not isinstance(title, str) or len(title) > 100:
        return False
    if state not in ("working", "ended", "unknown"):
        return False
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    record = {
        "tabID": tab_id,
        "conversationID": conversation_id,
        "title": title or "DeepSeek 会话",
        "state": state,
        "updatedAt": time.time(),
    }
    fd, temporary = tempfile.mkstemp(prefix=".deepseek-", dir=directory)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(record, stream, ensure_ascii=False)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return True


def main():
    header = read_exact(4)
    if not header:
        return
    size = struct.unpack("<I", header)[0]
    if size > 65536:
        respond(False)
        return
    payload = read_exact(size)
    try:
        message = json.loads(payload) if payload else None
        respond(handle(message) if isinstance(message, dict) else False)
    except (ValueError, OSError, TypeError):
        respond(False)


if __name__ == "__main__":
    main()
