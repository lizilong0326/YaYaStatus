#!/usr/bin/env python3
"""Remove only YaYa Status hooks from the user's Cursor configuration."""

import json
import os
import shutil
import tempfile
from datetime import datetime
from pathlib import Path


config = Path.home() / ".cursor/hooks.json"
handler = Path.home() / ".cursor/hooks/yayastatus-cursor.py"
if not config.is_file():
    raise SystemExit("未找到 Cursor hooks.json；未做修改")
original = config.read_bytes()
settings = json.loads(original)
hooks = settings.get("hooks")
if not isinstance(hooks, dict):
    raise SystemExit("Cursor hooks 配置格式不兼容；未做修改")
removed = 0
for event, entries in list(hooks.items()):
    if not isinstance(entries, list):
        continue
    kept = [entry for entry in entries if not (
        isinstance(entry, dict) and "yayastatus-cursor.py" in str(entry.get("command", ""))
    )]
    removed += len(entries) - len(kept)
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]
if removed:
    backup = config.with_name("hooks.json.yayastatus-backup-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(config, backup)
    fd, temporary = tempfile.mkstemp(prefix=".yayastatus-hooks-", dir=config.parent)
    try:
        os.fchmod(fd, config.stat().st_mode & 0o777)
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(settings, output, ensure_ascii=False, indent=2)
            output.write("\n")
        os.replace(temporary, config)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    handler.unlink(missing_ok=True)
    print(f"已移除 {removed} 个丫丫状态 Hook；原配置备份：{backup}")
else:
    print("未找到丫丫状态 Hook；未做修改")
