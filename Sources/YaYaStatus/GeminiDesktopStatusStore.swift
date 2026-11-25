import AppKit
import Foundation
import SQLite3

private struct GeminiDesktopTask: Sendable {
    let id: String
    let title: String
    let status: String
    let notFullyIdle: Bool
    let killed: Bool
    let updatedAt: Date
    let startedAt: Date?
}

private actor GeminiDesktopReader {
    private let database: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        database = home.appendingPathComponent(".gemini/antigravity/conversation_summaries.db")
    }

    func readRecent(limit: Int) throws -> [GeminiDesktopTask] {
        guard FileManager.default.fileExists(atPath: database.path) else {
            throw NSError(domain: "GeminiDesktopReader", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "未找到 Gemini 桌面任务摘要库"])
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            throw NSError(domain: "GeminiDesktopReader", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取 Gemini 桌面任务库"])
        }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT conversation_id, COALESCE(NULLIF(title, ''), 'Gemini 任务'),
                   COALESCE(status, ''), COALESCE(not_fully_idle, 0), COALESCE(killed, 0),
                   last_modified_time, last_user_input_time
            FROM conversation_summaries
            WHERE app_data_dir = 'antigravity' AND conversation_id IS NOT NULL
            ORDER BY last_modified_time DESC LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "GeminiDesktopReader", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Gemini 任务摘要格式不兼容"])
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(min(100, max(1, limit))))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var tasks: [GeminiDesktopTask] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw NSError(domain: "GeminiDesktopReader", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Gemini 任务摘要读取失败"])
            }
            guard let idText = sqlite3_column_text(statement, 0),
                  let updatedText = sqlite3_column_text(statement, 5) else { continue }
            let id = String(cString: idText)
            guard UUID(uuidString: id) != nil,
                  let updatedAt = formatter.date(from: String(cString: updatedText).replacingOccurrences(of: " ", with: "T")) else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "Gemini 任务"
            let status = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            let startedAt = sqlite3_column_text(statement, 6)
                .flatMap { formatter.date(from: String(cString: $0).replacingOccurrences(of: " ", with: "T")) }
            tasks.append(GeminiDesktopTask(
                id: id, title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)),
                status: status, notFullyIdle: sqlite3_column_int(statement, 3) != 0,
                killed: sqlite3_column_int(statement, 4) != 0,
                updatedAt: updatedAt, startedAt: startedAt
            ))
        }
        return tasks
    }
}

@MainActor
final class GeminiDesktopStatusStore {
    private let collection: TaskCollectionStore
    private let reader = GeminiDesktopReader()
    private var pollTask: Task<Void, Never>?

    init(collection: TaskCollectionStore) { self.collection = collection }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                let active = self.collection.tasks(from: .geminiDesktop).contains {
                    $0.state == .working || $0.state == .waiting
                }
                try? await Task.sleep(for: .seconds(active ? 2 : 12))
            }
        }
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

    func refresh() async {
        let manager = FileManager.default
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.GeminiMacOS")
            ?? URL(fileURLWithPath: "/Applications/Gemini.app", isDirectory: true)
        let hasApp = manager.fileExists(atPath: appURL.path)
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.GeminiMacOS").isEmpty
        do {
            let summaries = try await reader.readRecent(limit: TaskCollectionStore.recentTaskLimit)
            let tasks = summaries.map { summary in
                let state = Self.mapState(summary, appRunning: running)
                return MonitoredTask(
                    source: .geminiDesktop, sourceTaskID: summary.id,
                    title: summary.title.isEmpty ? "Gemini 任务" : summary.title,
                    state: state, updatedAt: summary.updatedAt,
                    startedAt: summary.startedAt,
                    endedAt: state == .completed || state == .interrupted || state == .failed
                        ? summary.updatedAt : nil,
                    openURL: hasApp ? appURL : nil,
                    openScope: hasApp ? .application : .unavailable
                )
            }
            collection.replaceTasks(from: .geminiDesktop, with: tasks)
            collection.setConnection(SourceConnection(
                source: .geminiDesktop,
                state: hasApp ? .partial : .setupRequired,
                detail: !hasApp ? "未找到 Gemini 桌面版"
                    : summaries.isEmpty ? "已找到任务库；等待本机任务摘要"
                    : "本机任务摘要可读；普通聊天和未同步的云端任务暂不可监控",
                observedAt: summaries.first?.updatedAt
            ))
        } catch {
            collection.setConnection(SourceConnection(
                source: .geminiDesktop,
                state: (error as NSError).domain == "GeminiDesktopReader"
                    && (error as NSError).code == 0 ? .setupRequired : .unavailable,
                detail: error.localizedDescription,
                observedAt: collection.connections[.geminiDesktop]?.observedAt
            ))
        }
    }

    private static func mapState(_ task: GeminiDesktopTask, appRunning: Bool) -> MonitoredTaskState {
        if task.killed { return .interrupted }
        let status = task.status.uppercased()
        if status.contains("FAIL") || status.contains("ERROR") { return .failed }
        if status.contains("IDLE") && task.notFullyIdle { return .unknown }
        if status.contains("IDLE") || status.contains("COMPLETE") || status.contains("FINISH") {
            return .completed
        }
        let active = task.notFullyIdle || status.contains("RUNNING") || status.contains("EXECUTING")
            || status.contains("WAITING") || status.contains("PAUSED")
        if active {
            guard appRunning, Date().timeIntervalSince(task.updatedAt) < 300 else { return .unknown }
            return status.contains("WAITING") || status.contains("PAUSED") ? .waiting : .working
        }
        return .unknown
    }
}
