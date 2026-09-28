import Foundation

@MainActor
final class CodexStatusStore: ObservableObject {
    private struct Cache: Codable {
        let quota: CodexQuotaSnapshot?
        let tasks: [CodexTaskSummary]
    }

    @Published private(set) var quota: CodexQuotaSnapshot?
    @Published private(set) var tasks: [CodexTaskSummary] = []
    @Published private(set) var quotaError: String?
    @Published private(set) var taskError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastTaskSync: Date?

    private static let cacheKey = "yayastatus-codex-status-cache-v1"
    private let client: IslandCodexAppServerClient
    private let runtimeIndex: IslandCodexTaskRuntimeIndex
    private let collection: TaskCollectionStore?
    private let defaults: UserDefaults
    private var quotaLoop: Task<Void, Never>?
    private var taskLoop: Task<Void, Never>?
    private var eventRefreshTask: Task<Void, Never>?
    private var isStarted = false
    private var isTaskRefreshing = false
    private var taskRefreshQueued = false

    init(
        client: IslandCodexAppServerClient = IslandCodexAppServerClient(),
        runtimeIndex: IslandCodexTaskRuntimeIndex = IslandCodexTaskRuntimeIndex(),
        collection: TaskCollectionStore? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.runtimeIndex = runtimeIndex
        self.collection = collection
        self.defaults = defaults
        restoreCache()
    }

    var preferredQuota: CodexQuotaWindow? { quota?.preferredWindow }

    var displayQuotaWindows: [CodexQuotaWindow] {
        Array((quota?.visibleWindows ?? []).prefix(2))
    }

    var workingTasks: [CodexTaskSummary] {
        tasks.filter { $0.state == .working }
    }

    var isConnected: Bool {
        quota != nil && quotaError == nil
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        Task { [weak self] in
            guard let self else { return }
            await client.setRateLimitUpdatedHandler { [weak self] in
                Task { @MainActor in self?.scheduleEventRefresh() }
            }
            await refreshAll()
            startLoops()
        }
    }

    func stop() {
        isStarted = false
        taskRefreshQueued = false
        quotaLoop?.cancel()
        taskLoop?.cancel()
        eventRefreshTask?.cancel()
        quotaLoop = nil
        taskLoop = nil
        eventRefreshTask = nil
        let client = client
        Task {
            await client.setRateLimitUpdatedHandler(nil)
            await client.stop()
        }
    }

    func refreshNow() {
        Task { [weak self] in await self?.refreshAll() }
    }

    private func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await refreshQuota()
        await refreshTasks()
    }

    private func refreshQuota() async {
        do {
            quota = try await client.readQuota()
            quotaError = nil
            persistCache()
        } catch {
            quotaError = error.localizedDescription
            if var cached = quota {
                cached.freshness = .stale
                quota = cached
            }
        }
    }

    private func refreshTasks() async {
        if isTaskRefreshing {
            taskRefreshQueued = true
            return
        }
        isTaskRefreshing = true
        defer {
            isTaskRefreshing = false
            if taskRefreshQueued && isStarted {
                taskRefreshQueued = false
                Task { [weak self] in await self?.refreshTasks() }
            }
        }
        for attempt in 0..<2 {
            do {
                let fetched = try await client.readRecentTasks(limit: TaskCollectionStore.recentTaskLimit)
                if fetched.isEmpty && !tasks.isEmpty {
                    throw IslandCodexClientError.rpc("任务列表意外返回空，已保留上次记录并等待重试")
                }

                // thread/list does not distinguish completed and interrupted
                // turns. Never replace verified states with its unknown fallback.
                let states = try await runtimeIndex.latestStates(for: fetched.map(\.id))
                if states.isEmpty && fetched.contains(where: { fetchedTask in
                    tasks.contains { $0.id == fetchedTask.id && $0.state != .unknown }
                }) {
                    throw IslandCodexRuntimeIndexError.query("已有任务的状态暂时没有返回")
                }
                let previous = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
                tasks = fetched.map { task in
                    if let runtime = states[task.id] {
                        return task.withRuntime(runtime)
                    }
                    if task.state == .working {
                        return CodexTaskSummary(id: task.id, title: task.title, state: task.state,
                                                updatedAt: task.updatedAt, source: task.source,
                                                startedAt: previous[task.id]?.startedAt)
                    }
                    if let old = previous[task.id], old.state != .working {
                        return CodexTaskSummary(id: task.id, title: task.title, state: old.state,
                                                updatedAt: task.updatedAt, source: task.source,
                                                startedAt: old.startedAt, endedAt: old.endedAt)
                    }
                    return task
                }
                taskError = nil
                lastTaskSync = .now
                publishToCollection()
                persistCache()
                return
            } catch {
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    continue
                }
                let isStale = lastTaskSync.map({ Date().timeIntervalSince($0) > 30 }) ?? true
                taskError = isStale
                    ? "Codex 读取中断，旧的工作中状态已撤回：\(error.localizedDescription)"
                    : "Codex 暂时读取失败，保留上次状态并重试：\(error.localizedDescription)"
                if isStale {
                    let demoted = tasks.map { $0.state == .working ? $0.withState(.unknown) : $0 }
                    if demoted != tasks {
                        tasks = demoted
                        publishToCollection()
                    }
                }
            }
        }
    }

    private func startLoops() {
        quotaLoop?.cancel()
        taskLoop?.cancel()

        quotaLoop = Task { [weak self] in
            while let self, self.isStarted, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard self.isStarted, !Task.isCancelled else { break }
                await self.refreshQuota()
            }
        }

        taskLoop = Task { [weak self] in
            while let self, self.isStarted, !Task.isCancelled {
                let interval: UInt64 = self.taskError != nil || !self.workingTasks.isEmpty ? 2 : 15
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
                guard self.isStarted, !Task.isCancelled else { break }
                await self.refreshTasks()
            }
        }
    }

    private func scheduleEventRefresh() {
        eventRefreshTask?.cancel()
        eventRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.refreshQuota()
        }
    }

    private func restoreCache() {
        guard let data = defaults.data(forKey: Self.cacheKey),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else {
            return
        }
        if var cachedQuota = cache.quota {
            cachedQuota.freshness = .stale
            quota = cachedQuota
        }
        tasks = cache.tasks.map { $0.state == .working ? $0.withState(.unknown) : $0 }
        publishToCollection()
    }

    private func publishToCollection() {
        collection?.replaceTasks(from: .codex, with: tasks.map { task in
            let state: MonitoredTaskState
            switch task.state {
            case .working: state = .working
            case .completed: state = .completed
            case .interrupted: state = .interrupted
            case .error: state = .failed
            case .unknown: state = .unknown
            }
            return MonitoredTask(
                source: .codex,
                sourceTaskID: task.id,
                title: task.title,
                state: state,
                updatedAt: task.updatedAt,
                startedAt: task.startedAt,
                endedAt: task.endedAt,
                openURL: task.deepLink,
                openScope: .exactTask
            )
        })
    }

    private func persistCache() {
        let cache = Cache(quota: quota, tasks: tasks)
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: Self.cacheKey)
        }
    }
}
