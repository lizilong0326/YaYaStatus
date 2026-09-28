import AppKit
import Foundation
import Darwin

private struct PiSessionSummary: Sendable {
    let id: String
    let cwd: String
    let title: String
    let updatedAt: Date
    let finalReason: String?
    let lastRole: String?
    let file: URL
}

private struct PiHookSnapshot: Decodable, Sendable {
    let sessionID: String
    let sessionFile: String
    let state: MonitoredTaskState
    let recordedAt: Date
    let pid: Int32

    enum CodingKeys: String, CodingKey {
        case sessionID, sessionFile, state, recordedAt, pid
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        sessionFile = try values.decode(String.self, forKey: .sessionFile)
        state = try values.decode(MonitoredTaskState.self, forKey: .state)
        recordedAt = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .recordedAt))
        pid = try values.decode(Int32.self, forKey: .pid)
    }
}

private actor PiAgentReader {
    private let sessionsDirectory: URL
    private let snapshotsDirectory: URL
    private var cache: [URL: (modifiedAt: Date, size: Int, summary: PiSessionSummary)] = [:]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        sessionsDirectory = home.appendingPathComponent(".pi/agent/sessions", isDirectory: true)
        snapshotsDirectory = home.appendingPathComponent(
            "Library/Application Support/YaYaStatus/pi/sessions", isDirectory: true
        )
    }

    func readRecent(limit: Int) throws -> ([PiSessionSummary], [String: PiHookSnapshot]) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionsDirectory.path) else { return ([], [:]) }
        let folders = try fileManager.contentsOfDirectory(
            at: sessionsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        var files: [(url: URL, modifiedAt: Date, size: Int)] = []
        for folder in folders {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            for file in (try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? [] where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let date = values?.contentModificationDate,
                      let size = values?.fileSize, size > 0, size < 30_000_000 else { continue }
                files.append((file, date, size))
            }
        }
        files.sort { $0.modifiedAt > $1.modifiedAt }
        var summaries: [PiSessionSummary] = []
        for file in files.prefix(max(1, limit)) {
            if let cached = cache[file.url], cached.modifiedAt == file.modifiedAt, cached.size == file.size {
                summaries.append(cached.summary)
            } else if let summary = try? parse(file: file.url, modifiedAt: file.modifiedAt) {
                cache[file.url] = (file.modifiedAt, file.size, summary)
                summaries.append(summary)
            }
        }
        cache = cache.filter { entry in files.prefix(max(1, limit)).contains { $0.url == entry.key } }
        return (summaries, readHookSnapshots())
    }

    private func parse(file: URL, modifiedAt: Date) throws -> PiSessionSummary {
        let data = try Data(contentsOf: file)
        var sessionID: String?
        var cwd: String?
        var name: String?
        var lastPrompt: String?
        var lastRole: String?
        var finalReason: String?
        var updatedAt = modifiedAt
        for line in data.split(separator: 10) where line.count < 2_000_000 {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            if type == "session" {
                sessionID = object["id"] as? String
                cwd = object["cwd"] as? String
            } else if type == "session_info" {
                name = object["name"] as? String
            } else if type == "message", let message = object["message"] as? [String: Any],
                      let role = message["role"] as? String {
                if role == "user" {
                    if let text = message["content"] as? String {
                        lastPrompt = text
                    } else if let blocks = message["content"] as? [[String: Any]] {
                        lastPrompt = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String
                    }
                }
                if role == "user" || role == "assistant" || role == "toolResult" { lastRole = role }
                if role == "assistant" { finalReason = message["stopReason"] as? String }
                if let timestamp = message["timestamp"] as? Double {
                    updatedAt = Date(timeIntervalSince1970: timestamp / 1_000)
                }
            }
        }
        guard let sessionID, UUID(uuidString: sessionID) != nil, let cwd, cwd.hasPrefix("/") else {
            throw NSError(domain: "PiAgentReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pi 会话格式不兼容"])
        }
        let workspace = URL(fileURLWithPath: cwd).lastPathComponent
        let prompt = (lastPrompt ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        let title: String
        if let name, !name.isEmpty {
            title = "\(workspace) · \(name)"
        } else if !prompt.isEmpty {
            title = "\(workspace) · \(String(prompt.prefix(56)))"
        } else {
            title = workspace
        }
        return PiSessionSummary(
            id: sessionID, cwd: cwd, title: title, updatedAt: updatedAt,
            finalReason: finalReason, lastRole: lastRole, file: file
        )
    }

    private func readHookSnapshots() -> [String: PiHookSnapshot] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: snapshotsDirectory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        )) ?? []
        var snapshots: [String: PiHookSnapshot] = [:]
        for file in files where file.pathExtension == "json" {
            guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  size < 4_096, let data = try? Data(contentsOf: file),
                  let snapshot = try? JSONDecoder().decode(PiHookSnapshot.self, from: data),
                  UUID(uuidString: snapshot.sessionID) != nil else { continue }
            snapshots[snapshot.sessionID] = snapshot
        }
        return snapshots
    }
}

