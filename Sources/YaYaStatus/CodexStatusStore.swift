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
    private var quotaLoop: Task<Void, Never>?
    private var taskLoop: Task<Void, Never>?
    private var eventRefreshTask: Task<Void, Never>?
    private var isStarted = false

    init(
        client: IslandCodexAppServerClient = IslandCodexAppServerClient(),
        runtimeIndex: IslandCodexTaskRuntimeIndex = IslandCodexTaskRuntimeIndex(),
        collection: TaskCollectionStore? = nil
    ) {
        self.client = client
        self.runtimeIndex = runtimeIndex
        self.collection = collection
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
        for attempt in 0..<2 {
            do {
                let fetched = try await client.readRecentTasks(limit: 16)
                if let states = try? await runtimeIndex.latestStates(for: fetched.map(\.id)) {
                    tasks = fetched.map { task in
                        guard let runtime = states[task.id] else { return task }
                        return task.withState(runtime.taskState())
                    }
                } else {
                    tasks = fetched
                }
                taskError = nil
                lastTaskSync = .now
                publishToCollection()
                persistCache()
                return
            } catch {
                if attempt == 0, lastTaskSync == nil, isStarted {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                taskError = error.localizedDescription
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
                let interval: UInt64 = self.workingTasks.isEmpty ? 15 : 2
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
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else {
            return
        }
        if var cachedQuota = cache.quota {
            cachedQuota.freshness = .stale
            quota = cachedQuota
        }
        tasks = cache.tasks
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
                openURL: task.deepLink,
                openScope: .exactTask
            )
        })
    }

    private func persistCache() {
        let cache = Cache(quota: quota, tasks: tasks)
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }
}
