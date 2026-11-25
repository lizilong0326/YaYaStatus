#!/usr/bin/env python3
"""Remove only YaYa Status entries from the user's Devin hooks."""

import json
import os
import shutil
import tempfile
from datetime import datetime
from pathlib import Path


config = Path.home() / ".config/devin/config.json"
handler = config.with_name("yayastatus-devin-hook.py")
if not config.is_file():
    raise SystemExit("未找到 Devin 配置，无需移除")
original = config.read_bytes()
settings = json.loads(original)
if not isinstance(settings, dict) or not isinstance(settings.get("hooks"), dict):
    raise SystemExit("Devin hooks 格式不兼容；未修改配置")
hooks = settings["hooks"]
for event in ("UserPromptSubmit", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd"):
    entries = hooks.get(event)
    if not isinstance(entries, list):
        continue
    kept = []
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("hooks"), list):
            kept.append(entry)
            continue
        own = [item for item in entry["hooks"] if not (
            isinstance(item, dict) and "yayastatus-devin-hook.py" in str(item.get("command", ""))
        )]
        if own:
            kept.append({**entry, "hooks": own})
    if kept:
        hooks[event] = kept
    else:
        hooks.pop(event, None)
if not hooks:
    settings.pop("hooks", None)
updated = (json.dumps(settings, ensure_ascii=False, indent=2) + "\n").encode()
if updated != original:
    backup = config.with_name("config.json.yayastatus-backup-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(config, backup)
    descriptor, temporary = tempfile.mkstemp(prefix=".yayastatus-devin-", dir=config.parent)
    try:
        os.fchmod(descriptor, config.stat().st_mode & 0o777)
        with os.fdopen(descriptor, "wb") as output:
            output.write(updated)
        os.replace(temporary, config)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print("原配置备份：", backup)
if handler.is_file():
    handler.unlink()
print("已移除丫丫状态的 Devin Hook；历史状态快照保留")
