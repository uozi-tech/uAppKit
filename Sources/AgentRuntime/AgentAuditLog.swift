import Foundation

/// 一次工具派发的审计记录。
public struct AgentAuditEntry: Sendable, Equatable {
    /// 谁放行的。
    public enum Approval: String, Sendable, Equatable {
        /// 工具声明不需要审批。
        case notRequired = "not_required"
        /// 审批策略直接放行。
        case policy
        /// 用户放行（含本会话放行命中）。
        case user
        /// 审批策略拒绝。
        case policyDenied = "policy_denied"
        /// 用户拒绝。
        case userDenied = "user_denied"
    }

    public let date: Date
    public let tool: String
    public let arguments: String
    public let approval: Approval?
    public let isError: Bool
    public let contentLength: Int

    public init(date: Date = Date(), tool: String, arguments: String, approval: Approval?,
                isError: Bool, contentLength: Int) {
        self.date = date
        self.tool = tool
        self.arguments = arguments
        self.approval = approval
        self.isError = isError
        self.contentLength = contentLength
    }

    /// 兼容 uTable 原格式的 `approved` 字段：放行 true、拒绝 false、不需要审批时不写。
    public var approved: Bool? {
        switch approval {
        case .policy, .user: return true
        case .policyDenied, .userDenied: return false
        case .notRequired, nil: return nil
        }
    }
}

/// JSONL 审计日志（每行一条：`ts`、`tool`、`args`（截到 4096 个 Unicode 标量）、`approved`、
/// `approval`、`isError`、`contentLen`）。尽力而为：写失败不打断 agent 循环。
///
/// 写在一条串行队列上，不占主线程；`flush()` 等队列排空（测试用）。
public final class AgentAuditLog: Sendable {
    public let url: URL
    private let queue = DispatchQueue(label: "AgentRuntime.AgentAuditLog")

    /// 参数超过这么多字节就截断。
    public static let argumentLimit = 4096

    public init(url: URL) {
        self.url = url
    }

    public func append(_ entry: AgentAuditEntry) {
        guard let line = Self.line(for: entry) else { return }
        let url = url
        queue.async {
            Self.write(line, to: url)
        }
    }

    /// 等已排队的写入完成。
    public func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    static func line(for entry: AgentAuditEntry) -> Data? {
        let arguments: String
        if entry.arguments.utf8.count <= argumentLimit {
            arguments = entry.arguments
        } else {
            arguments = String(String.UnicodeScalarView(entry.arguments.unicodeScalars.prefix(argumentLimit)))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var payload: [String: Any] = [
            "ts": formatter.string(from: entry.date),
            "tool": entry.tool,
            "args": arguments,
            "isError": entry.isError,
            "contentLen": entry.contentLength,
        ]
        if let approved = entry.approved { payload["approved"] = approved }
        if let approval = entry.approval { payload["approval"] = approval.rawValue }
        guard var data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return nil }
        data.append(0x0A)
        return data
    }

    private static func write(_ line: Data, to url: URL) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}
