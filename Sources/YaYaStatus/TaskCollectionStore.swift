import Foundation

enum TaskSource: String, Codable, CaseIterable, Sendable {
    case codex
    case workBuddy
    case doubaoWork
    case kimiWork
    case grokBot
    case piAgent
    case deepSeekWeb

    var label: String {
        switch self {
        case .codex: "Codex"
        case .workBuddy: "WorkBuddy"
        case .doubaoWork: "豆包工作"
        case .kimiWork: "Kimi Work"
        case .grokBot: "Grok Bot"
        case .piAgent: "Pi Agent"
        case .deepSeekWeb: "DeepSeek 网页"
        }
    }
}

enum MonitoredTaskState: String, Codable, Sendable {
    case checking
    case working
    case waiting
    case completed
    case ended
    case interrupted
    case failed
    case unknown
    case sessionOnly

    var label: String {
        switch self {
        case .checking: "核对中"
        case .working: "工作中"
        case .waiting: "等待操作"
        case .completed: "已完成"
        case .ended: "已结束"
        case .interrupted: "已中断"
        case .failed: "报错"
        case .unknown: "状态未知"
        case .sessionOnly: "仅会话"
        }
    }
}

enum TaskOpenScope: String, Sendable {
    case exactTask
    case application
    case unavailable
}

struct MonitoredTask: Identifiable, Equatable, Sendable {
    let source: TaskSource
    let sourceTaskID: String
    let title: String
    let state: MonitoredTaskState
    let updatedAt: Date
    let openURL: URL?
    let openScope: TaskOpenScope

    var id: String { "\(source.rawValue):\(sourceTaskID)" }
    var displayID: String { "\(id):\(state.rawValue)" }
}

enum SourceConnectionState: String, Sendable {
    case checking
    case connected
    case partial
    case setupRequired
    case unavailable
}

struct SourceConnection: Equatable, Sendable {
    let source: TaskSource
    let state: SourceConnectionState
    let detail: String
    let observedAt: Date?

    init(source: TaskSource, state: SourceConnectionState, detail: String, observedAt: Date? = nil) {
        self.source = source
        self.state = state
        self.detail = detail
        self.observedAt = observedAt
    }
}

@MainActor
final class TaskCollectionStore: ObservableObject {
    static let recentTaskLimit = 100

    @Published private(set) var tasks: [MonitoredTask] = []
    @Published private(set) var connections: [TaskSource: SourceConnection] = [:]
    private var tasksBySource: [TaskSource: [MonitoredTask]] = [:]

    func setConnection(_ connection: SourceConnection) {
        connections[connection.source] = connection
        if connection.state == .unavailable || connection.state == .setupRequired,
           connection.observedAt.map({ Date().timeIntervalSince($0) > 30 }) ?? true {
            demoteActiveTasks(from: connection.source)
        }
    }

    func demoteActiveTasks(from source: TaskSource) {
        let current = tasksBySource[source] ?? []
        let replacement = current.map { task in
            guard task.state == .working || task.state == .waiting else { return task }
            return MonitoredTask(
                source: task.source, sourceTaskID: task.sourceTaskID, title: task.title,
                state: .unknown, updatedAt: task.updatedAt,
                openURL: task.openURL, openScope: task.openScope
            )
        }
        if replacement != current { replaceTasks(from: source, with: replacement) }
    }

    func replaceTasks(from source: TaskSource, with replacement: [MonitoredTask]) {
        tasksBySource[source] = replacement
        tasks = Array(tasksBySource.values.flatMap { $0 }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
            .prefix(Self.recentTaskLimit))
    }

    func tasks(from source: TaskSource) -> [MonitoredTask] {
        tasksBySource[source] ?? []
    }
}
