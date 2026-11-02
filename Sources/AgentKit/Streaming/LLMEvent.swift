import Foundation

/// A single event in an LLM's streamed output.
///
/// This is the *canonical, aggregated* event shape: a `.toolCall` only ever
/// appears once a provider's incremental tool-call fragments (however the
/// wire format splits them — Anthropic's `content_block_start` /
/// `input_json_delta` / `content_block_stop`, OpenAI's indexed
/// `delta.tool_calls[]` fragments) have been fully accumulated into one
/// complete call. Consumers never see partial arguments.
///
/// Frozen shape, ported byte-for-byte from uTerm's original
/// `Features/Agent/Backend/LLMEvent.swift` (uTerm's own file now aliases this
/// type instead of redeclaring it — see AgentKit HANDOFF phase 2 notes).
/// Deliberately minimal: no usage/finish-reason case. Neither app's SSE
/// accumulator needs one to drive its control flow (uTerm's `AssistantModel`
/// infers "done" from stream completion; uTable's collecting adapter infers
/// `.toolCalls` vs `.stop` from whether any `.toolCall` event arrived), so
/// extending this shape for that purpose was left out of scope for this
/// phase rather than speculatively adding a case neither consumer needs.
public enum LLMEvent: Sendable, Equatable {
    /// A text delta.
    case text(String)
    /// One fully-aggregated tool call request (arguments already assembled).
    case toolCall(LLMToolCall)
    /// 一个完整的 Anthropic thinking / redacted_thinking 块（签名已收齐）。
    /// 不给人看：只为在同一轮工具循环里原样回传 —— 开着 thinking 时，带 `tool_use`
    /// 的 assistant 消息若丢了它前面的 thinking 块，API 会拒绝续轮请求。
    /// OpenAI 兼容端点永远不产出此事件。
    case thinking(LLMThinkingBlock)
}

/// A single tool call requested by the model, with arguments already
/// aggregated into one JSON string (never a partial fragment).
public struct LLMToolCall: Sendable, Equatable {
    /// The provider's tool_use id / tool_call id.
    public let id: String
    /// e.g. "run_command".
    public let name: String
    /// Raw JSON parameters string.
    public let argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}
