import Foundation

private actor DoubaoWorkReader {
    private let scriptURL: URL?
    private let nodeURL: URL?

    init() {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("doubao-cli/bin/doubao.mjs")
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/doubao-cli/bin/doubao.mjs")
        scriptURL = [bundled, source].compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
        nodeURL = Self.findNode()
    }

    func readiness() throws -> Bool {
        let object = try dictionary(from: runCLI(["cdp", "status"], allowNonZero: true))
        return object["available"] as? Bool == true
    }

    func sessions(limit: Int) throws -> [(id: String, title: String)] {
        let data = try runCLI(["sessions", "list"])
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw error("豆包会话列表格式不兼容")
        }
        return array.prefix(limit).compactMap { row in
            guard let id = row["id"] as? String, id.count >= 12, id.count <= 24,
                  id.allSatisfy(\.isNumber) else { return nil }
            let title = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (id, title?.isEmpty == false ? title! : "豆包任务")
        }
    }

    func state(for id: String) -> MonitoredTaskState {
        guard let data = try? runCLI(["sessions", "status", id]),
              let object = try? dictionary(from: data) else { return .unknown }
        switch object["status"] as? String {
        case "running": return .working
        case "waiting_input": return .waiting
        case "completed": return .completed
        case "failed": return .failed
        case "cancelled": return .interrupted
        default: return .unknown
        }
    }

    private func runCLI(_ arguments: [String], allowNonZero: Bool = false) throws -> Data {
        guard let scriptURL, let nodeURL else { throw error("缺少 Node.js 22+ 或内置豆包连接器") }
        let process = Process()
        process.executableURL = nodeURL
        process.arguments = [scriptURL.path, "--app", "work"] + arguments + ["--json"]
        let configuration = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/YaYaStatus/doubao-cli", isDirectory: true)
        process.environment = ProcessInfo.processInfo.environment.merging([
            "DOUBAO_CLI_DISABLE_AUTO_UPDATE": "1",
            "DOUBAO_CLI_CONFIG_DIR": configuration.path
        ]) { _, new in new }
        let output = Pipe()
        let diagnostics = Pipe()
        process.standardOutput = output
        process.standardError = diagnostics
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let diagnosticData = diagnostics.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || (allowNonZero && !data.isEmpty) else {
            let detail = String(data: diagnosticData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw error(detail?.isEmpty == false ? detail! : "豆包连接器执行失败")
        }
        guard data.count < 2_000_000 else { throw error("豆包状态响应过大") }
        return data
    }

    private func dictionary(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw error("豆包状态格式不兼容")
        }
        return object
    }

    private func error(_ message: String) -> NSError {
        NSError(domain: "DoubaoWorkReader", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func findNode() -> URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let fixed = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let nvm = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? []
        let candidates = (paths + fixed + versions.sorted().reversed().map { nvm.appendingPathComponent($0).appendingPathComponent("bin").path })
            .map { URL(fileURLWithPath: $0).appendingPathComponent("node") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

@MainActor
final class DoubaoWorkStatusStore {
    private let collection: TaskCollectionStore
    private let reader = DoubaoWorkReader()
    private var pollTask: Task<Void, Never>?
    private var lastStatusCheck: [String: Date] = [:]

    init(collection: TaskCollectionStore) { self.collection = collection }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        do {
            guard try await reader.readiness() else {
                demoteActiveTasks()
                collection.setConnection(SourceConnection(
                    source: .doubaoWork,
                    state: .limited,
                    detail: "当前客户端未开启 CDP；保留正在运行的豆包任务后再重启启用"
                ))
                return
            }
            let sessions = try await reader.sessions(limit: 10)
            let previous = Dictionary(uniqueKeysWithValues: collection.tasks
                .filter { $0.source == .doubaoWork }.map { ($0.sourceTaskID, $0) })
            var tasks: [MonitoredTask] = []
            for (index, session) in sessions.enumerated() {
                let old = previous[session.id]
                let wasActive = old?.state == .working || old?.state == .waiting || old?.state == .unknown
                let lastCheck = lastStatusCheck[session.id] ?? .distantPast
                let shouldCheck = index < 3 || wasActive || Date().timeIntervalSince(lastCheck) > 5 * 60
                let state: MonitoredTaskState
                if shouldCheck {
                    state = await reader.state(for: session.id)
                    lastStatusCheck[session.id] = .now
                } else {
                    state = old?.state ?? .unknown
                }
                let date = old?.state == state && old?.title == session.title
                    ? old!.updatedAt : Date().addingTimeInterval(Double(-index))
                var link = URLComponents()
                link.scheme = "doubaowork"
                link.host = "doubaoworkapp"
                link.path = "/open-url"
                link.queryItems = [URLQueryItem(name: "url", value: "https://www.doubao.com/chat/\(session.id)")]
                tasks.append(MonitoredTask(
                    source: .doubaoWork,
                    sourceTaskID: session.id,
                    title: session.title,
                    state: state,
                    updatedAt: date,
                    openURL: link.url,
                    openScope: link.url == nil ? .unavailable : .exactTask
                ))
            }
            collection.replaceTasks(from: .doubaoWork, with: tasks)
            collection.setConnection(SourceConnection(
                source: .doubaoWork,
                state: sessions.isEmpty ? .limited : .connected,
                detail: sessions.isEmpty ? "CDP 已连接，但暂未读到会话" : "CDP 已连接；读取逐轮任务状态"
            ))
        } catch {
            demoteActiveTasks()
            collection.setConnection(SourceConnection(source: .doubaoWork, state: .unavailable, detail: error.localizedDescription))
        }
    }

    private func demoteActiveTasks() {
        let current = collection.tasks.filter { $0.source == .doubaoWork }
        collection.replaceTasks(from: .doubaoWork, with: current.map { task in
            MonitoredTask(
                source: task.source,
                sourceTaskID: task.sourceTaskID,
                title: task.title,
                state: task.state == .working || task.state == .waiting ? .unknown : task.state,
                updatedAt: task.updatedAt,
                openURL: task.openURL,
                openScope: task.openScope
            )
        })
    }
}
