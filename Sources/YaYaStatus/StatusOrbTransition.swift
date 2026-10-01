import Foundation

enum OrbTaskOutcome: Equatable {
    case completed
    case ended
    case interrupted
    case failed

    init?(state: MonitoredTaskState) {
        switch state {
        case .completed: self = .completed
        case .ended: self = .ended
        case .interrupted: self = .interrupted
        case .failed: self = .failed
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .completed: "已完成"
        case .ended: "已结束"
        case .interrupted: "已中断"
        case .failed: "报错"
        }
    }
}

struct OrbTaskFinishCue: Identifiable, Equatable {
    let id = UUID()
    let outcome: OrbTaskOutcome
    let taskTitle: String
}

enum StatusOrbTransition {
    static func states(for tasks: [MonitoredTask]) -> [String: MonitoredTaskState] {
        Dictionary(tasks.map { ($0.id, $0.state) }, uniquingKeysWith: { _, latest in latest })
    }

    static func newFinish(previous: [String: MonitoredTaskState],
                          current: [MonitoredTask]) -> OrbTaskFinishCue? {
        let newlyFinished = current.filter { task in
            guard let previousState = previous[task.id],
                  previousState == .working || previousState == .waiting else { return false }
            return OrbTaskOutcome(state: task.state) != nil
        }
        guard let task = newlyFinished.max(by: {
            ($0.endedAt ?? $0.updatedAt) < ($1.endedAt ?? $1.updatedAt)
        }), let outcome = OrbTaskOutcome(state: task.state) else { return nil }
        return OrbTaskFinishCue(outcome: outcome, taskTitle: task.title)
    }

    static func hasNewCompletion(previous: [String: MonitoredTaskState],
                                 current: [MonitoredTask]) -> Bool {
        current.contains { task in
            guard task.state == .completed, let oldState = previous[task.id] else { return false }
            return oldState == .working || oldState == .waiting
        }
    }
}
