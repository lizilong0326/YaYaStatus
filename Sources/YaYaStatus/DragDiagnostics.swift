import AppKit

@MainActor
final class DragDiagnostics {
    static let shared = DragDiagnostics()

    private let startedAt = ProcessInfo.processInfo.systemUptime
    private let writeQueue = DispatchQueue(label: "com.local.yayastatus.drag-diagnostics")
    private let fileHandle: FileHandle?

    private init() {
        guard UserDefaults.standard.bool(forKey: "yayastatus-drag-diagnostics") else {
            fileHandle = nil
            return
        }
        let directory = URL(fileURLWithPath: "/tmp/YaYaStatus", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let name = "drag-\(Int(Date().timeIntervalSince1970))-\(ProcessInfo.processInfo.processIdentifier).log"
            let url = directory.appendingPathComponent(name)
            try Data().write(to: url, options: .atomic)
            fileHandle = try FileHandle(forWritingTo: url)
            record("session.start wall=\(ISO8601DateFormatter().string(from: Date())) " +
                   "pid=\(ProcessInfo.processInfo.processIdentifier)")
        } catch {
            fileHandle = nil
            NSLog("YaYaStatus drag diagnostics could not open log: %@", error.localizedDescription)
        }
    }

    func record(_ name: String, window: NSWindow? = nil,
                event: NSEvent? = nil, details: String = "") {
        guard let fileHandle else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let cursor = NSEvent.mouseLocation
        let frame = window?.frame ?? .zero
        let eventLocation = event?.locationInWindow ?? .zero
        let line = String(format: "%.4f %@ cursor=(%.1f,%.1f) frame=(%.1f,%.1f,%.1f,%.1f) " +
                          "event=(%.1f,%.1f) window=%d collapsed=%d %@\n",
                          elapsed, name, cursor.x, cursor.y,
                          frame.minX, frame.minY, frame.width, frame.height,
                          eventLocation.x, eventLocation.y,
                          event?.windowNumber ?? -1,
                          UserDefaults.standard.bool(forKey: "yayastatus-is-collapsed") ? 1 : 0,
                          details)
        writeQueue.async {
            fileHandle.write(Data(line.utf8))
        }
    }
}
