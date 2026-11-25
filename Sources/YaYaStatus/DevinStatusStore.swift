import AppKit
import Foundation
import SQLite3

private struct DevinSession: Sendable {
    let id: String
    let title: String
    let updatedAt: Date
}

private struct DevinHookSnapshot: Decodable, Sendable {
    let sessionID: String
    let promptID: String
    let state: MonitoredTaskState
    let recordedAt: Date
    let startedAt: Date?
    let endedAt: Date?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case promptID = "prompt_id"
        case state
        case recordedAt = "recorded_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        promptID = try values.decode(String.self, forKey: .promptID)
        state = try values.decode(MonitoredTaskState.self, forKey: .state)
        recordedAt = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .recordedAt))
        startedAt = try values.decodeIfPresent(Double.self, forKey: .startedAt).map(Date.init(timeIntervalSince1970:))
        endedAt = try values.decodeIfPresent(Double.self, forKey: .endedAt).map(Date.init(timeIntervalSince1970:))
    }
}

private actor DevinReader {
    private let storage: URL
    private let snapshots: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        storage = home.appendingPathComponent("Library/Application Support/Devin/User")
        snapshots = home.appendingPathComponent("Library/Application Support/YaYaStatus/devin/sessions")
    }

    func readRecent(limit: Int) throws -> ([DevinSession], [String: DevinHookSnapshot]) {
        let database = storage.appendingPathComponent("globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: database.path) else {
            throw NSError(domain: "DevinReader", code: 0, userInfo: [NSLocalizedDescriptionKey: "未找到 Devin 桌面会话库"])
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            throw NSError(domain: "DevinReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取 Devin 会话库"])
        }
        defer { sqlite3_close(db) }
        let sql = "SELECT key, value FROM ItemTable WHERE key LIKE 'windsurf.acp.messageStore.session.acp/devin-cli/%'"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "DevinReader", code: 2, userInfo: [NSLocalizedDescriptionKey: "Devin 会话索引格式不兼容"])
        }
        defer { sqlite3_finalize(statement) }
        var indexed: [(id: String, file: URL, updatedAt: Date)] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw NSError(domain: "DevinReader", code: 3, userInfo: [NSLocalizedDescriptionKey: "Devin 会话索引读取失败"])
            }
            guard let keyText = sqlite3_column_text(statement, 0),
                  let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let key = String(cString: keyText)
            let id = String(key.dropFirst("windsurf.acp.messageStore.session.acp/devin-cli/".count))
            guard !id.isEmpty, id.count < 128,
                  let value = try? JSONSerialization.jsonObject(
                    with: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
                  ) as? [String: Any],
                  let uuid = value["uuid"] as? String,
                  uuid.count == 40, uuid.allSatisfy(\.isHexDigit),
                  let milliseconds = value["lastUpdated"] as? NSNumber,
                  milliseconds.doubleValue > 0 else { continue }
            indexed.append((id, storage.appendingPathComponent("acp-messages/\(uuid).db"),
                            Date(timeIntervalSince1970: milliseconds.doubleValue / 1_000)))
        }
        let sessions = indexed.sorted { $0.updatedAt > $1.updatedAt }.prefix(max(1, limit)).compactMap { item -> DevinSession? in
            guard FileManager.default.fileExists(atPath: item.file.path) else { return nil }
            var title = "Devin 会话"
            var sessionDB: OpaquePointer?
            guard sqlite3_open_v2(item.file.path, &sessionDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let sessionDB else {
                if let sessionDB { sqlite3_close(sessionDB) }
                return nil
            }
            defer { sqlite3_close(sessionDB) }
            var count: OpaquePointer?
            guard sqlite3_prepare_v2(sessionDB, "SELECT value FROM meta WHERE key = 'message_count'", -1, &count, nil) == SQLITE_OK,
                  sqlite3_step(count) == SQLITE_ROW,
                  let countText = sqlite3_column_text(count, 0),
                  (Int(String(cString: countText)) ?? 0) > 0 else {
                if let count { sqlite3_finalize(count) }
                return nil
            }
            sqlite3_finalize(count)
            var info: OpaquePointer?
            if sqlite3_prepare_v2(sessionDB, "SELECT value FROM meta WHERE key = 'info'", -1, &info, nil) == SQLITE_OK,
               sqlite3_step(info) == SQLITE_ROW,
               let text = sqlite3_column_text(info, 0),
               let json = try? JSONSerialization.jsonObject(with: Data(String(cString: text).utf8)) as? [String: Any],
               let value = json["title"] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { title = String(trimmed.prefix(120)) }
            }
            if let info { sqlite3_finalize(info) }
            return DevinSession(id: item.id, title: title, updatedAt: item.updatedAt)
        }
        return (Array(sessions), readSnapshots())
    }

    private func readSnapshots() -> [String: DevinHookSnapshot] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        )) ?? []
        var result: [String: DevinHookSnapshot] = [:]
        for file in files where file.pathExtension == "json" {
            guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  size > 0, size < 4_096,
                  let data = try? Data(contentsOf: file),
                  let snapshot = try? JSONDecoder().decode(DevinHookSnapshot.self, from: data),
                  !snapshot.sessionID.isEmpty, snapshot.sessionID.count < 128,
                  !snapshot.promptID.isEmpty, snapshot.promptID.count < 128,
                  snapshot.recordedAt.timeIntervalSinceNow < 300 else { continue }
            let id = snapshot.sessionID.components(separatedBy: "/").last ?? snapshot.sessionID
            if result[id].map({ $0.recordedAt < snapshot.recordedAt }) ?? true {
                result[id] = snapshot
            }
        }
        return result
    }
}

