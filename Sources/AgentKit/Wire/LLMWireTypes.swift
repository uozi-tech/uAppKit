import Foundation

// 模型请求层的公共类型：两个 app 各有自己的会话消息模型（uTerm 的工具结果内嵌在 assistant
// 消息里，uTable 的是独立消息），发请求前都先转成这里的形状；序列化、SSE 解析、传输只认这一种。

/// 发给模型的一条消息。形状贴近两家协议的公约数：工具结果是独立消息，按 `toolCallID`
/// 对上发起它的调用。
public enum LLMWireMessage: Sendable, Equatable {
    case system(String)
    case user(String)
    /// - Parameters:
    ///   - text: nil 与空串在 OpenAI 协议里是两回事（`null` / `""`），所以保留区分；
    ///     Anthropic 协议里两者都不产生文字块。
    ///   - thinking: 这条消息当初带回来的 thinking 块。只有请求开着思考
    ///     （`AgentReasoningRequest.replaysThinking`）时才会被放回去；要不要带由调用方决定
    ///     ——只给本轮工具循环里的消息带，更早轮次的留空。
    case assistant(text: String?, toolCalls: [LLMToolCall], thinking: [LLMThinkingBlock])
    case toolResult(toolCallID: String, content: String, isError: Bool)
}

/// 一个可被模型调用的工具：名字、说明、参数的 JSON Schema（原始 JSON 字符串）。
public struct LLMToolSchema: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parametersJSON: String

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }

    /// 解析后的参数 schema；解析不了时退成「没有参数的对象」，不让一份坏 schema 把请求打挂。
    var parametersObject: Any {
        if let data = parametersJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            return parsed
        }
        return ["type": "object", "properties": [:] as [String: Any]]
    }
}

public enum LLMToolChoice: Sendable, Equatable {
    case auto
    case required
    case none
    case named(String)
}

/// 一次模型请求。可选项为 nil 时请求体里不带对应字段，交给服务端默认。
public struct LLMWireRequest: Sendable {
    public var model: String
    public var messages: [LLMWireMessage]
    public var tools: [LLMToolSchema]
    /// 只在 `tools` 非空时生效。
    public var toolChoice: LLMToolChoice?
    /// 模型不收采样参数（开着思考、或是推理模型）时即使给了也不带。
    public var temperature: Double?
    /// Anthropic 必须有 `max_tokens`：nil 时用 `AnthropicWire.defaultMaxTokens`。
    public var maxTokens: Int?
    /// 思考深度（已按模型折算）。
    public var reasoning: AgentReasoningRequest?

    public init(model: String,
                messages: [LLMWireMessage],
                tools: [LLMToolSchema] = [],
                toolChoice: LLMToolChoice? = nil,
                temperature: Double? = nil,
                maxTokens: Int? = nil,
                reasoning: AgentReasoningRequest? = nil) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.reasoning = reasoning
    }
}

/// 请求发到哪里。`url` 是**完整端点**（含 `/v1/messages`、`/chat/completions` 这一段）：
/// 两个 app 对 Base URL 的约定不同（带不带 `/v1`），拼路径留在各自那边。
public struct LLMWireEndpoint: Sendable, Equatable {
    public let url: URL
    public let apiKey: String
    public let wireProtocol: AgentWireProtocol

    public init(url: URL, apiKey: String, wireProtocol: AgentWireProtocol) {
        self.url = url
        self.apiKey = apiKey
        self.wireProtocol = wireProtocol
    }
}

public enum LLMFinishReason: String, Sendable, Equatable {
    case stop
    case length
    case toolCalls = "tool_calls"
    case contentFilter = "content_filter"
    case unknown
}

public struct LLMUsage: Sendable, Equatable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int

    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

/// 非流式请求的完整回复。
public struct LLMWireResponse: Sendable, Equatable {
    public let id: String
    public let model: String
    /// 没有任何文字时为 nil。
    public let text: String?
    public let toolCalls: [LLMToolCall]
    public let thinking: [LLMThinkingBlock]
    /// 带工具调用时一律是 `.toolCalls`：有的兼容端点带着调用却报 `stop`。
    public let finishReason: LLMFinishReason
    public let usage: LLMUsage?

    public init(id: String, model: String, text: String?, toolCalls: [LLMToolCall],
                thinking: [LLMThinkingBlock] = [], finishReason: LLMFinishReason, usage: LLMUsage? = nil) {
        self.id = id
        self.model = model
        self.text = text
        self.toolCalls = toolCalls
        self.thinking = thinking
        self.finishReason = finishReason
        self.usage = usage
    }
}

/// 请求层自己能判定的失败。网络层的错误（`URLError` 等）不包装，原样抛给调用方。
public enum LLMWireError: Error, Equatable, Sendable {
    /// 非 2xx。`body` 最多取前 4096 字节；`retryAfter` 来自 `Retry-After` 头。
    case http(status: Int, body: String, retryAfter: TimeInterval?)
    /// 响应不是能解析的形状。
    case invalidResponse(String)
    /// 连续一段时间没有任何事件（见 `withIdleTimeout`）。
    case streamIdleTimeout
    /// 服务端在 SSE 流**内部**报错（HTTP 已经是 200）：Anthropic 的 `error` 事件、
    /// OpenAI 兼容端点的 `{"error":…}` 帧。中转网关上游过载 / 超时最常走这条。
    case streamError(String)
    /// 字节流结束了，却没等到任何收尾标记 —— 连接被中途掐断，回复不完整。
    case incompleteStream
    /// 模型撞上单次输出上限（`max_tokens` / `length`），回复在半句话处被截断。
    case outputLimitReached
}
