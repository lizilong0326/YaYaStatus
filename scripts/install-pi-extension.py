#!/usr/bin/env python3
"""Install the small Pi status extension without touching active Pi processes."""

import shutil
from datetime import datetime
from pathlib import Path

source = Path(__file__).with_name("yayastatus-pi.ts")
target = Path.home() / ".pi/agent/extensions/yayastatus-pi.ts"
target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)

if target.exists() and target.read_bytes() == source.read_bytes():
    print("Pi 扩展已安装，无需修改")
else:
    if target.exists():
        backup = target.with_name(target.name + ".backup-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(target, backup)
        print("原扩展备份：", backup)
    shutil.copy2(source, target)
    target.chmod(0o600)
    print("已安装 Pi 状态扩展：", target)
print("现有 Pi 进程不会被重启；在 Pi 中执行 /reload 或下次启动后接收实时事件")
