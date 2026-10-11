#!/usr/bin/env python3
"""Merge YaYa Status event hooks into the user's Cursor configuration."""

import json
import os
import shutil
import tempfile
from datetime import datetime
from pathlib import Path


source = Path(__file__).with_name("cursor-hook.py")
config = Path.home() / ".cursor/hooks.json"
handler = Path.home() / ".cursor/hooks/yayastatus-cursor.py"
events = (
    "beforeSubmitPrompt", "postToolUse", "afterAgentThought",
    "afterAgentResponse", "stop", "sessionEnd",
)

if not (Path("/Applications/Cursor.app").is_dir() or (Path.home() / ".cursor").is_dir()):
    raise SystemExit("未找到 Cursor 安装；未修改配置")
original = config.read_bytes() if config.is_file() else None
settings = json.loads(original) if original is not None else {"version": 1, "hooks": {}}
if not isinstance(settings, dict) or settings.get("version") != 1:
    raise SystemExit("Cursor hooks.json 格式或版本不兼容；未修改配置")
hooks = settings.setdefault("hooks", {})
if not isinstance(hooks, dict):
    raise SystemExit("Cursor hooks 字段不是对象；未修改配置")
for event in events:
    if event in hooks and not isinstance(hooks[event], list):
        raise SystemExit(f"Cursor {event} 配置格式不兼容；未修改配置")

handler.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
shutil.copy2(source, handler)
handler.chmod(0o700)
command = "./hooks/yayastatus-cursor.py"
for event in events:
    entries = hooks.setdefault(event, [])
    if not any(isinstance(entry, dict) and
               "yayastatus-cursor.py" in str(entry.get("command", ""))
               for entry in entries):
        entries.append({"command": command, "timeout": 3})

updated = (json.dumps(settings, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
if updated != original:
    config.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if original is not None:
        backup = config.with_name("hooks.json.yayastatus-backup-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(config, backup)
        print("原配置备份：", backup)
    fd, temporary = tempfile.mkstemp(prefix=".yayastatus-hooks-", dir=config.parent)
    try:
        os.fchmod(fd, config.stat().st_mode & 0o777 if original is not None else 0o600)
        with os.fdopen(fd, "wb") as output:
            output.write(updated)
        os.replace(temporary, config)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print("已安装 Cursor Hook；新提交的 Agent 任务将写入状态事件")
else:
    print("Cursor Hook 已存在，无需修改配置")
