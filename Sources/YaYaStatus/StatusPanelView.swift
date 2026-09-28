import AppKit
import SwiftUI

private enum Palette {
    static let darkBackground = Color.black.opacity(0.8)
    static let lightBackground = Color(nsColor: .windowBackgroundColor).opacity(0.92)
    static let surface = Color.primary.opacity(0.075)
    static let control = Color.primary.opacity(0.07)
    static let border = Color.primary.opacity(0.12)
    static let primary = Color.primary
    static let secondary = Color.secondary
    static let green = Color(nsColor: .systemGreen)
    static let orange = Color(nsColor: .systemOrange)
    static let blue = Color(nsColor: .systemBlue)
    static let red = Color(nsColor: .systemRed)
    static let gray = Color(nsColor: .systemGray)
}

struct StatusPanelView: View {
    @ObservedObject var store: CodexStatusStore
    @ObservedObject var collection: TaskCollectionStore
    let onRefresh: () -> Void
    let onSizeChange: (NSSize) -> Void
    @State private var showingSettings = false
    @State private var knownTaskStates: [String: MonitoredTaskState]?
    @State private var finishCue: OrbTaskFinishCue?
    @State private var showWorkingBeam = false
    @AppStorage("yayastatus-is-dark-mode") private var isDarkMode = true
    @AppStorage("yayastatus-is-collapsed") private var isCollapsed = false

    private var activeTaskCount: Int {
        collection.activeTasks.count
    }

    private var workingTaskCount: Int {
        collection.activeTasks.filter { $0.state == .working }.count
    }

    private var recentFinishedTasks: [MonitoredTask] {
        collection.tasks.filter { task in
            switch task.state {
            case .completed, .ended, .interrupted, .failed: true
            default: false
            }
        }
        .sorted { lhs, rhs in
            let lhsEnd = lhs.endedAt ?? lhs.updatedAt
            let rhsEnd = rhs.endedAt ?? rhs.updatedAt
            return lhsEnd == rhsEnd ? lhs.id < rhs.id : lhsEnd > rhsEnd
        }
    }

    private var panelHeight: CGFloat {
        if isCollapsed { return StatusOrbMetrics.windowSide }
        if showingSettings { return 560 }
        let finishedCount = recentFinishedTasks.count
        if activeTaskCount == 0 && finishedCount == 0 { return 140 }
        let visibleRows = min(6, activeTaskCount + finishedCount)
        return min(390, max(110, 70 + CGFloat(visibleRows) * 43 + (finishedCount > 0 ? 21 : 0)))
    }

    private var panelSize: NSSize {
        NSSize(width: isCollapsed ? StatusOrbMetrics.windowSide : (showingSettings ? 390 : 350),
               height: panelHeight)
    }

    private var panelBackground: Color {
        isDarkMode ? Palette.darkBackground : Palette.lightBackground
    }

    private var readableGreen: Color {
        isDarkMode ? Palette.green : Color(red: 0.02, green: 0.43, blue: 0.18)
    }

    private var readableOrange: Color {
        isDarkMode ? Palette.orange : Color(red: 0.60, green: 0.28, blue: 0.02)
    }

    private var failedSourceCount: Int {
        collection.connections.values.filter { $0.state == .unavailable }.count
            + (connectionState(for: .codex) == .unavailable ? 1 : 0)
    }

    private var emptyTitle: String {
        store.isRefreshing ? "正在检查任务…" : "当前没有进行中的任务"
    }

