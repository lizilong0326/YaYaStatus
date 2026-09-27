#!/usr/bin/env python3
"""Remove only YaYa Status handlers from WorkBuddy settings."""

import json
import os
import shutil
import tempfile
from datetime import datetime
from pathlib import Path

settings_path = Path.home() / ".workbuddy/settings.json"
hook_path = Path.home() / ".workbuddy/hooks/yayastatus-workbuddy.py"

if not settings_path.is_file():
    raise SystemExit("未找到 WorkBuddy 设置文件；未做修改")

original = settings_path.read_bytes()
settings = json.loads(original)
hooks = settings.get("hooks")
if not isinstance(hooks, dict):
    raise SystemExit("WorkBuddy hooks 格式不兼容；未做修改")

removed = 0
for event, groups in list(hooks.items()):
    if not isinstance(groups, list):
        continue
    preserved = []
    for group in groups:
        if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
            preserved.append(group)
            continue
        handlers = []
        for handler in group["hooks"]:
            if isinstance(handler, dict) and "yayastatus-workbuddy.py" in str(handler.get("command", "")):
                removed += 1
            else:
                handlers.append(handler)
        if handlers:
            preserved.append({**group, "hooks": handlers})
    if preserved:
        hooks[event] = preserved
    else:
        del hooks[event]

if removed:
    backup = settings_path.with_name("settings.json.yayastatus-backup-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(settings_path, backup)
    fd, temporary = tempfile.mkstemp(prefix=".yayastatus-settings-", dir=settings_path.parent)
    try:
        os.fchmod(fd, settings_path.stat().st_mode & 0o777)
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(settings, output, ensure_ascii=False, indent=2)
            output.write("\n")
        os.replace(temporary, settings_path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    hook_path.unlink(missing_ok=True)
    print(f"已移除 {removed} 个丫丫状态 Hook；原设置备份：{backup}")
else:
    print("未找到丫丫状态 Hook；未做修改")
