import Foundation

private struct DeepSeekTabSnapshot: Decodable, Sendable {
    let tabID: Int
    let conversationID: String
    let title: String
    let state: MonitoredTaskState
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case tabID, conversationID, title, state, updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tabID = try values.decode(Int.self, forKey: .tabID)
        conversationID = try values.decode(String.self, forKey: .conversationID)
        title = try values.decode(String.self, forKey: .title)
        state = try values.decode(MonitoredTaskState.self, forKey: .state)
        updatedAt = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .updatedAt))
    }
}

private actor DeepSeekTabReader {
    private let snapshotDirectory: URL
    private let hostManifest: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        snapshotDirectory = home.appendingPathComponent(
            "Library/Application Support/YaYaStatus/deepseek/tabs", isDirectory: true
        )
        hostManifest = home.appendingPathComponent(
            "Library/Application Support/Google/Chrome/NativeMessagingHosts/com.local.yayastatus.deepseek.json"
        )
    }

    func read() -> (tasks: [MonitoredTask], hostInstalled: Bool) {
        let fileManager = FileManager.default
        let hostInstalled = fileManager.fileExists(atPath: hostManifest.path)
        let files = (try? fileManager.contentsOfDirectory(
            at: snapshotDirectory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        )) ?? []
        let tasks: [MonitoredTask] = files.compactMap { file in
            guard file.pathExtension == "json",
                  let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  size < 4_096, let data = try? Data(contentsOf: file),
                  let tab = try? JSONDecoder().decode(DeepSeekTabSnapshot.self, from: data),
                  tab.tabID > 0, UUID(uuidString: tab.conversationID) != nil,
                  Date().timeIntervalSince(tab.updatedAt) < 35 else { return nil }
            return MonitoredTask(
                source: .deepSeekWeb,
                sourceTaskID: "\(tab.tabID):\(tab.conversationID)",
                title: String(tab.title.prefix(100)),
                state: tab.state,
                updatedAt: tab.updatedAt,
                openURL: URL(string: "https://chat.deepseek.com/a/chat/s/\(tab.conversationID)"),
                openScope: .exactTask
            )
        }.sorted { $0.updatedAt > $1.updatedAt }
        return (Array(tasks.prefix(10)), hostInstalled)
    }
}

@MainActor
final class DeepSeekWebStatusStore {
    private let collection: TaskCollectionStore
    private let reader = DeepSeekTabReader()
    private var pollTask: Task<Void, Never>?

    init(collection: TaskCollectionStore) { self.collection = collection }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        let result = await reader.read()
        collection.replaceTasks(from: .deepSeekWeb, with: result.tasks)
        collection.setConnection(SourceConnection(
            source: .deepSeekWeb,
            state: result.tasks.isEmpty ? .limited : .connected,
            detail: result.tasks.isEmpty
                ? (result.hostInstalled ? "本机桥接已安装；等待 Chrome 扩展的页面事件" : "需要安装 Chrome 扩展与本机桥接")
                : "只观察已打开标签；未验证生成信号时显示状态未知",
            observedAt: result.tasks.isEmpty ? nil : .now
        ))
    }
}
