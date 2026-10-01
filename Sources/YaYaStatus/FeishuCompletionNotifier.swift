import CryptoKit
import Foundation
import SwiftUI

@MainActor
final class FeishuCompletionNotifier: ObservableObject {
    @Published private(set) var statusText = "尚未发送"
    @Published private(set) var isSending = false
    private var pendingCount = 0

    func notify(_ task: MonitoredTask) {
        let title = String(task.title.replacingOccurrences(of: "\n", with: " ").prefix(120))
        let message = "【丫丫状态】任务已完成\n来源：\(task.source.label)\n任务：\(title.isEmpty ? "未命名任务" : title)"
        let eventTime = task.endedAt ?? task.updatedAt
        let event = "\(task.id):\(Int64(eventTime.timeIntervalSince1970 * 1_000))"
        let digest = SHA256.hash(data: Data(event.utf8))
        let key = "yaya-" + digest.map { String(format: "%02x", $0) }.joined().prefix(40)
        deliver(message, idempotencyKey: key)
    }

    func sendTest() {
        deliver("【丫丫状态】飞书完成提醒测试\n这条消息由丫丫状态应用发送。",
                idempotencyKey: "yaya-test-\(UUID().uuidString)")
    }

    private func deliver(_ message: String, idempotencyKey: String) {
        pendingCount += 1
        isSending = true
        statusText = "正在发送到飞书…"
        Task.detached(priority: .utility) { [weak self] in
            let result = Result { try FeishuCLIRunner.send(message, idempotencyKey: idempotencyKey) }
            await MainActor.run {
                guard let self else { return }
                self.pendingCount -= 1
                self.isSending = self.pendingCount > 0
                switch result {
                case .success:
                    self.statusText = "已发送到飞书"
                case .failure(let error):
                    self.statusText = "发送失败：\(error.localizedDescription)"
                }
            }
        }
    }
}

private enum FeishuCLIRunner {
    enum Failure: LocalizedError {
        case cliMissing
        case invalidResponse
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .cliMissing: "找不到 feishu-cli，请先安装并登录"
            case .invalidResponse: "飞书接口没有返回有效的账号或消息 ID"
            case .commandFailed(let detail): detail
            }
        }
    }

    static func send(_ message: String, idempotencyKey: String) throws -> String {
        guard let executable = executableURL() else { throw Failure.cliMissing }
        let userData = try run(executable, arguments: [
            "api", "GET", "/open-apis/authen/v1/user_info", "--as", "user"
        ])
        guard let user = try JSONSerialization.jsonObject(with: userData) as? [String: Any],
              (user["code"] as? NSNumber)?.intValue == 0,
              let data = user["data"] as? [String: Any],
              let openID = data["open_id"] as? String, !openID.isEmpty else {
            throw Failure.invalidResponse
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yayastatus-feishu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let contentFile = directory.appendingPathComponent("message.json")
        let content = try JSONSerialization.data(withJSONObject: ["text": message])
        guard FileManager.default.createFile(atPath: contentFile.path, contents: content,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw Failure.commandFailed("无法准备消息内容")
        }

        let response = try run(executable, arguments: [
            "msg", "send", "--receive-id-type", "open_id", "--receive-id", openID,
            "--msg-type", "text", "--content-file", contentFile.path,
            "--idempotency-key", idempotencyKey, "-o", "json"
        ])
        guard let sent = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let messageID = sent["message_id"] as? String, !messageID.isEmpty else {
            throw Failure.invalidResponse
        }
        return messageID
    }

    private static func executableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let candidates = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] + pathEntries
        return candidates.map { URL(fileURLWithPath: $0).appendingPathComponent("feishu-cli") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func run(_ executable: URL, arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let response = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.commandFailed(String((detail?.isEmpty == false ? detail! : "飞书 CLI 调用失败").prefix(180)))
        }
        return response
    }
}
