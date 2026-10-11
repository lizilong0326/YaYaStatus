import AppKit
import Foundation

private struct CursorHookSnapshot: Decodable, Sendable {
    let conversationID: String
    let generationID: String
    let title: String
    let workspace: String
    let state: MonitoredTaskState
    let recordedAt: Date
    let startedAt: Date?
    let endedAt: Date?

    enum CodingKeys: String, CodingKey {
        case conversationID, generationID, title, workspace, state, recordedAt, startedAt, endedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try values.decode(String.self, forKey: .conversationID)
        generationID = try values.decode(String.self, forKey: .generationID)
        title = try values.decode(String.self, forKey: .title)
        workspace = try values.decode(String.self, forKey: .workspace)
        state = try values.decode(MonitoredTaskState.self, forKey: .state)
        recordedAt = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .recordedAt))
        startedAt = try values.decodeIfPresent(Double.self, forKey: .startedAt)
            .map(Date.init(timeIntervalSince1970:))
        endedAt = try values.decodeIfPresent(Double.self, forKey: .endedAt)
            .map(Date.init(timeIntervalSince1970:))
    }
}

private actor CursorHookReader {
    private let directory: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        directory = home.appendingPathComponent(
            "Library/Application Support/YaYaStatus/cursor/sessions", isDirectory: true
        )
    }

    func readRecent(limit: Int) throws -> [CursorHookSnapshot] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }
        let files = try manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
        let sorted = files.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhs > rhs
        }
        return sorted.prefix(limit).compactMap { file in
            guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  size > 0, size < 4_096,
                  let data = try? Data(contentsOf: file),
                  let snapshot = try? JSONDecoder().decode(CursorHookSnapshot.self, from: data),
                  !snapshot.conversationID.isEmpty, snapshot.conversationID.count <= 128,
                  !snapshot.generationID.isEmpty, snapshot.generationID.count <= 128,
                  snapshot.title.count <= 160, snapshot.workspace.count <= 160,
                  snapshot.recordedAt.timeIntervalSince1970 > 0,
                  snapshot.recordedAt.timeIntervalSinceNow < 300 else { return nil }
            return snapshot
        }
    }
}

@MainActor
final class CursorStatusStore {
    private let collection: TaskCollectionStore
    private let reader = CursorHookReader()
    private var pollTask: Task<Void, Never>?

    init(collection: TaskCollectionStore) { self.collection = collection }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                let active = self.collection.tasks(from: .cursor).contains {
                    $0.state == .working || $0.state == .waiting
                }
                try? await Task.sleep(for: .seconds(active ? 2 : 8))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        let manager = FileManager.default
        let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.todesktop.230313mzl4w4u92"
        ) ?? URL(fileURLWithPath: "/Applications/Cursor.app", isDirectory: true)
        let hasApp = manager.fileExists(atPath: appURL.path)
        let bundleID = Bundle(url: appURL)?.bundleIdentifier
        let appRunning = bundleID.map {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        } ?? false
        let home = manager.homeDirectoryForCurrentUser
        let hookURL = home.appendingPathComponent(".cursor/hooks/yayastatus-cursor.py")
        let configURL = home.appendingPathComponent(".cursor/hooks.json")
        let installed = manager.fileExists(atPath: hookURL.path) && hasHook(in: configURL)

        do {
            let snapshots = try await reader.readRecent(limit: TaskCollectionStore.recentTaskLimit)
            let now = Date()
            let newestByConversation = Dictionary(grouping: snapshots, by: \.conversationID)
                .mapValues { group in group.map(\.recordedAt).max() ?? .distantPast }
            let tasks = snapshots.map { snapshot in
                let fresh = now.timeIntervalSince(snapshot.recordedAt) < 120
                let superseded = snapshot.recordedAt < (newestByConversation[snapshot.conversationID] ?? .distantPast)
                let state: MonitoredTaskState =
                    (snapshot.state == .working && (!fresh || !appRunning || superseded))
                    ? .unknown : snapshot.state
                let title = snapshot.workspace.isEmpty
                    ? snapshot.title : "\(snapshot.workspace) · \(snapshot.title)"
                return MonitoredTask(
                    source: .cursor,
                    sourceTaskID: "\(snapshot.conversationID):\(snapshot.generationID)",
                    title: title, state: state, updatedAt: snapshot.recordedAt,
                    startedAt: snapshot.startedAt, endedAt: snapshot.endedAt,
                    openURL: hasApp ? appURL : nil,
                    openScope: hasApp ? .application : .unavailable
                )
            }
            collection.replaceTasks(from: .cursor, with: tasks)
            let recentEvent = snapshots.contains { now.timeIntervalSince($0.recordedAt) < 86_400 }
            let state: SourceConnectionState = !hasApp || !installed ? .setupRequired
                : (appRunning && recentEvent ? .connected : .partial)
            let detail: String
            if !hasApp {
                detail = "未找到 Cursor 桌面版"
            } else if !installed {
                detail = "安装 Cursor Hook 后可监控新任务；已有会话不会补读"
            } else if !appRunning {
                detail = "Hook 已安装；Cursor 当前未运行"
            } else if recentEvent {
                detail = "Agent 事件可读；点击任务打开 Cursor 应用"
            } else {
                detail = "Hook 已安装；等待下一次 Cursor Agent 任务"
            }
            collection.setConnection(SourceConnection(
                source: .cursor, state: state, detail: detail,
                observedAt: recentEvent ? snapshots.first?.recordedAt : nil
            ))
        } catch {
            collection.setConnection(SourceConnection(
                source: .cursor, state: .unavailable,
                detail: "Cursor 事件读取失败：\(error.localizedDescription)",
                observedAt: collection.connections[.cursor]?.observedAt
            ))
        }
    }

    private func hasHook(in url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let entries = hooks["beforeSubmitPrompt"] as? [[String: Any]] else { return false }
        return entries.contains {
            ($0["command"] as? String)?.contains("yayastatus-cursor.py") == true
        }
    }
}
