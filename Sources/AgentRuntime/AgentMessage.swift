import AgentKit
import Foundation

/// 模型发起的一次工具调用。`arguments` 是收齐了的参数 JSON。
public struct AgentToolCall: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// 会话里的一条消息（uTable 的形状：工具结果是独立消息，按 `toolCallID` 对上发起它的调用）。
public enum AgentMessage: Sendable, Hashable, Codable {
    case system(String)
    case user(String)
    case assistant(content: String?, toolCalls: [AgentToolCall])
    case toolResult(toolCallID: String, content: String, isError: Bool)

    public var role: String {
        switch self {
        case .system: return "system"
        case .user: return "user"
        case .assistant: return "assistant"
        case .toolResult: return "tool"
        }
    }

    /// assistant 消息带的工具调用；其余为空。
    public var toolCalls: [AgentToolCall] {
        if case .assistant(_, let calls) = self { return calls }
        return []
    }

    /// 请求层的形状。`thinkingReplay` 按首个 tool call 的 id 填回对应的 assistant 消息；
    /// 发不发出去由请求层按 `reasoning.replaysThinking` 决定。
    func wireMessage(thinkingReplay: [String: [LLMThinkingBlock]] = [:]) -> LLMWireMessage {
        switch self {
        case .system(let text):
            return .system(text)
        case .user(let text):
            return .user(text)
        case .assistant(let content, let toolCalls):
            return .assistant(
                text: content,
                toolCalls: toolCalls.map { LLMToolCall(id: $0.id, name: $0.name, argumentsJSON: $0.arguments) },
                thinking: toolCalls.first.flatMap { thinkingReplay[$0.id] } ?? [])
        case .toolResult(let id, let content, let isError):
            return .toolResult(toolCallID: id, content: content, isError: isError)
        }
    }
}

// MARK: - 上下文压缩

extension AgentMessage: CompressibleMessage {
    public var isTurnBoundary: Bool { if case .user = self { return true }; return false }

    public var payloadByteCount: Int {
        switch self {
        case .system(let text), .user(let text):
            return text.utf8.count
        case .assistant(let content, let toolCalls):
            return (content?.utf8.count ?? 0)
                + toolCalls.reduce(0) { $0 + $1.name.utf8.count + $1.arguments.utf8.count }
        case .toolResult(_, let content, _):
            return content.utf8.count
        }
    }

    public var turnText: String? { if case .user(let text) = self { return text }; return nil }

    public var toolCallNames: [String] { toolCalls.map(\.name) }

    public func folded(policy: AgentContextCompressor.Policy) -> AgentMessage {
        switch self {
        case .system:
            return self
        case .user(let text):
            guard text.count > policy.foldedTextCap else { return self }
            return .user(String(text.prefix(policy.foldedTextCap)) + "…（已截断）")
        case .assistant(let content, let toolCalls):
            guard let content, content.count > policy.foldedTextCap else { return self }
            return .assistant(content: String(content.prefix(policy.foldedTextCap)) + "…（已截断）",
                              toolCalls: toolCalls)
        case .toolResult(let id, let content, let isError):
            guard content.count > policy.foldedToolResultCap else { return self }
            let head = String(content.prefix(policy.foldedToolResultCap))
            return .toolResult(
                toolCallID: id,
                content: head + "…（结果已折叠，原 \(content.count) 字符；需要时请重新调用工具）",
                isError: isError)
        }
    }

    /// 被丢弃轮次的确定性摘要：按工具名分别列出次数。
    public static func digestMessage(count: Int, firstTurnText: String?, toolCallCounts: [String: Int]) -> AgentMessage {
        var parts: [String] = ["（上下文压缩：已省略更早的 \(count) 条消息"]
        if let first = firstTurnText {
            let head = first.count > 80 ? String(first.prefix(80)) + "…" : first
            parts.append("，最早的请求是「\(head)」")
        }
        if !toolCallCounts.isEmpty {
            let tools = toolCallCounts.sorted { $0.key < $1.key }
                .map { "\($0.key)×\($0.value)" }
                .joined(separator: "、")
            parts.append("；期间调用过工具：\(tools)")
        }
        parts.append("。需要这些细节时请重新调用工具获取。）")
        return .user(parts.joined())
    }
}
