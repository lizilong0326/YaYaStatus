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

    private var activeTasks: [MonitoredTask] {
        collection.tasks.filter { $0.state == .working || $0.state == .waiting }
    }

    private var recentTasks: [MonitoredTask] {
        collection.tasks.filter { $0.state != .working && $0.state != .waiting }
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
        .frame(width: 390, height: 510)
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
                store.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 29, height: 29)
                    .background(Circle().fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("刷新 Codex 任务")
        }
    }

    private var providerCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 9) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.primary)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1)))
                Text("Codex")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                Spacer()
                Circle()
                    .fill(store.taskError == nil && store.lastTaskSync != nil ? Palette.green : Palette.orange)
                    .frame(width: 6, height: 6)
                Text(connectionLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            }
            HStack(spacing: 8) {
                Text("\(activeTasks.count) 个进行中")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(activeTasks.isEmpty ? Palette.secondary : Palette.green)
                Text("·")
                    .foregroundStyle(Palette.secondary)
                Text("\(collection.tasks.count) 个最近任务")
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

    private var connectionLabel: String {
        if store.taskError != nil { return "连接失败" }
        if store.lastTaskSync == nil { return "连接中" }
        return "已连接"
    }

    private var taskContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("任务")
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
                        sectionTitle("最近任务")
                            .padding(.top, activeTasks.isEmpty ? 0 : 9)
                        ForEach(recentTasks) { task in taskRow(task) }
                    }
                    if collection.tasks.isEmpty {
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
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.surface))
        }
        .buttonStyle(.plain)
        .help("在 \(task.source.label) 中打开：\(task.title)")
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "tray")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Palette.secondary)
            Text(store.isRefreshing ? "正在读取 Codex 任务…" : "暂时没有最近任务")
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
            Text("其他工作台陆续接入")
        }
        .font(.system(size: 10))
        .foregroundStyle(Palette.secondary)
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.border).frame(height: 1)
        }
    }
}
