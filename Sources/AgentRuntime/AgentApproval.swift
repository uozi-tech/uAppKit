import AgentKit
import CryptoKit
import Foundation

/// 用户（或审批门）对一次调用的决定。
public enum ApprovalDecision: Sendable, Hashable {
    case granted
    case denied
    /// 本会话内放行**完全相同**的请求（工具名 + 审批内容逐字一致）。改一个字面量、标识符、
    /// 数字或格式都要重新审批。只有 `allowsSessionGrant` 的请求才认，否则按 `.granted` 处理。
    case grantedForSession
}

/// 一次待审批的工具调用。
public struct AgentApprovalRequest: Sendable, Hashable, Identifiable {
    public let toolCallID: String
    public let toolName: String
    /// 原始参数 JSON。
    public let arguments: String
    /// 审批卡上展示、会话放行按它匹配的内容（见 `AgentToolApprovalRequirement.ask`）；
    /// nil 时用 `arguments`。
    public let subject: String?
    /// 模型随参数给的理由（参数 JSON 里的 `reason`），审批卡上作为说明。
    public let reason: String?
    /// 审批策略转人工时给的说明（如「不是只读命令」）。
    public let policyNote: String?
    /// 是否允许「本会话允许」。`.alwaysManual` 的请求为 false。
    public let allowsSessionGrant: Bool

    public var id: String { toolCallID }

    public init(toolCallID: String, toolName: String, arguments: String, subject: String? = nil,
                reason: String? = nil, policyNote: String? = nil, allowsSessionGrant: Bool = true) {
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.arguments = arguments
        self.subject = subject
        self.reason = reason ?? Self.reason(from: arguments)
        self.policyNote = policyNote
        self.allowsSessionGrant = allowsSessionGrant
    }

