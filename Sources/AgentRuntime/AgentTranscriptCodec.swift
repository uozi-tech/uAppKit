import AgentKit
import Foundation

/// `ChatMessageRecord` 的字段（值类型）。codec 只跟它打交道，不碰 `@Model`：
/// uTerm 和 uTable 往同一个实体里存的形状不同（uTable 存独立的 tool 行，uTerm 把工具结果
/// 内嵌在 assistant 行里），运行时一律经 codec 访问持久化，`@Model` 本身一个字段都不改。
public struct AgentTranscriptRow: Sendable, Equatable {
    public var roleRaw: String
    public var text: String
    public var toolCallsJSON: String
    public var toolCallID: String
    public var isError: Bool
    public var displayText: String

    public init(roleRaw: String, text: String, toolCallsJSON: String = "", toolCallID: String = "",
                isError: Bool = false, displayText: String = "") {
        self.roleRaw = roleRaw
        self.text = text
        self.toolCallsJSON = toolCallsJSON
        self.toolCallID = toolCallID
        self.isError = isError
        self.displayText = displayText
    }

    public init(_ record: ChatMessageRecord) {
        self.init(roleRaw: record.roleRaw, text: record.text, toolCallsJSON: record.toolCallsJSON,
                  toolCallID: record.toolCallID, isError: record.isError, displayText: record.displayText)
    }

    /// 写回一条记录（不动 id / 时间 / 顺序 / 所属会话）。
    public func apply(to record: ChatMessageRecord) {
        record.roleRaw = roleRaw
        record.text = text
        record.toolCallsJSON = toolCallsJSON
        record.toolCallID = toolCallID
        record.isError = isError
        record.displayText = displayText
    }
}

/// 一条运行时消息写穿时对记录的改动。
public enum AgentTranscriptWrite: Sendable, Equatable {
    /// 不落库（system 提示词每轮重建）。
    case skip
    case append(AgentTranscriptRow)
    /// 改写最后一行（工具结果内嵌在 assistant 行里的形状用）。
    case replaceLast(AgentTranscriptRow)
}

/// 从记录恢复出来的会话。
public struct AgentRestoredTranscript: Sendable, Equatable {
    public var messages: [AgentMessage]
    /// user 消息的展示别名（按 `messages` 下标）。
    public var displayOverrides: [Int: String]

    public init(messages: [AgentMessage] = [], displayOverrides: [Int: String] = [:]) {
        self.messages = messages
        self.displayOverrides = displayOverrides
    }
}

/// 运行时消息 ⇄ 持久化记录。
public protocol AgentTranscriptCodec: Sendable {
    /// - Parameter lastRow: 会话当前的最后一行（没有为 nil）。
    func encode(_ message: AgentMessage, display: String?, lastRow: AgentTranscriptRow?) -> AgentTranscriptWrite
    /// 行按 `orderIndex` 排好序传入。认不出的行跳过。
    func decode(_ rows: [AgentTranscriptRow]) -> AgentRestoredTranscript
}

/// 缺省 codec：uTable 的形状 —— user / assistant / tool 各一行，assistant 行的
/// `toolCallsJSON` 是 `[{id, name, arguments}]`。与 uTable 已写下的记录逐字段兼容。
public struct ToolRowsTranscriptCodec: AgentTranscriptCodec {
    public init() {}

    public func encode(_ message: AgentMessage, display: String?, lastRow: AgentTranscriptRow?) -> AgentTranscriptWrite {
        switch message {
        case .system:
            return .skip
        case .user(let text):
            return .append(AgentTranscriptRow(roleRaw: "user", text: text, displayText: display ?? ""))
        case .assistant(let content, let toolCalls):
            return .append(AgentTranscriptRow(roleRaw: "assistant", text: content ?? "",
                                              toolCallsJSON: Self.encodeToolCalls(toolCalls)))
        case .toolResult(let toolCallID, let content, let isError):
            return .append(AgentTranscriptRow(roleRaw: "tool", text: content, toolCallID: toolCallID,
                                              isError: isError))
        }
    }

    public func decode(_ rows: [AgentTranscriptRow]) -> AgentRestoredTranscript {
        var restored = AgentRestoredTranscript()
        for row in rows {
            let message: AgentMessage
            switch row.roleRaw {
            case "user":
                message = .user(row.text)
                if !row.displayText.isEmpty { restored.displayOverrides[restored.messages.count] = row.displayText }
            case "assistant":
                message = .assistant(content: row.text.isEmpty ? nil : row.text,
                                     toolCalls: Self.decodeToolCalls(row.toolCallsJSON))
            case "tool":
                message = .toolResult(toolCallID: row.toolCallID, content: row.text, isError: row.isError)
            default:
                continue
            }
            restored.messages.append(message)
        }
        return restored
    }

    static func encodeToolCalls(_ calls: [AgentToolCall]) -> String {
        guard !calls.isEmpty, let data = try? JSONEncoder().encode(calls) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeToolCalls(_ json: String) -> [AgentToolCall] {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([AgentToolCall].self, from: data)) ?? []
    }
}
