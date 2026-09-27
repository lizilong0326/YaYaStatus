import Foundation

enum TaskSource: String, Codable, CaseIterable, Sendable {
    case codex
    case workBuddy
    case doubaoWork
    case kimiWork
    case grokBot

    var label: String {
        switch self {
        case .codex: "Codex"
        case .workBuddy: "WorkBuddy"
        case .doubaoWork: "豆包工作"
        case .kimiWork: "Kimi Work"
        case .grokBot: "Grok Bot"
        }
    }
}

enum MonitoredTaskState: String, Codable, Sendable {
    case working
    case waiting
    case completed
    case interrupted
    case failed
    case unknown

    var label: String {
        switch self {
        case .working: "工作中"
        case .waiting: "等待操作"
        case .completed: "已完成"
        case .interrupted: "已中断"
        case .failed: "报错"
        case .unknown: "状态未知"
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
}

enum SourceConnectionState: String, Sendable {
    case connected
    case limited
    case unavailable
}

struct SourceConnection: Equatable, Sendable {
    let source: TaskSource
    let state: SourceConnectionState
    let detail: String
}

@MainActor
final class TaskCollectionStore: ObservableObject {
    @Published private(set) var tasks: [MonitoredTask] = []
    @Published private(set) var connections: [TaskSource: SourceConnection] = [:]

    func setConnection(_ connection: SourceConnection) {
        connections[connection.source] = connection
    }

    func replaceTasks(from source: TaskSource, with replacement: [MonitoredTask]) {
        tasks = (tasks.filter { $0.source != source } + replacement)
            .sorted { lhs, rhs in
                let lhsActive = lhs.state == .working || lhs.state == .waiting
                let rhsActive = rhs.state == .working || rhs.state == .waiting
                if lhsActive != rhsActive { return lhsActive }
                return lhs.updatedAt > rhs.updatedAt
            }
    }
}
