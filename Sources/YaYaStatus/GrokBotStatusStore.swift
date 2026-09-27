import Foundation

private actor GrokBotReader {
    private let persistenceDirectory: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        persistenceDirectory = home.appendingPathComponent(
            "Library/Application Support/Grok Bot/sand-client-persistence",
            isDirectory: true
        )
    }

    func readRecent(limit: Int) throws -> [MonitoredTask] {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: persistenceDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return [] }

        // The desktop client keeps one roster snapshot per account. Pick the
        // most recently written one and read only its row metadata.
        let candidates = files.filter {
            $0.pathExtension == "blob"
                && Self.decodedKey(for: $0)?.hasSuffix(".roster.last-roster") == true
        }
            .sorted {
                let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return first > second
            }
        var roster: [[String: Any]]?
        for file in candidates {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size > 0, size < 200_000,
                  let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = object["value"] as? [String: Any],
                  let rows = value["rows"] as? [[String: Any]],
                  rows.allSatisfy({ $0["id"] is String && $0["createdAt"] is NSNumber })
            else { continue }
            roster = rows
            break
        }

        let appURL = URL(fileURLWithPath: "/Applications/Grok Bot.app", isDirectory: true)
        let canOpenApp = fileManager.fileExists(atPath: appURL.path)
        let visibleRows = (roster ?? []).filter { $0["isHiddenFromSidebar"] as? Bool != true }
            .sorted {
                let first = ($0["updatedAt"] as? NSNumber)?.doubleValue ?? 0
                let second = ($1["updatedAt"] as? NSNumber)?.doubleValue ?? 0
                return first > second
            }
        return visibleRows.prefix(limit).compactMap { row in
            guard let id = row["id"] as? String, UUID(uuidString: id) != nil else { return nil }
            let name = ((row["name"] as? String) ?? (row["title"] as? String) ?? "未命名 Bot")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let millis = (row["updatedAt"] as? NSNumber)?.doubleValue
                ?? (row["createdAt"] as? NSNumber)?.doubleValue ?? 0
            return MonitoredTask(
                source: .grokBot,
                sourceTaskID: id,
                title: "Bot · \(name.isEmpty ? "未命名 Bot" : name)",
                state: .unknown,
                updatedAt: millis > 0 ? Date(timeIntervalSince1970: millis / 1_000) : .distantPast,
                openURL: canOpenApp ? appURL : nil,
                openScope: canOpenApp ? .application : .unavailable
            )
        }
    }

    private static func decodedKey(for file: URL) -> String? {
        var buffer = 0
        var bits = 0
        var bytes: [UInt8] = []
        for character in file.deletingPathExtension().lastPathComponent.lowercased() {
            let value: Int
            switch character {
            case "a"..."z": value = Int(character.asciiValue! - Character("a").asciiValue!)
            case "2"..."7": value = Int(character.asciiValue! - Character("2").asciiValue!) + 26
            default: return nil
            }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> bits) & 0xff))
                buffer &= (1 << bits) - 1
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}

@MainActor
final class GrokBotStatusStore {
    private let collection: TaskCollectionStore
    private let reader = GrokBotReader()
    private var pollTask: Task<Void, Never>?

    init(collection: TaskCollectionStore) { self.collection = collection }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        do {
            let tasks = try await reader.readRecent(limit: 10)
            collection.replaceTasks(from: .grokBot, with: tasks)
            collection.setConnection(SourceConnection(
                source: .grokBot,
                state: .limited,
                detail: tasks.isEmpty
                    ? "尚未读到 Grok Bot 会话快照"
                    : "只读 Bot 会话；无法判断云端任务状态；点击打开应用"
            ))
        } catch {
            collection.setConnection(SourceConnection(source: .grokBot, state: .unavailable, detail: error.localizedDescription))
        }
    }
}