    var body: some View {
        Group {
            if isCollapsed {
                collapsedOrb
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if showingSettings {
                        settingsHeader
                        settingsContent
                            .padding(.top, 16)
                    } else {
                        header
                        taskContent
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(width: panelSize.width, height: panelSize.height)
                .background {
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .fill(panelBackground)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .stroke(Palette.border, lineWidth: 1)
                }
            }
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
        .animation(.easeInOut(duration: 0.2), value: isDarkMode)
        .onAppear {
            onSizeChange(panelSize)
            if knownTaskStates == nil {
                knownTaskStates = StatusOrbTransition.states(for: collection.tasks)
            }
        }
        .onChange(of: panelSize) { onSizeChange($0) }
        .onChange(of: collection.tasks) { _ in updateFinishCue() }
        .task(id: workingTaskCount > 0) {
            showWorkingBeam = false
            guard workingTaskCount > 0 else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { showWorkingBeam = true }
        }
        .task(id: finishCue?.id) {
            guard let cue = finishCue else { return }
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled && finishCue?.id == cue.id { finishCue = nil }
        }
    }

    private func updateFinishCue() {
        let current = StatusOrbTransition.states(for: collection.tasks)
        defer { knownTaskStates = current }
        guard let knownTaskStates else { return }
        if let newCue = StatusOrbTransition.newFinish(previous: knownTaskStates,
                                                      current: collection.tasks) {
            finishCue = newCue
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            if let mark = BrandIcon.mark {
                Image(nsImage: mark)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 19, height: 19)
            } else {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(readableGreen)
                    .frame(width: 19, height: 19)
            }
            Text("丫丫状态")
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Palette.secondary)
            Text("\(activeTaskCount) 个进行中")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(activeTaskCount == 0 ? Palette.secondary : readableOrange)
            Spacer()
            appearanceButton
            collapseButton
            Button {
                showingSettings = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                        .frame(width: 27, height: 27)
                        .background(Circle().fill(Palette.control))
                    if failedSourceCount > 0 {
                        Circle().fill(Palette.red).frame(width: 6, height: 6)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("设置与工作台")
        }
        .contentShape(Rectangle())
    }

    private var appearanceButton: some View {
        Button { isDarkMode.toggle() } label: {
            Image(systemName: isDarkMode ? "sun.max" : "moon.stars")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .frame(width: 27, height: 27)
                .background(Circle().fill(Palette.control))
        }
        .buttonStyle(.plain)
        .help(isDarkMode ? "切换到日间外观" : "切换到深色外观")
    }

    private var collapseButton: some View {
        Button { isCollapsed = true } label: {
            Image(systemName: "minus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .frame(width: 27, height: 27)
                .background(Circle().fill(Palette.control))
        }
        .buttonStyle(.plain)
        .help("收起成状态圆球")
    }

    private var collapsedOrb: some View {
        ZStack {
            StatusOrbFace(activeTaskCount: activeTaskCount,
                          workingTaskCount: workingTaskCount,
                          showWorkingBeam: showWorkingBeam,
                          finishCue: finishCue,
                          hasSourceError: failedSourceCount > 0,
                          isDarkMode: isDarkMode)
                .accessibilityHidden(true)
            OrbDragControl(
                accessibilityLabel: orbStatusLabel + "，点击展开丫丫状态",
                toolTip: orbStatusLabel + "；点击展开，拖动可移动"
            ) {
                showingSettings = false
                isCollapsed = false
            }
            .frame(width: StatusOrbMetrics.windowSide, height: StatusOrbMetrics.windowSide)
        }
        .frame(width: StatusOrbMetrics.windowSide, height: StatusOrbMetrics.windowSide)
    }

    private var orbStatusLabel: String {
        if let finishCue {
            return "\(finishCue.taskTitle)\(finishCue.outcome.label)，\(activeTaskCount) 个进行中"
        }
        return "\(activeTaskCount) 个进行中"
    }

    private var settingsHeader: some View {
        HStack(spacing: 8) {
            Button {
                showingSettings = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                    .frame(width: 27, height: 27)
                    .background(Circle().fill(Palette.control))
            }
            .buttonStyle(.plain)
            .help("返回任务列表")
            VStack(alignment: .leading, spacing: 2) {
                Text("设置")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                Text("工作台连接状态")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.secondary)
            }
            Spacer()
            appearanceButton
            collapseButton
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 27, height: 27)
                    .background(Circle().fill(Palette.control))
            }
            .buttonStyle(.plain)
            .help("刷新全部工作台")
        }
        .contentShape(Rectangle())
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
        case .connected: readableGreen
        case .partial: Palette.blue
        case .setupRequired: readableOrange
        case .unavailable: Palette.red
        }
    }

    private func sourceRow(_ source: TaskSource) -> some View {
        let state = connectionState(for: source)
        let connection = collection.connections[source]
        let detail = source == .codex
            ? (store.taskError ?? (store.lastTaskSync == nil ? "正在连接 Codex" : "Codex 任务状态"))
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(collection.activeTasks, id: \.displayID) { task in taskRow(task) }
                if !recentFinishedTasks.isEmpty {
                    Text("最近结束")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                        .padding(.top, activeTaskCount > 0 ? 7 : 0)
                        .padding(.bottom, 1)
                    ForEach(recentFinishedTasks, id: \.displayID) { task in taskRow(task) }
                }
                if collection.activeTasks.isEmpty && recentFinishedTasks.isEmpty { emptyState }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func taskRow(_ task: MonitoredTask) -> some View {
        Button {
            if let link = task.openURL { NSWorkspace.shared.open(link) }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(color(for: task))
                    .frame(width: 6, height: 6)
                    .frame(width: 11)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text("\(task.source.label) · \(stateLabel(for: task))")
                            .foregroundStyle(color(for: task))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        if task.state == .working || task.state == .waiting {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(taskTimeLabel(for: task, now: context.date))
                                    .foregroundStyle(Palette.secondary)
                                    .lineLimit(1)
                            }
                        } else {
                            Text(taskTimeLabel(for: task, now: .now))
                                .foregroundStyle(Palette.secondary)
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 9.5))
                }
                if task.openURL != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.surface))
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
        VStack(spacing: 5) {
            Image(systemName: "tray")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(Palette.secondary)
            Text(emptyTitle)
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
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

    private func taskTimeLabel(for task: MonitoredTask, now: Date) -> String {
        if task.state == .working || task.state == .waiting {
            guard let startedAt = task.startedAt, startedAt <= now else { return "运行时长待确认" }
            let seconds = Int(now.timeIntervalSince(startedAt))
            let days = seconds / 86_400
            let hours = (seconds % 86_400) / 3_600
            let minutes = (seconds % 3_600) / 60
            let remainingSeconds = seconds % 60
            if days > 0 { return String(format: "已运行 %d天 %02d:%02d:%02d", days, hours, minutes, remainingSeconds) }
            return String(format: "已运行 %02d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        if task.state == .completed || task.state == .ended
            || task.state == .interrupted || task.state == .failed {
            guard let endedAt = task.endedAt else { return "结束时间未记录" }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            if Calendar.current.isDateInToday(endedAt) {
                formatter.dateFormat = "HH:mm"
                return "结束于 今天 \(formatter.string(from: endedAt))"
            }
            if Calendar.current.isDateInYesterday(endedAt) {
                formatter.dateFormat = "HH:mm"
                return "结束于 昨天 \(formatter.string(from: endedAt))"
            }
            formatter.dateFormat = Calendar.current.component(.year, from: endedAt) == Calendar.current.component(.year, from: now)
                ? "M月d日 HH:mm" : "yyyy年M月d日 HH:mm"
            return "结束于 \(formatter.string(from: endedAt))"
        }
        return task.state == .sessionOnly ? "无任务时间" : "任务时间未确认"
    }

    private func color(for task: MonitoredTask) -> Color {
        if task.state == .unknown {
            switch connectionState(for: task.source) {
            case .checking, .partial: return Palette.blue
            case .setupRequired: return readableOrange
            case .unavailable: return Palette.red
            case .connected: return Palette.gray
            }
        }
        return switch task.state {
        case .checking: Palette.blue
        case .working: readableOrange
        case .waiting: readableOrange
        case .completed: readableGreen
        case .ended: readableGreen
        case .interrupted: Palette.gray
        case .failed: Palette.red
        case .unknown: Palette.gray
        case .sessionOnly: Palette.gray
        }
    }
}
