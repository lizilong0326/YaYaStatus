# Devin 与 Gemini 桌面任务接入

## Devin Desktop

丫丫状态只读 `~/Library/Application Support/Devin/User/globalStorage/state.vscdb` 的本地 ACP 会话索引，并从对应的 `acp-messages/*.db` 读取会话标题。**历史会话只有“仅会话”状态**，不会因为窗口打开或文件刚更新就算作运行中。

运行 `python3 scripts/install-devin-hook.py` 后，安装脚本备份并合并 `~/.config/devin/config.json`，把事件处理器复制到同目录。Devin 的 `UserPromptSubmit` 表示开始一轮，`PostToolUse` 刷新工作心跳，`PermissionRequest` 表示等待操作，`Stop` 表示该轮已完成，`SessionEnd` 表示会话结束。事件文件保存在 `~/Library/Application Support/YaYaStatus/devin/sessions/`，只含会话 ID、轮次 ID、状态和时间；提示词、回复、工具参数与工具输出不会写入事件文件。监控脚本出错时直接退出，不阻塞 Devin。

安装后需要**新提交**一个 Devin 本地任务，已有任务不会补出开始事件；如果新任务仍没有事件，可重启 Devin 后再试。五分钟没有新的事件时，“工作中”降为“状态未知”；关闭 Devin 应用时也会降为未知。点击列表中的任务只打开 Devin 应用，不保证定位到具体会话。云端 Devin 任务以及在 Devin 中运行的其他 ACP 代理尚未验证。

可运行 `python3 scripts/uninstall-devin-hook.py` 移除本项目 Hook。卸载前会备份配置，其他 Hook 保留，历史事件文件仍留在本机。

[Devin 官方生命周期 Hook 文档](https://docs.devin.ai/cli/extensibility/hooks/lifecycle-hooks.md)明确这些事件也在 Desktop 触发；本机安装后的真实新任务回调仍需验证。

## Gemini 桌面版

丫丫状态只读 `~/.gemini/antigravity/conversation_summaries.db` 中 `app_data_dir = antigravity` 的本机任务摘要。运行或等待状态需同时满足应用仍在运行、摘要最近五分钟内更新；超时显示“状态未知”。明确的空闲、完成、失败或中止状态显示相应结果。任务标题与时间从摘要读取，不读取对话步骤正文。

这部分覆盖的是写入本机任务摘要的 Gemini 桌面任务。普通聊天、云端运行但尚未同步到本机的任务不会进入列表。没有公开、稳定的桌面任务状态 API；客户端升级后本地字段可能变化。设置页会显示当前读取结果，点击任务只打开 Gemini 应用。

[Google 对 Gemini Mac 后台任务的介绍](https://blog.google/innovation-and-ai/products/gemini-app/computer-use-mac/)说明了桌面任务能力；本项目的本地摘要读取方式是针对当前安装版本的实现，并非 Google 提供的公开集成接口。