@MainActor
final class DevinStatusStore {
    private let collection: TaskCollectionStore
    private let reader = DevinReader()
    private var pollTask: Task<Void, Never>?

    init(collection: TaskCollectionStore) { self.collection = collection }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                let active = self.collection.tasks(from: .devin).contains {
                    $0.state == .working || $0.state == .waiting
                }
                try? await Task.sleep(for: .seconds(active ? 2 : 12))
            }
        }
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

    func refresh() async {
        let manager = FileManager.default
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.exafunction.windsurf")
            ?? URL(fileURLWithPath: "/Applications/Devin.app", isDirectory: true)
        let hasApp = manager.fileExists(atPath: appURL.path)
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.exafunction.windsurf").isEmpty
        let config = manager.homeDirectoryForCurrentUser.appendingPathComponent(".config/devin/config.json")
        let handler = manager.homeDirectoryForCurrentUser.appendingPathComponent(".config/devin/yayastatus-devin-hook.py")
        let installed = manager.fileExists(atPath: handler.path) && Self.hasHook(config)
        do {
            let (sessions, snapshots) = try await reader.readRecent(limit: TaskCollectionStore.recentTaskLimit)
            let now = Date()
            var tasks = sessions.map { session in
                let snapshot = snapshots[session.id]
                let state: MonitoredTaskState
                if let snapshot {
                    let fresh = now.timeIntervalSince(snapshot.recordedAt) < 300
                    state = snapshot.state == .working && (!fresh || !running) ? .unknown : snapshot.state
                } else {
                    state = .sessionOnly
                }
                return MonitoredTask(
                    source: .devin,
                    sourceTaskID: "\(session.id):\(snapshot?.promptID ?? "history")",
                    title: session.title,
                    state: state,
                    updatedAt: max(session.updatedAt, snapshot?.recordedAt ?? .distantPast),
                    startedAt: snapshot?.startedAt,
                    endedAt: snapshot?.endedAt,
                    openURL: hasApp ? appURL : nil,
                    openScope: hasApp ? .application : .unavailable
                )
            }
            let ids = Set(sessions.map(\.id))
            for (id, snapshot) in snapshots where !ids.contains(id)
                && now.timeIntervalSince(snapshot.recordedAt) < 86_400 {
                let fresh = now.timeIntervalSince(snapshot.recordedAt) < 300
                let state: MonitoredTaskState = snapshot.state == .working && (!fresh || !running)
                    ? .unknown : snapshot.state
                tasks.append(MonitoredTask(
                    source: .devin, sourceTaskID: "\(id):\(snapshot.promptID)",
                    title: "Devin 任务", state: state, updatedAt: snapshot.recordedAt,
                    startedAt: snapshot.startedAt, endedAt: snapshot.endedAt,
                    openURL: hasApp ? appURL : nil,
                    openScope: hasApp ? .application : .unavailable
                ))
            }
            collection.replaceTasks(from: .devin, with: tasks)
            let hasEvent = snapshots.values.contains { now.timeIntervalSince($0.recordedAt) < 86_400 }
            let detail: String = !hasApp ? "未找到 Devin 桌面版"
                : !installed ? "会话可读；安装 Hook 后监控新任务运行状态"
                : !running ? "Hook 已安装；Devin 当前未运行"
                : hasEvent ? "本地任务事件可读；点击任务打开 Devin"
                : "Hook 已安装；等待下一条 Devin 任务"
            collection.setConnection(SourceConnection(
                source: .devin,
                state: !hasApp || !installed ? .setupRequired : (running && hasEvent ? .connected : .partial),
                detail: detail, observedAt: snapshots.values.map(\.recordedAt).max()
            ))
        } catch {
            collection.setConnection(SourceConnection(
                source: .devin, state: (error as NSError).domain == "DevinReader"
                    && (error as NSError).code == 0 ? .setupRequired : .unavailable,
                detail: error.localizedDescription,
                observedAt: collection.connections[.devin]?.observedAt
            ))
        }
    }

    private static func hasHook(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return ["UserPromptSubmit", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd"].allSatisfy { event in
            (hooks[event] as? [[String: Any]])?.contains { entry in
                (entry["hooks"] as? [[String: Any]])?.contains {
                    ($0["command"] as? String)?.contains("yayastatus-devin-hook.py") == true
                } == true
            } == true
        }
    }
}
