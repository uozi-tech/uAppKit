import AgentRuntime
import Foundation

/// 一条工具调用在面板上的样子：调用本身 + 对上的结果 + 状态。
public struct AgentToolCallItem: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// 模型发起了，还没轮到 / 正在审批。
        case pending
        /// 正在 `tool.run` 里。
        case running
        case succeeded
        case failed
    }

    public let call: AgentToolCall
    /// 对上 `toolCallID` 的结果；还没有为 nil。
    public let result: String?
    public let status: Status

    public var id: String { call.id }
}

/// 面板的一行。工具结果并进发起它的那条 assistant 行（uTerm 的展示形状），不单独成行；
/// 找不到发起方的结果（历史被截断等）单独显示。
public struct AgentTranscriptItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `text` 已换成展示别名（`/` 命令显示用户敲的原文）。
        case user(text: String)
        case assistant(text: String?, toolCalls: [AgentToolCallItem])
        case orphanToolResult(toolCallID: String, content: String, isError: Bool)
    }

    /// 取自 `AgentRuntimeSession.messageIDs`：独立于数组位置的展示身份。
    public let id: UUID
    /// 在 `messages` 里的下标。
    public let index: Int
    public let kind: Kind
}

/// 会话消息 → 面板行。纯函数，可单测。
public enum AgentTranscriptItems {
    public static func make(
        messages: [AgentMessage],
        messageIDs: [UUID],
        displayOverrides: [Int: String] = [:],
        runningToolCallID: String? = nil
    ) -> [AgentTranscriptItem] {
        var results: [String: (content: String, isError: Bool)] = [:]
        var calledIDs: Set<String> = []
        for message in messages {
            switch message {
            case .toolResult(let id, let content, let isError): results[id] = (content, isError)
            case .assistant(_, let calls): calledIDs.formUnion(calls.map(\.id))
            default: break
            }
        }

        var items: [AgentTranscriptItem] = []
        let count = min(messages.count, messageIDs.count)
        items.reserveCapacity(count)
        for index in 0..<count {
            let id = messageIDs[index]
            switch messages[index] {
            case .system:
                continue
            case .user(let text):
                items.append(AgentTranscriptItem(id: id, index: index, kind: .user(text: displayOverrides[index] ?? text)))
            case .assistant(let content, let calls):
                let text = content?.isEmpty == false ? content : nil
                guard text != nil || !calls.isEmpty else { continue }
                let callItems = calls.map { call -> AgentToolCallItem in
                    if let result = results[call.id] {
                        return AgentToolCallItem(call: call, result: result.content,
                                                 status: result.isError ? .failed : .succeeded)
                    }
                    return AgentToolCallItem(call: call, result: nil,
                                             status: call.id == runningToolCallID ? .running : .pending)
                }
                items.append(AgentTranscriptItem(id: id, index: index, kind: .assistant(text: text, toolCalls: callItems)))
            case .toolResult(let callID, let content, let isError):
                guard !calledIDs.contains(callID) else { continue }
                items.append(AgentTranscriptItem(id: id, index: index,
                                                 kind: .orphanToolResult(toolCallID: callID, content: content,
                                                                         isError: isError)))
            }
        }
        return items
    }
}

extension AgentRuntimeSession {
    /// 当前会话的面板行。按 `transcriptRevision` 缓存：只有消息、展示身份、展示别名或正在跑的
    /// 工具变了才重新折叠；流式文字、状态行这些高频变化直接命中缓存。
    public var transcriptItems: [AgentTranscriptItem] {
        // 命中缓存也要读一遍这几个被观察的属性：调用方视图靠这次读取订阅它们的变化。
        let messages = messages
        let messageIDs = messageIDs
        let overrides = userDisplayOverrides
        let running = runningToolCallID
        if let cache = transcriptCache, cache.revision == transcriptRevision,
           let items = cache.value as? [AgentTranscriptItem] {
            return items
        }
        let items = AgentTranscriptItems.make(messages: messages, messageIDs: messageIDs,
                                              displayOverrides: overrides, runningToolCallID: running)
        transcriptCache = (transcriptRevision, items)
        return items
    }

    /// 状态行文案；空闲 / 正在吐字时为 nil（吐字由流式气泡自己表现）。
    public var statusLine: AgentStatusLine? {
        switch state {
        case .idle, .streaming: return nil
        case .sending: return .busy(String(localized: "思考中…", bundle: ModuleBundle.bundle))
        case .reviewingTool(let name): return .busy(String(localized: "审查 \(name)…", bundle: ModuleBundle.bundle, comment: "AI 正在审查某个工具调用；参数是工具名"))
        case .waitingForApproval(let name): return .busy(String(localized: "等待确认 \(name)", bundle: ModuleBundle.bundle, comment: "等用户确认某个工具调用；参数是工具名"))
        case .runningTool(let name): return .busy(String(localized: "运行工具 \(name)…", bundle: ModuleBundle.bundle, comment: "参数是工具名"))
        case .error(let message): return .error(message)
        }
    }
}

/// 状态行。
public enum AgentStatusLine: Equatable, Sendable {
    case busy(String)
    case error(String)
}
