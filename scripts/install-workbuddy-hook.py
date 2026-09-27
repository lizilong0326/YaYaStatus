#!/usr/bin/env python3
"""Merge YaYa Status hooks into WorkBuddy settings, preserving a dated backup."""

import json
import os
import shutil
import shlex
import tempfile
from datetime import datetime
from pathlib import Path

root = Path(__file__).resolve().parents[1]
settings_path = Path.home() / ".workbuddy/settings.json"
hook_path = Path.home() / ".workbuddy/hooks/yayastatus-workbuddy.py"
events = (
    "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
    "PermissionRequest", "Notification", "Stop", "SessionEnd", "Interrupt",
)

if not settings_path.is_file():
    raise SystemExit("未找到 WorkBuddy 设置文件；未修改任何配置")

original = settings_path.read_bytes()
settings = json.loads(original)
if not isinstance(settings, dict):
    raise SystemExit("WorkBuddy 设置格式不是对象；未修改任何配置")

hooks = settings.setdefault("hooks", {})
if not isinstance(hooks, dict):
    raise SystemExit("WorkBuddy hooks 格式不兼容；未修改任何配置")

hook_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
shutil.copy2(root / "scripts/workbuddy-hook.py", hook_path)
hook_path.chmod(0o700)
command = "/usr/bin/python3 " + shlex.quote(str(hook_path))
for event in events:
    groups = hooks.setdefault(event, [])
    if not isinstance(groups, list):
        raise SystemExit(f"WorkBuddy {event} 配置格式不兼容；未修改设置文件")
    present = any(
        isinstance(group, dict) and any(
            isinstance(item, dict) and "yayastatus-workbuddy.py" in str(item.get("command", ""))
            for item in group.get("hooks", [])
        )
        for group in groups
    )
    if present:
        continue
    handler = {"type": "command", "command": command, "timeout": 3}
    if event != "SessionEnd":
        handler["async"] = True
    groups.append({"matcher": "", "hooks": [handler]})

updated = (json.dumps(settings, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
if updated != original:
    backup = settings_path.with_name("settings.json.yayastatus-backup-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(settings_path, backup)
    fd, temporary = tempfile.mkstemp(prefix=".yayastatus-settings-", dir=settings_path.parent)
    try:
        os.fchmod(fd, settings_path.stat().st_mode & 0o777)
        with os.fdopen(fd, "wb") as output:
            output.write(updated)
        os.replace(temporary, settings_path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print("已合并 WorkBuddy Hook；原设置备份：", backup)
else:
    print("WorkBuddy Hook 已存在，无需修改")
