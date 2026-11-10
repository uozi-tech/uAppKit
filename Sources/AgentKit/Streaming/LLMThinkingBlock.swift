import Foundation

/// Anthropic 回复里的一个 `thinking` / `redacted_thinking` 内容块。
///
/// 开着 thinking（extended / adaptive）时，Anthropic 要求工具循环里的续轮请求把上一条
/// assistant 消息的 thinking 块**原样**放回 `tool_use` 之前；字段一个字都不能改（签名
/// 覆盖了内容）。所以这里只做搬运：解析时收齐，回传时按原形状编码，不做任何加工。
///
/// 只在内存里活一轮：两个 app 都不落库。跨轮不回传等于「从历史前端整体移除」，
/// 这是 API 允许的形状；从中间删才会破坏签名链。
public struct LLMThinkingBlock: Sendable, Equatable, Codable {
    /// `thinking` 文本（新模型默认 `display: omitted`，常为空串 —— 空串也必须保留）。
    public var thinking: String
    public var signature: String
    /// 非 nil 表示这是 `redacted_thinking` 块，内容只有这段加密数据。
    public var redactedData: String?

    public init(thinking: String, signature: String) {
        self.thinking = thinking
        self.signature = signature
        self.redactedData = nil
    }

    public init(redactedData: String) {
        self.thinking = ""
        self.signature = ""
        self.redactedData = redactedData
    }

    /// 回传给 Messages API 的内容块。
    public var anthropicJSON: [String: Any] {
        if let redactedData {
            return ["type": "redacted_thinking", "data": redactedData]
        }
        return ["type": "thinking", "thinking": thinking, "signature": signature]
    }
}

/// 把 Anthropic SSE 里 thinking 块的碎片（`content_block_start` / `thinking_delta` /
/// `signature_delta` / `content_block_stop`）按 `index` 拼成完整的 `LLMThinkingBlock`。
/// uTerm 与 uTable 各有一份 SSE 解析器，这一段两边共用，免得两份各写一遍。
public struct LLMThinkingBlockAccumulator: Sendable {
    private var open: [Int: LLMThinkingBlock] = [:]

    public init() {}

    /// 有 thinking 块开了头还没收尾：模型正在想。
    public var hasOpenBlock: Bool { !open.isEmpty }

    /// `content_block_start`：是 thinking 类块就开始记，返回 true。
    @discardableResult
    public mutating func start(index: Int, block: [String: Any]) -> Bool {
        switch block["type"] as? String {
        case "thinking":
            open[index] = LLMThinkingBlock(thinking: block["thinking"] as? String ?? "",
                                           signature: block["signature"] as? String ?? "")
            return true
        case "redacted_thinking":
            open[index] = LLMThinkingBlock(redactedData: block["data"] as? String ?? "")
            return true
        default:
            return false
        }
    }

    /// `content_block_delta`：认得的 delta 就并进去，返回 true。
    @discardableResult
    public mutating func delta(index: Int, delta: [String: Any]) -> Bool {
        guard open[index] != nil else { return false }
        switch delta["type"] as? String {
        case "thinking_delta":
            open[index]?.thinking += delta["thinking"] as? String ?? ""
            return true
        case "signature_delta":
            open[index]?.signature += delta["signature"] as? String ?? ""
            return true
        default:
            return false
        }
    }

    /// `content_block_stop`：收尾并交出这个块；不是 thinking 块返回 nil。
    public mutating func stop(index: Int) -> LLMThinkingBlock? {
        open.removeValue(forKey: index)
    }
}
