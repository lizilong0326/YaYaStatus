import Foundation
import SQLite3

private struct KimiConversation: Sendable {
    let key: String
    let title: String
    let recordsPath: String?
    let updatedAt: Date
}

private actor KimiWorkReader {
    private let databaseURL: URL
    private let runtimeRoot: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let base = home.appendingPathComponent("Library/Application Support/kimi-desktop/daimon-share/daimon")
        databaseURL = base.appendingPathComponent("agents/main/sessions/hosted-logical/conversations.sqlite")
        runtimeRoot = base.appendingPathComponent("runtime/kimi-code/home/sessions", isDirectory: true)
    }

    func readRecent(limit: Int) throws -> [MonitoredTask] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        let rows = try readConversationRows(limit: limit)
        let appURL = URL(fileURLWithPath: "/Applications/Kimi.app", isDirectory: true)
        let canOpenApp = FileManager.default.fileExists(atPath: appURL.path)
        return rows.map { conversation in
            let status = runtimeState(for: conversation.recordsPath)
            return MonitoredTask(
                source: .kimiWork,
                sourceTaskID: conversation.key,
                title: conversation.title,
                state: status,
                updatedAt: conversation.updatedAt,
                openURL: canOpenApp ? appURL : nil,
                openScope: canOpenApp ? .application : .unavailable
            )
        }
    }

    private func readConversationRows(limit: Int) throws -> [KimiConversation] {
        var db: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, db != nil else {
            if let db { sqlite3_close(db) }
            throw NSError(domain: "KimiWorkReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法只读打开 Kimi Work 会话库"])
        }
        defer { if let db { sqlite3_close(db) } }
        let sql = """
            SELECT conversation_key, COALESCE(NULLIF(title, ''), '未命名任务'),
                   kernel_records_path, COALESCE(updated_at_ms, created_at_ms, 0)
            FROM conversations
            WHERE conversation_key IS NOT NULL AND conversation_key != ''
            ORDER BY updated_at_ms DESC
            LIMIT ?;
            """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            sqlite3_close(db)
            db = nil
            let fallback = sqlite3_open_v2(
                "file:\(databaseURL.path)?immutable=1",
                &db,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX,
                nil
            )
            guard fallback == SQLITE_OK, db != nil,
                  sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw NSError(domain: "KimiWorkReader", code: 2, userInfo: [NSLocalizedDescriptionKey: "Kimi Work 会话表格式不兼容"])
            }
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(min(100, max(1, limit))))
        var rows: [KimiConversation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let keyText = sqlite3_column_text(statement, 0) else { continue }
            rows.append(KimiConversation(
                key: String(cString: keyText),
                title: sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "未命名任务",
                recordsPath: sqlite3_column_text(statement, 2).map { String(cString: $0) },
                updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1000)
            ))
        }
        return rows
    }

    private func runtimeState(for rawPath: String?) -> MonitoredTaskState {
        guard let rawPath else { return .unknown }
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard path.path.hasPrefix(runtimeRoot.standardizedFileURL.path + "/"),
              path.lastPathComponent == "wire.jsonl",
              let handle = try? FileHandle(forReadingFrom: path) else { return .unknown }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return .unknown }
        let length: UInt64 = 512 * 1024
        let offset = fileSize > length ? fileSize - length : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: Int(length)),
              let text = String(data: data, encoding: .utf8) else { return .unknown }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        var state: MonitoredTaskState = .unknown
        for line in lines {
            guard let bytes = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let type = record["type"] as? String else { continue }
            if type == "turn.prompt" {
                state = .working
            } else if type == "context.append_loop_event",
                      let event = record["event"] as? [String: Any],
                      event["type"] as? String == "step.end" {
                switch event["finishReason"] as? String {
                case "end_turn": state = .completed
                case "tool_use": state = .working
                default: break
                }
            }
        }
        if state == .working {
            let modified = (try? path.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, Date().timeIntervalSince(modified) < 3 * 60 else { return .unknown }
        }
        return state
    }
}

@MainActor
final class KimiWorkStatusStore {
    private let collection: TaskCollectionStore
    private let reader = KimiWorkReader()
    private var pollTask: Task<Void, Never>?

    init(collection: TaskCollectionStore) {
        self.collection = collection
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                let hasActive = self.collection.tasks.contains { $0.source == .kimiWork && $0.state == .working }
                try? await Task.sleep(nanoseconds: (hasActive ? 3 : 20) * 1_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        do {
            let tasks = try await reader.readRecent(limit: TaskCollectionStore.recentTaskLimit)
            collection.replaceTasks(from: .kimiWork, with: tasks)
            collection.setConnection(SourceConnection(
                source: .kimiWork,
                state: .limited,
                detail: "只读会话状态；点击打开 Kimi 应用",
                observedAt: .now
            ))
        } catch {
            collection.setConnection(SourceConnection(
                source: .kimiWork,
                state: .unavailable,
                detail: error.localizedDescription,
                observedAt: collection.connections[.kimiWork]?.observedAt
            ))
        }
    }
}
