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

struct MonitoredTask: Identifiable, Equatable, Sendable {
    let source: TaskSource
    let sourceTaskID: String
    let title: String
    let state: MonitoredTaskState
    let updatedAt: Date
    let openURL: URL?

    var id: String { "\(source.rawValue):\(sourceTaskID)" }
}

@MainActor
final class TaskCollectionStore: ObservableObject {
    @Published private(set) var tasks: [MonitoredTask] = []

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
