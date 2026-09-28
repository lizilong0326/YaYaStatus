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
    static let blue = Color(red: 0.42, green: 0.72, blue: 1.0)
    static let red = Color(red: 1.0, green: 0.37, blue: 0.40)
    static let gray = Color.white.opacity(0.40)
}

struct StatusPanelView: View {
    @ObservedObject var store: CodexStatusStore
    @ObservedObject var collection: TaskCollectionStore
    let onRefresh: () -> Void
    @State private var showingSettings = false

    private var activeTaskCount: Int {
        collection.tasks.filter { $0.state == .working || $0.state == .waiting }.count
    }

    private var failedSourceCount: Int {
        collection.connections.values.filter { $0.state == .unavailable }.count
            + (connectionState(for: .codex) == .unavailable ? 1 : 0)
    }

    private var emptyTitle: String {
        store.isRefreshing ? "正在读取任务…" : "暂时没有任务与会话"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showingSettings {
                settingsHeader
                settingsContent
                    .padding(.top, 20)
            } else {
                header
                overviewCard
                    .padding(.top, 19)
                taskContent
                    .padding(.top, 18)
            }
            footer
        }
        .padding(20)
        .frame(width: 390, height: 605)
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
            Button {
                showingSettings = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                        .frame(width: 29, height: 29)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                    if failedSourceCount > 0 {
                        Circle().fill(Palette.red).frame(width: 7, height: 7)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("设置与工作台")
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(activeTaskCount) 个进行中")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(activeTaskCount == 0 ? Palette.secondary : Palette.green)
                Text("·")
                    .foregroundStyle(Palette.secondary)
                Text("显示最近 \(collection.tasks.count) / \(TaskCollectionStore.recentTaskLimit) 条")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                Spacer()
            }
            if failedSourceCount > 0 {
                Text("\(failedSourceCount) 个来源读取失败，请到设置查看")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.red)
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

    private var settingsHeader: some View {
        HStack(spacing: 11) {
            Button {
                showingSettings = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 11).fill(Palette.surface))
            }
            .buttonStyle(.plain)
            .help("返回任务列表")
            VStack(alignment: .leading, spacing: 2) {
                Text("设置")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                Text("工作台连接状态")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
            }
            Spacer()
            Button(action: onRefresh) {
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

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("工作台")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                Spacer()
                Text("\(TaskSource.allCases.count) 个来源")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(TaskSource.allCases, id: \.self) { source in
                        sourceRow(source)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func connectionState(for source: TaskSource) -> SourceConnectionState {
        let connection = collection.connections[source]
        if source == .codex {
            if store.taskError != nil {
                let recentlyVerified = store.lastTaskSync.map { Date().timeIntervalSince($0) < 30 } ?? false
                return recentlyVerified ? .partial : .unavailable
            }
            return store.lastTaskSync == nil ? .checking : .connected
        }
        return connection?.state ?? .checking
    }

    private func connectionLabel(_ state: SourceConnectionState) -> String {
        switch state {
        case .checking: "连接中"
        case .connected: "状态可读"
        case .partial: "部分可用"
        case .setupRequired: "待接入"
        case .unavailable: "读取失败"
        }
    }

    private func connectionColor(_ state: SourceConnectionState) -> Color {
        switch state {
        case .checking: Palette.gray
        case .connected: Palette.green
        case .partial: Palette.blue
        case .setupRequired: Palette.orange
        case .unavailable: Palette.red
        }
    }

    private func sourceRow(_ source: TaskSource) -> some View {
        let state = connectionState(for: source)
        let connection = collection.connections[source]
        let detail = source == .codex
            ? (store.taskError ?? (store.lastTaskSync == nil ? "正在连接 Codex" : "Codex 任务与额度"))
            : (connection?.detail ?? "正在读取工作台")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(connectionColor(state))
                    .frame(width: 7, height: 7)
                Text(source.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                Spacer()
                Text(connectionLabel(state))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(connectionColor(state))
            }
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let observedAt = source == .codex ? store.lastTaskSync : connection?.observedAt {
                HStack(spacing: 3) {
                    Text("上次读取")
                    Text(observedAt, style: .relative)
                }
                .font(.system(size: 10))
                .foregroundStyle(Palette.gray)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border, lineWidth: 1))
    }

    private var taskContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("最近任务与会话")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                Spacer()
                Text("按更新时间排序")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.secondary)
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
                    ForEach(collection.tasks, id: \.displayID) { task in taskRow(task) }
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

    private func taskRow(_ task: MonitoredTask) -> some View {
        Button {
            if let link = task.openURL { NSWorkspace.shared.open(link) }
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(color(for: task))
                    .frame(width: 7, height: 7)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.primary)
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        Text("\(task.source.label) · \(stateLabel(for: task))")
                            .foregroundStyle(color(for: task))
                        Text("·")
                            .foregroundStyle(Palette.secondary)
                        Text(task.updatedAt, style: .relative)
                            .foregroundStyle(Palette.secondary)
                    }
                    .font(.system(size: 10))
                }
                Spacer(minLength: 0)
                if task.openScope == .application {
                    Text(task.source == .piAgent ? "打开工作区" : "打开应用")
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
              : (task.source == .piAgent
                 ? "打开 VS Code 工作区；暂不能定位到原 Pi 终端"
                 : "打开 \(task.source.label) 应用；暂不能定位到此任务"))
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

    private func stateLabel(for task: MonitoredTask) -> String {
        guard task.state == .unknown else { return task.state.label }
        switch connectionState(for: task.source) {
        case .checking: return "核对中"
        case .setupRequired: return "待接入"
        case .unavailable: return "读取中断"
        case .connected, .partial: return "状态未确认"
        }
    }

    private func color(for task: MonitoredTask) -> Color {
        if task.state == .unknown {
            switch connectionState(for: task.source) {
            case .checking, .partial: return Palette.blue
            case .setupRequired: return Palette.orange
            case .unavailable: return Palette.red
            case .connected: return Palette.gray
            }
        }
        return switch task.state {
        case .checking: Palette.blue
        case .working: Palette.orange
        case .waiting: Palette.orange
        case .completed: Palette.green
        case .ended: Palette.green
        case .interrupted: Palette.orange
        case .failed: Palette.red
        case .unknown: Palette.gray
        case .sessionOnly: Palette.gray
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "hand.draw")
                .font(.system(size: 10))
            Text("拖动空白处移动悬浮框")
            Spacer()
            Text(showingSettings ? "7 个来源" : "最近 100 条")
        }
        .font(.system(size: 10))
        .foregroundStyle(Palette.secondary)
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.border).frame(height: 1)
        }
    }
}
