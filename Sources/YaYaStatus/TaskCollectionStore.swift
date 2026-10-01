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
    let startedAt: Date?
    let endedAt: Date?
    let openURL: URL?
    let openScope: TaskOpenScope

    init(source: TaskSource, sourceTaskID: String, title: String, state: MonitoredTaskState,
         updatedAt: Date, startedAt: Date? = nil, endedAt: Date? = nil,
         openURL: URL?, openScope: TaskOpenScope) {
        self.source = source
        self.sourceTaskID = sourceTaskID
        self.title = title
        self.state = state
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.openURL = openURL
        self.openScope = openScope
    }

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
    private static let feishuEnabledKey = "yayastatus-feishu-notifications-enabled"

    var onTaskCompleted: (@MainActor (MonitoredTask) -> Void)?
    @Published private(set) var tasks: [MonitoredTask] = []
    @Published private(set) var activeTasks: [MonitoredTask] = []
    @Published private(set) var connections: [TaskSource: SourceConnection] = [:]
    @Published private(set) var feishuNotificationsEnabled = UserDefaults.standard.bool(forKey: feishuEnabledKey)
    @Published private(set) var feishuSelectedTaskIDs: Set<String> = []
    private var tasksBySource: [TaskSource: [MonitoredTask]] = [:]

    func setFeishuNotificationsEnabled(_ enabled: Bool) {
        feishuNotificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.feishuEnabledKey)
        if !enabled { feishuSelectedTaskIDs.removeAll() }
    }

    func hasFeishuNotification(for task: MonitoredTask) -> Bool {
        feishuNotificationsEnabled && feishuSelectedTaskIDs.contains(task.id)
    }

    func toggleFeishuNotification(for task: MonitoredTask) {
        guard feishuNotificationsEnabled, isActive(task.state),
              activeTasks.contains(where: { $0.id == task.id && isActive($0.state) }) else { return }
        if feishuSelectedTaskIDs.contains(task.id) {
            feishuSelectedTaskIDs.remove(task.id)
        } else {
            feishuSelectedTaskIDs.insert(task.id)
        }
    }

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
                startedAt: task.startedAt, endedAt: task.endedAt,
                openURL: task.openURL, openScope: task.openScope
            )
        }
        if replacement != current { replaceTasks(from: source, with: replacement) }
    }

    func replaceTasks(from source: TaskSource, with replacement: [MonitoredTask]) {
        let oldTasks = tasksBySource[source] ?? []
        let previous = Dictionary(oldTasks.map { ($0.id, $0.state) },
                                  uniquingKeysWith: { _, latest in latest })
        let selectedCompletions = replacement.filter { task in
            feishuNotificationsEnabled && task.state == .completed
                && feishuSelectedTaskIDs.contains(task.id)
                && previous[task.id].map(isActive) == true
        }
        let activeIDs = Set(replacement.filter { isActive($0.state) }.map(\.id))
        let finishedOrMissing = Set(oldTasks.map(\.id)).subtracting(activeIDs)
            .intersection(feishuSelectedTaskIDs)
        if !finishedOrMissing.isEmpty {
            feishuSelectedTaskIDs.subtract(finishedOrMissing)
        }
        tasksBySource[source] = replacement
        let sorted = tasksBySource.values.flatMap { $0 }.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
        tasks = Array(sorted.prefix(Self.recentTaskLimit))
        activeTasks = sorted.filter { $0.state == .working || $0.state == .waiting }
        for task in selectedCompletions {
            onTaskCompleted?(task)
        }
    }

    func tasks(from source: TaskSource) -> [MonitoredTask] {
        tasksBySource[source] ?? []
    }

    private func isActive(_ state: MonitoredTaskState) -> Bool {
        state == .working || state == .waiting
    }
}
