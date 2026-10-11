# Cursor 任务进度接入

丫丫状态通过 [Cursor 官方 Agent Hooks](https://cursor.com/docs/hooks) 接收本机 Cursor 桌面版的 Agent 事件。Cursor 允许在 `~/.cursor/hooks.json` 配置用户级 Hook，适用于 Agent Chat 和 Cmd+K。安装后只观察**新提交**的任务；已有历史会话不会补读。

## 安装与验证

在本仓库运行：

```sh
python3 scripts/install-cursor-hook.py
```

脚本复制 `scripts/cursor-hook.py` 到 `~/.cursor/hooks/yayastatus-cursor.py`，并合并六个事件入口到 `~/.cursor/hooks.json`。如果原配置存在，先在同目录创建带时间戳的备份。重复运行不会重复添加处理器。然后在 Cursor 桌面版新提交一条 Agent 任务，打开丫丫状态设置页检查 Cursor 连接状态和任务列表。必要时重新打开 Cursor 工作区，让其加载新配置。

事件快照写在 `~/Library/Application Support/YaYaStatus/cursor/sessions/`。每轮任务由 Cursor 给出的 `conversation_id` 和 `generation_id` 唯一标识。快照只保留前 96 个字符的单行提示词标题、工作区名、状态与时间；不保存完整提示词、思考内容、工具参数、工具输出、邮箱或令牌。目录只供本机用户访问。

## 状态含义

| Cursor 事件 | 丫丫状态 |
| --- | --- |
| 提交提示词、Agent 的后续事件 | 工作中 |
| `stop.status = completed` | 已完成 |
| `stop.status = aborted` | 已中断 |
| `stop.status = error` | 报错 |
| 活动事件静默超过两分钟，或 Cursor 退出 | 状态未知 |

Cursor 的这些 Hook 没有稳定的“正在等待用户审批”信号，所以当前不会给 Cursor 任务显示“等待操作”。点任务只能打开 Cursor 应用，不能精确定位原会话。用户级 Hook 运行于本机，不覆盖云端 Agent；Tab 补全也不作为任务。首次安装后的第一条真实任务需要验证回调是否到达，手工模拟事件只能验证本项目的解析与显示。

Cursor 任务与其他来源一样，飞书通知默认关闭。若需要完成提醒，先在设置中开启飞书总开关，再为**当前进行中**的 Cursor 任务点亮铃铛。旧任务或已完成任务不会补发。

## 移除

```sh
python3 scripts/uninstall-cursor-hook.py
```

卸载脚本只移除本项目的事件处理器，保留其他 Cursor Hook，修改前也会备份配置。历史事件文件不会自动删除。若希望一起删除本机历史记录，可自行删除 `~/Library/Application Support/YaYaStatus/cursor/sessions/`。
