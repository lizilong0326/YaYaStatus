import AppKit
import SwiftUI

private enum Palette {
    static let background = Color(red: 0.075, green: 0.09, blue: 0.11)
    static let surface = Color(red: 0.12, green: 0.14, blue: 0.17)
    static let border = Color.white.opacity(0.11)
    static let primary = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.57)
    static let green = Color(red: 0.24, green: 0.87, blue: 0.55)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.33)
    static let red = Color(red: 1.0, green: 0.37, blue: 0.40)
    static let gray = Color.white.opacity(0.40)
}

struct StatusPanelView: View {
    @ObservedObject var store: CodexStatusStore
    @ObservedObject var collection: TaskCollectionStore
    let onRefresh: () -> Void
    @State private var selectedSource: TaskSource?

    private var visibleTasks: [MonitoredTask] {
        guard let selectedSource else { return collection.tasks }
        return collection.tasks.filter { $0.source == selectedSource }
    }

    private var activeTasks: [MonitoredTask] {
        visibleTasks.filter { $0.state == .working || $0.state == .waiting }
    }

    private var recentTasks: [MonitoredTask] {
        visibleTasks.filter { $0.state != .working && $0.state != .waiting }
    }

    private var emptyTitle: String {
        if store.isRefreshing && selectedSource == nil { return "正在读取任务…" }
        if let selectedSource, collection.connections[selectedSource]?.state != .connected {
            return "尚未读取到任务"
        }
        return "暂时没有任务"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            providerCard
                .padding(.top, 19)
            taskContent
                .padding(.top, 18)
            footer
        }
        .padding(20)
        .frame(width: 390, height: 570)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Palette.background)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Palette.border, lineWidth: 1)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Palette.green.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.green)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("丫丫状态")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                Text("所有 AI 任务，一个地方看")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
            }
            Spacer()
            Button {
                onRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 29, height: 29)
                    .background(Circle().fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("刷新全部工作台")
        }
    }

    private var providerCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 9) {
                Text("工作台")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                Spacer()
                Button {
                    selectedSource = nil
                } label: {
                    Text(selectedSource == nil ? "全部来源" : "查看全部")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selectedSource == nil ? Palette.green : Palette.secondary)
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    providerBadge(.codex)
                    providerBadge(.workBuddy)
                    providerBadge(.kimiWork)
                }
                HStack(spacing: 5) {
                    providerBadge(.doubaoWork)
                    providerBadge(.grokBot)
                }
            }
            if let selectedSource, let connection = collection.connections[selectedSource],
               connection.state != .connected {
                Text(connection.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text("\(activeTasks.count) 个进行中")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(activeTasks.isEmpty ? Palette.secondary : Palette.green)
                Text("·")
                    .foregroundStyle(Palette.secondary)
                Text("\(visibleTasks.count) 条任务/会话")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                Spacer()
            }
            if !store.displayQuotaWindows.isEmpty {
                HStack(spacing: 7) {
                    ForEach(store.displayQuotaWindows) { window in
                        Text("\(window.shortName)剩余 \(Int(window.remainingPercent.rounded()))%")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Palette.border, lineWidth: 1))
    }

    private func providerBadge(_ source: TaskSource) -> some View {
        let connection = collection.connections[source]
        let state: SourceConnectionState
        if source == .codex {
            state = store.taskError != nil ? .unavailable : (store.lastTaskSync == nil ? .limited : .connected)
        } else {
            state = connection?.state ?? .limited
        }
        return Button {
            selectedSource = selectedSource == source ? nil : source
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(state == .connected ? Palette.green : (state == .limited ? Palette.orange : Palette.red))
                    .frame(width: 5, height: 5)
                Text(source.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Capsule().fill(selectedSource == source ? Palette.green.opacity(0.18) : Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help("筛选 \(source.label)；\(connection?.detail ?? (source == .codex ? "Codex 任务与额度" : "正在读取"))")
    }

    private var taskContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(selectedSource == .grokBot ? "Bot 会话" : (selectedSource == nil ? "任务与会话" : "任务"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                Spacer()
                if let sync = store.lastTaskSync {
                    Text(sync, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.secondary)
                }
            }
            if let error = store.taskError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.orange)
                    .lineLimit(2)
                    .padding(.bottom, 2)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if !activeTasks.isEmpty {
                        sectionTitle("进行中")
                        ForEach(activeTasks) { task in taskRow(task) }
                    }
                    if !recentTasks.isEmpty {
                        sectionTitle(selectedSource == .grokBot ? "最近会话" : (selectedSource == nil ? "最近任务/会话" : "最近任务"))
                            .padding(.top, activeTasks.isEmpty ? 0 : 9)
                        ForEach(recentTasks) { task in taskRow(task) }
                    }
                    if visibleTasks.isEmpty {
                        emptyState
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sectionTitle(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Palette.secondary)
            .padding(.leading, 2)
            .padding(.bottom, 2)
    }

    private func taskRow(_ task: MonitoredTask) -> some View {
        Button {
            if let link = task.openURL { NSWorkspace.shared.open(link) }
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(color(for: task.state))
                    .frame(width: 7, height: 7)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.primary)
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        Text("\(task.source.label) · \(task.state.label)")
                            .foregroundStyle(color(for: task.state))
                        Text("·")
                            .foregroundStyle(Palette.secondary)
                        Text(task.updatedAt, style: .relative)
                            .foregroundStyle(Palette.secondary)
                    }
                    .font(.system(size: 10))
                }
                Spacer(minLength: 0)
                if task.openScope == .application {
                    Text("打开应用")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.secondary)
                } else if task.openScope == .exactTask {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.surface))
        }
        .buttonStyle(.plain)
        .disabled(task.openURL == nil)
        .help(task.openScope == .exactTask
              ? "在 \(task.source.label) 中打开：\(task.title)"
              : "打开 \(task.source.label) 应用；暂不能定位到此任务")
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "tray")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Palette.secondary)
            Text(emptyTitle)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
    }

    private func color(for state: MonitoredTaskState) -> Color {
        switch state {
        case .working: Palette.orange
        case .waiting: Palette.orange
        case .completed: Palette.green
        case .interrupted: Palette.orange
        case .failed: Palette.red
        case .unknown: Palette.gray
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "hand.draw")
                .font(.system(size: 10))
            Text("拖动空白处移动悬浮框")
            Spacer()
            Text("Codex · WorkBuddy · Kimi · 豆包 · Grok")
        }
        .font(.system(size: 10))
        .foregroundStyle(Palette.secondary)
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.border).frame(height: 1)
        }
    }
}
