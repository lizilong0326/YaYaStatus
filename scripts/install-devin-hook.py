#!/usr/bin/env python3
"""Merge YaYa Status lifecycle hooks into the user's Devin CLI/Desktop config."""

import json
import os
import shutil
import tempfile
from datetime import datetime
from pathlib import Path


config = Path.home() / ".config/devin/config.json"
handler = config.with_name("yayastatus-devin-hook.py")
source = Path(__file__).with_name("devin-hook.py")
events = ("UserPromptSubmit", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd")

if not Path("/Applications/Devin.app").is_dir() and not config.is_file():
    raise SystemExit("未找到 Devin 安装；未修改配置")
original = config.read_bytes() if config.is_file() else None
settings = json.loads(original) if original is not None else {}
if not isinstance(settings, dict):
    raise SystemExit("Devin 配置格式不兼容；未修改配置")
hooks = settings.setdefault("hooks", {})
if not isinstance(hooks, dict):
    raise SystemExit("Devin hooks 字段不是对象；未修改配置")
for event in events:
    if event in hooks and not isinstance(hooks[event], list):
        raise SystemExit(f"Devin {event} 配置格式不兼容；未修改配置")

command = str(handler)
for event in events:
    entries = hooks.setdefault(event, [])
    if not any(isinstance(entry, dict) and isinstance(entry.get("hooks"), list)
               and any(isinstance(item, dict) and
                       "yayastatus-devin-hook.py" in str(item.get("command", ""))
                       for item in entry["hooks"]) for entry in entries):
        entries.append({"matcher": "", "hooks": [{"type": "command", "command": command, "timeout": 3}]})

updated = (json.dumps(settings, ensure_ascii=False, indent=2) + "\n").encode()
config.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
if updated != original:
    if original is not None:
        backup = config.with_name("config.json.yayastatus-backup-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(config, backup)
        print("原配置备份：", backup)
    descriptor, temporary = tempfile.mkstemp(prefix=".yayastatus-devin-", dir=config.parent)
    try:
        os.fchmod(descriptor, config.stat().st_mode & 0o777 if original is not None else 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(updated)
        os.replace(temporary, config)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
shutil.copy2(source, handler)
handler.chmod(0o700)
print("Devin Hook 已安装；若 Devin 正在运行，请等当前任务结束后退出并重开，再提交新任务")
