import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/cursor-hook.py"
INSTALL = SCRIPT.with_name("install-cursor-hook.py")
UNINSTALL = SCRIPT.with_name("uninstall-cursor-hook.py")


class CursorHookTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        self.root = Path(self.home.name)

    def send(self, event, generation="generation-1", **fields):
        payload = {
            "hook_event_name": event,
            "conversation_id": "conversation-1",
            "generation_id": generation,
            "workspace_roots": ["/work/project"],
            **fields,
        }
        result = subprocess.run(
            [sys.executable, str(SCRIPT)], input=json.dumps(payload), text=True,
            capture_output=True, check=True, env={**os.environ, "HOME": str(self.root)},
        )
        return json.loads(result.stdout)

    def record(self, generation="generation-1"):
        key = hashlib.sha256(("conversation-1:" + generation).encode()).hexdigest()
        path = self.root / "Library/Application Support/YaYaStatus/cursor/sessions" / (key + ".json")
        return json.loads(path.read_text())

    def test_each_generation_has_independent_lifecycle_and_no_full_prompt(self):
        prompt = "修改任务列表 " + "敏感正文" * 100
        self.assertEqual(self.send("beforeSubmitPrompt", prompt=prompt), {"continue": True})
        first = self.record()
        self.assertEqual(first["state"], "working")
        self.assertEqual(first["workspace"], "project")
        self.assertLessEqual(len(first["title"]), 96)
        self.assertNotIn(prompt, json.dumps(first, ensure_ascii=False))

        self.send("postToolUse")
        self.assertEqual(self.record()["startedAt"], first["startedAt"])
        self.send("stop", status="completed")
        self.assertEqual(self.record()["state"], "completed")
        self.send("sessionEnd", reason="window_close")
        self.assertEqual(self.record()["state"], "completed")

        self.send("beforeSubmitPrompt", generation="generation-2", prompt="第二轮")
        self.assertEqual(self.record("generation-2")["state"], "working")
        self.assertEqual(self.record()["state"], "completed")
        self.send("stop", generation="generation-2", status="aborted")
        self.assertEqual(self.record("generation-2")["state"], "interrupted")

    def test_error_and_unrecognized_event(self):
        self.send("beforeSubmitPrompt", prompt="失败任务")
        self.send("stop", status="error")
        self.assertEqual(self.record()["state"], "failed")
        self.send("postToolUse")
        self.assertEqual(self.record()["state"], "failed")
        self.send("unrelated", prompt="ignored")
        self.assertEqual(self.record()["state"], "failed")

    def test_install_preserves_other_hooks_and_is_idempotent(self):
        config = self.root / ".cursor/hooks.json"
        config.parent.mkdir()
        config.write_text(json.dumps({
            "version": 1, "hooks": {"stop": [{"command": "./hooks/existing.sh"}]}
        }))
        env = {**os.environ, "HOME": str(self.root)}
        for _ in range(2):
            subprocess.run([sys.executable, str(INSTALL)], env=env, check=True, capture_output=True)
        hooks = json.loads(config.read_text())["hooks"]
        self.assertEqual(len(hooks), 6)
        self.assertEqual(hooks["stop"][0], {"command": "./hooks/existing.sh"})
        self.assertEqual(len(hooks["stop"]), 2)
        subprocess.run([sys.executable, str(UNINSTALL)], env=env, check=True, capture_output=True)
        self.assertEqual(json.loads(config.read_text())["hooks"], {
            "stop": [{"command": "./hooks/existing.sh"}]
        })


if __name__ == "__main__":
    unittest.main()