    /// 审批卡上要展示的正文：有 `subject` 用它，否则把参数 JSON 排版一下。
    public var displayText: String {
        if let subject = subject?.trimmingCharacters(in: .whitespacesAndNewlines), !subject.isEmpty {
            return subject
        }
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8)
        else { return arguments }
        return text
    }

    /// 精确请求指纹：SHA-256(工具名 \0 去首尾空白的审批内容)。会话放行按它匹配。
    public var fingerprint: String {
        let source = (subject ?? arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data((toolName + "\u{0}" + source).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func with(policyNote: String?) -> AgentApprovalRequest {
        AgentApprovalRequest(toolCallID: toolCallID, toolName: toolName, arguments: arguments, subject: subject,
                             reason: reason, policyNote: policyNote, allowsSessionGrant: allowsSessionGrant)
    }

    /// 参数 JSON 里的 `reason` 字段（去首尾空白，空则 nil）。
    static func reason(from arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let reason = dict["reason"] as? String
        else { return nil }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - 审批门

/// 把需要人确认的请求交给人。本会话的放行列表只在审批门里维护（uTable 原先在会话里还有一份
/// 从未被填充的 `sessionGrants`，抽包时删掉了）。
public protocol ApprovalGate: Sendable {
    func request(_ request: AgentApprovalRequest) async -> ApprovalDecision
    /// 新对话 / 恢复历史时调用：清空本会话的放行列表。缺省什么都不做。
    func resetSession() async
}

extension ApprovalGate {
    public func resetSession() async {}
}

/// 交给 UI 的审批门：请求经 `presenter`（通常是 `AgentApprovalQueue.presenter`）挂到界面上，
/// 用户点完再回来。维护本会话的精确放行列表。
public actor InteractiveApprovalGate: ApprovalGate {
    public typealias Presenter = @MainActor @Sendable (AgentApprovalRequest) async -> ApprovalDecision

    private let presenter: Presenter
    private var sessionAllowList: Set<String> = []

    public init(presenter: @escaping Presenter) {
        self.presenter = presenter
    }

    public func request(_ request: AgentApprovalRequest) async -> ApprovalDecision {
        // 指纹由门自己按正在展示的请求算，不信任 presenter 回来的任何值。
        let fingerprint = request.fingerprint
        if request.allowsSessionGrant, sessionAllowList.contains(fingerprint) {
            return .granted
        }
        let decision = await presenter(request)
        switch decision {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .grantedForSession:
            if request.allowsSessionGrant { sessionAllowList.insert(fingerprint) }
            return .granted
        }
    }

    public func resetSession() async {
        sessionAllowList.removeAll()
    }

    public func clearSessionAllowList() {
        sessionAllowList.removeAll()
    }

    public var sessionAllowListCount: Int { sessionAllowList.count }
}

/// 一律拒绝（没有 UI 的宿主、只读模式）。
public struct AutoDenyApprovalGate: ApprovalGate {
    public init() {}

    public func request(_ request: AgentApprovalRequest) async -> ApprovalDecision { .denied }
}

// MARK: - 审批策略

/// 审批策略的结论。
public enum AgentApprovalVerdict: Sendable, Hashable {
    /// 不问人直接放行（如确定性判定的只读命令）。`reason` 进审计日志。
    case allow(reason: String)
    /// 不问人直接拒绝；`reason` 作为工具结果交回模型。
    case deny(reason: String)
    /// 交给审批门问人；`note` 显示在审批卡上。
    case askUser(note: String?)
}

/// 在审批门之前的预判（只作用于 `.ask` 的请求；`.alwaysManual` 跳过策略）。uTerm 的
/// 三档安全开关、AI 审查都从这里接入。
public protocol AgentApprovalPolicy: Sendable {
    func evaluate(_ request: AgentApprovalRequest) async -> AgentApprovalVerdict
}

/// 缺省策略：全部问人。
public struct AlwaysAskApprovalPolicy: AgentApprovalPolicy {
    public init() {}

    public func evaluate(_ request: AgentApprovalRequest) async -> AgentApprovalVerdict {
        .askUser(note: nil)
    }
}

/// 「跑一条 shell 命令」一类工具的策略：包一层 AgentKit 的 `AgentToolApproval` 规则。
///
/// - 确定性判定的只读命令（`ReadOnlyShellCommand` 白名单，含 git 的只读子命令）直接放行；
/// - `ManualOnlyCommand` 硬规则命中的（删除、凭据、远程执行…）交给人，AI 审查不能放宽；
/// - 其余：配了 `review`（独立、无工具的模型请求）就请 AI 审查，批准则放行，否则交给人；
///   没配就交给人。
///
/// uGit 的 `run_git` 这样接：`commandPrefix: "git "`、`command` 从参数里取出参数数组再用
/// `shellJoin` 拼起来，git 只读白名单（status / log / diff / show / blame …）就直接复用。
public struct ShellCommandApprovalPolicy: AgentApprovalPolicy {
    public typealias CommandExtractor = @Sendable (AgentApprovalRequest) -> String?
    public typealias IntentProvider = @Sendable (AgentApprovalRequest) async -> (userIntent: String, context: String)
    public typealias Review = @Sendable (_ systemPrompt: String, _ envelope: String) async throws -> String

    /// 由本策略判定的工具名；其余工具一律问人。
    public let toolNames: Set<String>
    /// 拼在命令前面的东西（`"git "`）。
    public let commandPrefix: String
    public let mode: AgentToolApproval.Mode
    private let command: CommandExtractor
    private let intent: IntentProvider?
    private let review: Review?

    /// - Parameters:
    ///   - command: 从请求里取出命令文本（不含 `commandPrefix`）；取不出返回 nil → 问人。
    ///     缺省取参数 JSON 的 `command` 字段。
    ///   - intent: 给 AI 审查的用户意图与上下文；不配 `review` 时用不到。
    ///   - review: 独立、无工具、有超时的模型请求（见 `AgentToolApproval.evaluate`）。nil = 不做 AI 审查。
    public init(toolNames: Set<String> = ["run_command"],
                commandPrefix: String = "",
                mode: AgentToolApproval.Mode = .readOnly,
                command: @escaping CommandExtractor = ShellCommandApprovalPolicy.commandField,
                intent: IntentProvider? = nil,
                review: Review? = nil) {
        self.toolNames = toolNames
        self.commandPrefix = commandPrefix
        self.mode = mode
        self.command = command
        self.intent = intent
        self.review = review
    }

    public func evaluate(_ request: AgentApprovalRequest) async -> AgentApprovalVerdict {
        guard toolNames.contains(request.toolName),
              let body = command(request)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty else { return .askUser(note: nil) }
        let (userIntent, context) = await intent?(request) ?? ("", "")
        // AgentKit 的规则按 `run_command` 认工具；这里把命令原样交给它判。
        let approvalRequest = AgentToolApproval.Request(
            id: request.toolCallID + "-" + UUID().uuidString, toolName: "run_command",
            command: commandPrefix + body, userIntent: userIntent, context: context, mode: mode)
        if AgentToolApproval.isReadOnly(approvalRequest) {
            return .allow(reason: AgentToolApproval.readOnlyReason)
        }
        guard let review else {
            return .askUser(note: AgentToolApproval.manualReason(for: approvalRequest))
        }
        let decision = await AgentToolApproval.evaluate(approvalRequest, review: review)
        return decision.approved ? .allow(reason: decision.reason) : .askUser(note: decision.reason)
    }

    /// 缺省取参数 JSON 的 `command` 字段。
    public static let commandField: CommandExtractor = { request in
        jsonObject(request.arguments)?["command"] as? String
    }

    /// 取参数 JSON 里的字符串数组字段（如 `run_git` 的 `args`）并拼成 shell 词。
    public static func argumentArray(_ key: String) -> CommandExtractor {
        { request in
            guard let array = jsonObject(request.arguments)?[key] as? [Any] else { return nil }
            let words = array.compactMap { $0 as? String }
            guard words.count == array.count, !words.isEmpty else { return nil }
            return shellJoin(words)
        }
    }

    /// 把参数数组拼成 shell 词：只含安全字符的原样，其余用单引号包起来（内部单引号转义）。
    /// 只读判定按 shell 文法分词，所以这里的引号规则必须与 sh 一致。
    public static func shellJoin(_ words: [String]) -> String {
        words.map { word in
            let safe = CharacterSet(charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=@,+%^")
            if !word.isEmpty, word.unicodeScalars.allSatisfy({ safe.contains($0) }) { return word }
            return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    private static func jsonObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
