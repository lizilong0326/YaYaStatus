import AppKit
import Foundation
import SQLite3

private struct WorkBuddySession: Sendable {
    let id: String
    let title: String
    let status: String
    let updatedAt: Date
}

private struct WorkBuddyHookSnapshot: Decodable, Sendable {
    let sessionID: String
    let state: MonitoredTaskState
    let recordedAt: Date
    let startedAt: Date?
    let endedAt: Date?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case state
        case recordedAt = "recorded_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }
}

private actor WorkBuddyReader {
    private let databaseURL: URL
    private let snapshotDirectory: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        databaseURL = home.appendingPathComponent(".workbuddy/workbuddy.db")
        snapshotDirectory = home.appendingPathComponent(
            "Library/Application Support/YaYaStatus/workbuddy-sessions",
            isDirectory: true
        )
    }

    func readSessions(limit: Int) throws -> [WorkBuddySession] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw NSError(domain: "WorkBuddyReader", code: 0, userInfo: [NSLocalizedDescriptionKey: "未找到 WorkBuddy 会话库"])
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            if let db { sqlite3_close(db) }
            throw NSError(domain: "WorkBuddyReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取 WorkBuddy 会话：\(message)"])
        }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT id, COALESCE(NULLIF(custom_title, ''), NULLIF(title, ''), '未命名任务'),
                   COALESCE(status, ''), COALESCE(last_activity_at, updated_at, created_at, 0)
            FROM sessions
            WHERE deleted_at IS NULL AND id IS NOT NULL AND id != ''
            ORDER BY updated_at DESC
            LIMIT ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "WorkBuddyReader", code: 2, userInfo: [NSLocalizedDescriptionKey: "WorkBuddy 会话表格式不兼容"])
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(min(100, max(1, limit))))
        var result: [WorkBuddySession] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw NSError(domain: "WorkBuddyReader", code: 3, userInfo: [NSLocalizedDescriptionKey: "WorkBuddy 会话查询失败"])
            }
            guard let idText = sqlite3_column_text(statement, 0) else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "未命名任务"
            let status = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            let milliseconds = sqlite3_column_int64(statement, 3)
            result.append(WorkBuddySession(
                id: String(cString: idText),
                title: title,
                status: status,
                updatedAt: Date(timeIntervalSince1970: Double(milliseconds) / 1000)
            ))
        }
        return result
    }

    func readHookSnapshots() -> [String: WorkBuddyHookSnapshot] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: snapshotDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [:] }
        var result: [String: WorkBuddyHookSnapshot] = [:]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        for file in files.prefix(100) where file.pathExtension == "json" {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let size = attributes[.size] as? NSNumber, size.intValue < 8192,
                  let data = try? Data(contentsOf: file),
                  let snapshot = try? decoder.decode(WorkBuddyHookSnapshot.self, from: data),
                  snapshot.sessionID.count < 256 else { continue }
            result[snapshot.sessionID] = snapshot
        }
        return result
    }
}

@MainActor
final class WorkBuddyStatusStore {
    private let collection: TaskCollectionStore
    private let reader = WorkBuddyReader()
    private var pollTask: Task<Void, Never>?
    private(set) var lastError: String?

    init(collection: TaskCollectionStore) {
        self.collection = collection
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                let hasActive = self.collection.tasks.contains {
                    $0.source == .workBuddy && ($0.state == .working || $0.state == .waiting)
                }
                try? await Task.sleep(nanoseconds: (hasActive ? 2 : 12) * 1_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        do {
            let sessions = try await reader.readSessions(limit: TaskCollectionStore.recentTaskLimit)
            let hooks = await reader.readHookSnapshots()
            let isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.workbuddy.mac").isEmpty
            var tasks = sessions.map { session in
                let state: MonitoredTaskState
                let updatedAt: Date
                var timingHook: WorkBuddyHookSnapshot?
                if let hook = hooks[session.id],
                   hook.recordedAt >= session.updatedAt.addingTimeInterval(-10) {
                    state = trustworthy(hook.state, at: hook.recordedAt, appRunning: isRunning)
                    updatedAt = max(session.updatedAt, hook.recordedAt)
                    timingHook = hook
                } else {
                    state = trustworthy(mappedDatabaseState(session.status), at: session.updatedAt, appRunning: isRunning)
                    updatedAt = session.updatedAt
                }
                return MonitoredTask(
                    source: .workBuddy,
                    sourceTaskID: session.id,
                    title: session.title,
                    state: state,
                    updatedAt: updatedAt,
                    startedAt: timingHook?.startedAt,
                    endedAt: timingHook?.endedAt ?? (
                        state == .completed || state == .interrupted || state == .failed
                            ? session.updatedAt : nil
                    ),
                    openURL: sessionURL(id: session.id),
                    openScope: .exactTask
                )
            }
            let knownIDs = Set(sessions.map(\.id))
            for hook in hooks.values where !knownIDs.contains(hook.sessionID)
                && Date().timeIntervalSince(hook.recordedAt) < 24 * 60 * 60 {
                tasks.append(MonitoredTask(
                    source: .workBuddy,
                    sourceTaskID: hook.sessionID,
                    title: "WorkBuddy 任务",
                    state: trustworthy(hook.state, at: hook.recordedAt, appRunning: isRunning),
                    updatedAt: hook.recordedAt,
                    startedAt: hook.startedAt,
                    endedAt: hook.endedAt,
                    openURL: sessionURL(id: hook.sessionID),
                    openScope: .exactTask
                ))
            }
            collection.replaceTasks(from: .workBuddy, with: tasks)
            let hookInstalled = FileManager.default.fileExists(atPath:
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".workbuddy/hooks/yayastatus-workbuddy.py").path
            )
            let hasRecentHook = hooks.values.contains { Date().timeIntervalSince($0.recordedAt) < 24 * 60 * 60 }
            collection.setConnection(SourceConnection(
                source: .workBuddy,
                state: hasRecentHook ? .connected : .partial,
                detail: hasRecentHook ? "会话库与 Hook 均有数据" :
                    (hookInstalled ? "会话可读；Hook 等待下一次真实事件" : "会话可读；缺少实时 Hook 事件"),
                observedAt: .now
            ))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            let missingSource = (error as NSError).domain == "WorkBuddyReader" && (error as NSError).code == 0
            collection.setConnection(SourceConnection(
                source: .workBuddy,
                state: missingSource ? .setupRequired : .unavailable,
                detail: error.localizedDescription,
                observedAt: collection.connections[.workBuddy]?.observedAt
            ))
        }
    }

    private func mappedDatabaseState(_ raw: String) -> MonitoredTaskState {
        switch raw.lowercased() {
        case "running", "in_progress", "inprogress", "active", "working": .working
        case "waiting", "waiting_input", "pending_approval": .waiting
        case "completed", "done", "success": .completed
        case "failed", "error": .failed
        case "interrupted", "cancelled", "canceled", "aborted": .interrupted
        default: .unknown
        }
    }

    private func trustworthy(_ state: MonitoredTaskState, at date: Date, appRunning: Bool) -> MonitoredTaskState {
        guard state == .working || state == .waiting else { return state }
        guard appRunning, Date().timeIntervalSince(date) < 15 * 60 else { return .unknown }
        return state
    }

    private func sessionURL(id: String) -> URL? {
        var components = URLComponents()
        components.scheme = "workbuddy"
        components.host = "chat"
        components.path = "/\(id)"
        return components.url
    }
}