@MainActor
final class PiAgentStatusStore {
    private let collection: TaskCollectionStore
    private let reader = PiAgentReader()
    private var pollTask: Task<Void, Never>?

    init(collection: TaskCollectionStore) { self.collection = collection }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                let active = self.collection.tasks.contains {
                    $0.source == .piAgent && ($0.state == .working || $0.state == .waiting)
                }
                try? await Task.sleep(nanoseconds: (active ? 2 : 8) * 1_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        do {
            let (sessions, hooks) = try await reader.readRecent(limit: TaskCollectionStore.recentTaskLimit)
            let fileManager = FileManager.default
            let hasVSCode = fileManager.fileExists(atPath: "/Applications/Visual Studio Code.app")
            let tasks = sessions.map { session in
                let hook = hooks[session.id].flatMap {
                    $0.sessionFile == session.file.path ? $0 : nil
                }
                let state = state(for: session, hook: hook)
                let canOpen = hasVSCode && fileManager.fileExists(atPath: session.cwd)
                var components = URLComponents()
                components.scheme = "vscode"
                components.host = "file"
                components.path = session.cwd.hasSuffix("/") ? session.cwd : session.cwd + "/"
                return MonitoredTask(
                    source: .piAgent, sourceTaskID: session.id,
                    title: session.title, state: state,
                    updatedAt: max(session.updatedAt, hook?.recordedAt ?? .distantPast),
                    openURL: canOpen ? components.url : nil,
                    openScope: canOpen ? .application : .unavailable
                )
            }
            collection.replaceTasks(from: .piAgent, with: tasks)
            let installed = fileManager.fileExists(atPath: fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".pi/agent/extensions/yayastatus-pi.ts").path)
            let recentHook = hooks.values.contains { Date().timeIntervalSince($0.recordedAt) < 24 * 60 * 60 }
            collection.setConnection(SourceConnection(
                source: .piAgent,
                state: recentHook ? .connected : .limited,
                detail: recentHook ? "Pi 扩展事件已到达；点击打开 VS Code 工作区" :
                    (installed ? "已安装 Pi 扩展；当前 Pi 会话需 /reload 或下次启动" : "只读 Pi 会话；安装扩展可获取实时状态"),
                observedAt: .now
            ))
        } catch {
            collection.setConnection(SourceConnection(
                source: .piAgent, state: .unavailable,
                detail: error.localizedDescription,
                observedAt: collection.connections[.piAgent]?.observedAt
            ))
        }
    }

    private func state(for session: PiSessionSummary, hook: PiHookSnapshot?) -> MonitoredTaskState {
        if let hook, hook.recordedAt >= session.updatedAt.addingTimeInterval(-10) {
            if hook.state == .working || hook.state == .waiting {
                let alive = kill(hook.pid, 0) == 0 || errno == EPERM
                if alive && Date().timeIntervalSince(hook.recordedAt) < 35 { return hook.state }
                return .unknown
            }
            return hook.state
        }
        guard session.lastRole == "assistant" else { return .unknown }
        switch session.finalReason {
        case "stop": return .completed
        case "error": return .failed
        case "aborted": return .interrupted
        default: return .unknown
        }
    }
}
