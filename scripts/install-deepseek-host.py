#!/usr/bin/env python3
"""Register the DeepSeek bridge for one unpacked Chrome extension ID."""

import argparse
import json
import os
import re
import shlex
import shutil
from datetime import datetime
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("extension_id", help="Chrome extension ID shown on chrome://extensions")
args = parser.parse_args()
if not re.fullmatch(r"[a-p]{32}", args.extension_id):
    parser.error("扩展 ID 必须是 Chrome 显示的 32 位 a-p 字符串")

support = Path.home() / "Library/Application Support/YaYaStatus/deepseek"
support.mkdir(mode=0o700, parents=True, exist_ok=True)
host = support / "native-host.py"
launcher = support / "native-host.sh"
shutil.copy2(Path(__file__).with_name("deepseek-native-host.py"), host)
host.chmod(0o700)
launcher.write_text("#!/bin/sh\nexec /usr/bin/python3 " + shlex.quote(str(host)) + "\n")
launcher.chmod(0o700)

manifest_dir = Path.home() / "Library/Application Support/Google/Chrome/NativeMessagingHosts"
manifest_dir.mkdir(parents=True, exist_ok=True)
manifest = manifest_dir / "com.local.yayastatus.deepseek.json"
if manifest.exists():
    backup = manifest.with_name(manifest.name + ".backup-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(manifest, backup)
    print("原桥接配置备份：", backup)
payload = {
    "name": "com.local.yayastatus.deepseek",
    "description": "Local DeepSeek tab status for YaYa Status",
    "path": str(launcher),
    "type": "stdio",
    "allowed_origins": [f"chrome-extension://{args.extension_id}/"],
}
manifest.write_text(json.dumps(payload, indent=2) + "\n")
os.chmod(manifest, 0o600)
print("本机桥接已注册：", manifest)
