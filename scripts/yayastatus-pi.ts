// Pi lifecycle bridge. Stores only the session ID, file path, state, PID, and time.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const snapshotDirectory = join(homedir(), "Library/Application Support/YaYaStatus/pi/sessions");
type State = "working" | "waiting" | "completed" | "interrupted" | "failed" | "unknown";

export default function (pi: ExtensionAPI) {
  let state: State = "unknown";
  let lastReason: string | undefined;
  let heartbeat: ReturnType<typeof setInterval> | undefined;

  function save(ctx: { sessionManager: { getSessionId(): string; getSessionFile(): string | undefined } }) {
    const sessionID = ctx.sessionManager.getSessionId();
    const sessionFile = ctx.sessionManager.getSessionFile();
    if (!/^[0-9a-f-]{36}$/i.test(sessionID) || !sessionFile) return;
    mkdirSync(snapshotDirectory, { recursive: true, mode: 0o700 });
    const target = join(snapshotDirectory, `${sessionID}.json`);
    const temporary = join(snapshotDirectory, `.${sessionID}.${process.pid}.tmp`);
    const record = { sessionID, sessionFile, state, recordedAt: Date.now() / 1000, pid: process.pid };
    writeFileSync(temporary, JSON.stringify(record) + "\n", { mode: 0o600 });
    renameSync(temporary, target);
  }

  pi.on("session_start", (_event, ctx) => {
    if (heartbeat) clearInterval(heartbeat);
    state = "unknown";
    lastReason = undefined;
    heartbeat = setInterval(() => {
      if (state === "working" || state === "waiting") save(ctx);
    }, 10_000);
  });
  pi.on("agent_start", (_event, ctx) => {
    state = "working";
    lastReason = undefined;
    save(ctx);
  });
  pi.on("agent_end", (event) => {
    const assistant = [...event.messages].reverse().find(message => message.role === "assistant");
    if (assistant?.role === "assistant") lastReason = assistant.stopReason;
  });
  pi.on("ui_prompt_start", (_event, ctx) => {
    state = "waiting";
    save(ctx);
  });
  pi.on("ui_prompt_end", (_event, ctx) => {
    state = "working";
    save(ctx);
  });
  pi.on("agent_settled", (_event, ctx) => {
    state = lastReason === "error" ? "failed" : lastReason === "aborted" ? "interrupted" : "completed";
    save(ctx);
  });
  pi.on("session_shutdown", (_event, ctx) => {
    if (heartbeat) clearInterval(heartbeat);
    heartbeat = undefined;
    if (state === "working" || state === "waiting") {
      state = "unknown";
      save(ctx);
    }
  });
}
