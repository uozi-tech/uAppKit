import AgentKit
import AgentProviders
import Foundation

/// `tool_choice`。
public enum AgentToolChoice: Sendable, Hashable {
    case auto
    case required
    case none
    case named(String)

    var wire: LLMToolChoice {
        switch self {
        case .auto: return .auto
        case .required: return .required
        case .none: return .none
        case .named(let name): return .named(name)
        }
    }
}

/// 一次模型请求。
public struct AgentChatRequest: Sendable {
    public var model: String
    public var messages: [AgentMessage]
    public var tools: [AgentToolSchema]
    public var toolChoice: AgentToolChoice
    /// 模型不收采样参数（开着思考、或是推理模型）时请求层会自动不带。
    public var temperature: Double?
    /// nil = 不指定：Anthropic 用 `AnthropicProvider.defaultMaxTokens`，OpenAI 兼容端点不带上限。
    public var maxTokens: Int?
    /// 思考深度（已按模型折算）；nil = 不带任何思考参数。
    public var reasoning: AgentReasoningRequest?
    /// 本轮工具循环里各条 assistant 消息的 thinking 块，按该消息第一个 tool call 的 id 索引 ——
    /// Anthropic 开着思考时续轮必须把它们原样放回 `tool_use` 之前。
    public var thinkingReplay: [String: [LLMThinkingBlock]]

    public init(model: String, messages: [AgentMessage], tools: [AgentToolSchema] = [],
                toolChoice: AgentToolChoice = .auto, temperature: Double? = nil, maxTokens: Int? = nil,
                reasoning: AgentReasoningRequest? = nil, thinkingReplay: [String: [LLMThinkingBlock]] = [:]) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.reasoning = reasoning
        self.thinkingReplay = thinkingReplay
    }

    public var wireRequest: LLMWireRequest {
        LLMWireRequest(
            model: model,
            messages: messages.map { $0.wireMessage(thinkingReplay: thinkingReplay) },
            tools: tools.map(\.wire),
            toolChoice: toolChoice.wire,
            temperature: temperature,
            maxTokens: maxTokens,
            reasoning: reasoning)
    }
}

/// 一次完整的回复。
public struct AgentChatResponse: Sendable {
    /// 总是 `.assistant`。
    public let message: AgentMessage
    /// 带工具调用时一律是 `.toolCalls`。流式收集得到的回复只会是 `.toolCalls` / `.stop`
    /// （撞上限是一次失败，不会走到这里）。
    public let finishReason: LLMFinishReason
    /// Anthropic 回复里的 thinking 块（不展示，只为续轮回传）。
    public let thinking: [LLMThinkingBlock]
    /// 只有非流式回复带用量。
    public let usage: LLMUsage?

    public init(message: AgentMessage, finishReason: LLMFinishReason, thinking: [LLMThinkingBlock] = [],
                usage: LLMUsage? = nil) {
        self.message = message
        self.finishReason = finishReason
        self.thinking = thinking
        self.usage = usage
    }

    public var toolCalls: [AgentToolCall] { message.toolCalls }
}

/// 模型服务。运行时只依赖这个协议：测试用脚本化的假实现，生产用 `AnthropicProvider` /
/// `OpenAICompatibleProvider`（`AgentLLMProviders.make(endpoint:apiKey:)`）。
///
/// 不叫 `LLMProvider`：那是 `AgentProviders` 里共享的 `@Model` 实体名（CloudKit 只认类名，
/// 不能改），两个模块同时导入时同名会互相遮蔽。
public protocol AgentLLMProvider: Sendable {
    /// 流式回复。事件是聚合好的：`.toolCall` 只在参数收齐后出现一次。结束时的错误折成
    /// `LLMServiceError`（或 `CancellationError`）。
    func stream(_ request: AgentChatRequest) -> AsyncThrowingStream<LLMEvent, Error>
    /// 非流式回复。只在流没能建起来（一个事件都没收到）时作回退；不支持就抛
    /// `LLMServiceError.unimplemented`（缺省实现）。
    func chat(_ request: AgentChatRequest) async throws -> AgentChatResponse
}

extension AgentLLMProvider {
    public func chat(_ request: AgentChatRequest) async throws -> AgentChatResponse {
        throw LLMServiceError.unimplemented
    }
}

/// 回复说到一半失败了：带着失败之前已经收到的部分。
///
/// 流在产出文字或工具调用**之后**才失败时抛出（连接中途断开、撞输出上限、流内报错…）。
/// `abandonedToolCalls` 是已经收齐、但因为回复不完整而不该执行的工具调用数。
public struct AgentPartialReplyFailure: Error, Sendable, CustomStringConvertible, LocalizedError {
    public let text: String?
    public let abandonedToolCalls: Int
    public let underlying: Error

    public init(text: String?, abandonedToolCalls: Int, underlying: Error) {
        self.text = text
        self.abandonedToolCalls = abandonedToolCalls
        self.underlying = underlying
    }

    public var description: String {
        (underlying as? LocalizedError)?.errorDescription ?? "\(underlying)"
    }

    public var errorDescription: String? { description }
}

/// 把流式回复收成一条完整回复（原 uTable `StreamCollectingProvider` 的语义）。
///
/// - 只在**建流**失败（一个事件都没收到）且不是「流已开始的结论」时回退到非流式 `chat`；
///   provider 不支持非流式（`.unimplemented`）时抛原错误。
/// - 流在产出内容**之后**失败：抛 `AgentPartialReplyFailure`，不重发 —— 非流式重发一遍可能让
///   模型重复发起、宿主重复执行已经跑过的工具。
/// - `onText` 在调用方的隔离域里逐段回调文字增量（面板实时显示用）。
public enum AgentReplyCollector {
    public static func collect(
        _ provider: any AgentLLMProvider,
        _ request: AgentChatRequest,
        isolation: isolated (any Actor)? = #isolation,
        onText: ((String) -> Void)? = nil
    ) async throws -> AgentChatResponse {
        var text: String?
        var toolCalls: [LLMToolCall] = []
        var thinking: [LLMThinkingBlock] = []
        do {
            for try await event in provider.stream(request) {
                switch event {
                case .text(let delta):
                    text = (text ?? "") + delta
                    onText?(delta)
                case .toolCall(let call):
                    toolCalls.append(call)
                case .thinking(let block):
                    thinking.append(block)
                }
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let mapped = LLMServiceError.map(error)
            guard text == nil, toolCalls.isEmpty else {
                throw AgentPartialReplyFailure(text: text, abandonedToolCalls: toolCalls.count, underlying: mapped)
            }
            if let verdict = mapped as? LLMServiceError, verdict.isStreamVerdict { throw verdict }
            do {
                return try await provider.chat(request)
            } catch LLMServiceError.unimplemented {
                throw mapped
            }
        }
        let calls = toolCalls.map { AgentToolCall(id: $0.id, name: $0.name, arguments: $0.argumentsJSON) }
        return AgentChatResponse(
            message: .assistant(content: text, toolCalls: calls),
            finishReason: calls.isEmpty ? .stop : .toolCalls,
            thinking: thinking)
    }
}

// MARK: - 生产实现

/// 构造生产用的 provider。
public enum AgentLLMProviders {
    /// 流连续这么久没有进展就放弃等待（thinking / 工具参数增量也算进展，只发心跳不算）。
    /// 中转网关把连接挂着不吐内容时，系统层的超时未必触发。
    public static let defaultStreamIdleTimeout: Duration = .seconds(60)

    public static func make(endpoint: ProviderEndpoint, apiKey: String,
                            urlSession: URLSession = .shared) -> any AgentLLMProvider {
        switch endpoint.kind {
        case .anthropic:
            return AnthropicProvider(baseURL: endpoint.baseURL, apiKey: apiKey, urlSession: urlSession)
        case .openai:
            return OpenAICompatibleProvider(baseURL: endpoint.baseURL, apiKey: apiKey, urlSession: urlSession)
        }
    }
}

/// Anthropic Messages API（`{baseURL}/v1/messages`；baseURL 是根地址）。
public struct AnthropicProvider: AgentLLMProvider {
    /// 请求没指定输出上限时用这个数 —— 这个协议每次请求都必须带 `max_tokens`。开着思考深度时
    /// 请求层会在它之上再抬高。
    public static let defaultMaxTokens = 8192

    private let client: WireClient

    public init(baseURL: String, apiKey: String, urlSession: URLSession = .shared,
                streamIdleTimeout: Duration = AgentLLMProviders.defaultStreamIdleTimeout) {
        client = WireClient(endpoint: ProviderEndpoint(kind: .anthropic, baseURL: baseURL), apiKey: apiKey,
                            urlSession: urlSession, streamIdleTimeout: streamIdleTimeout,
                            defaultMaxTokens: Self.defaultMaxTokens)
    }

    public func stream(_ request: AgentChatRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        client.stream(request)
    }

    public func chat(_ request: AgentChatRequest) async throws -> AgentChatResponse {
        try await client.chat(request)
    }
}

/// OpenAI 兼容 `/chat/completions`（baseURL 带版本前缀）。Key 为空时不带鉴权头（本地服务）。
/// 请求没指定输出上限时不带，由服务端按模型自己的上限来。
public struct OpenAICompatibleProvider: AgentLLMProvider {
    private let client: WireClient

    public init(baseURL: String, apiKey: String, urlSession: URLSession = .shared,
                streamIdleTimeout: Duration = AgentLLMProviders.defaultStreamIdleTimeout) {
        client = WireClient(endpoint: ProviderEndpoint(kind: .openai, baseURL: baseURL), apiKey: apiKey,
                            urlSession: urlSession, streamIdleTimeout: streamIdleTimeout, defaultMaxTokens: nil)
    }

    public func stream(_ request: AgentChatRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        client.stream(request)
    }

    public func chat(_ request: AgentChatRequest) async throws -> AgentChatResponse {
        try await client.chat(request)
    }
}

/// 两家共用的一层：转成请求层的形状 → 交给 `LLMWireTransport` → 把结果和错误转回来。
struct WireClient: Sendable {
    /// 地址不合法时不在构造时抛，留到第一次请求再报。
    private let endpoint: Result<LLMWireEndpoint, LLMServiceError>
    private let urlSession: URLSession
    private let streamIdleTimeout: Duration
    private let defaultMaxTokens: Int?

    init(endpoint: ProviderEndpoint, apiKey: String, urlSession: URLSession,
         streamIdleTimeout: Duration, defaultMaxTokens: Int?) {
        do {
            self.endpoint = .success(LLMWireEndpoint(url: try endpoint.chatURL(), apiKey: apiKey,
                                                     wireProtocol: endpoint.kind.wireProtocol))
        } catch {
            self.endpoint = .failure(LLMServiceError.map(error) as? LLMServiceError
                                     ?? .invalidResponse(String(describing: error)))
        }
        self.urlSession = urlSession
        self.streamIdleTimeout = streamIdleTimeout
        self.defaultMaxTokens = defaultMaxTokens
    }

    private func wireRequest(_ request: AgentChatRequest) -> LLMWireRequest {
        var wire = request.wireRequest
        if wire.maxTokens == nil { wire.maxTokens = defaultMaxTokens }
        return wire
    }

    func chat(_ request: AgentChatRequest) async throws -> AgentChatResponse {
        let endpoint = try endpoint.get()
        let wire: LLMWireResponse
        do {
            wire = try await LLMWireTransport.send(wireRequest(request), endpoint: endpoint, session: urlSession)
        } catch {
            throw LLMServiceError.map(error)
        }
        let calls = wire.toolCalls.map { AgentToolCall(id: $0.id, name: $0.name, arguments: $0.argumentsJSON) }
        return AgentChatResponse(message: .assistant(content: wire.text, toolCalls: calls),
                                 finishReason: wire.finishReason, thinking: wire.thinking, usage: wire.usage)
    }

    func stream(_ request: AgentChatRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let events: AsyncThrowingStream<LLMEvent, Error>
        switch endpoint {
        case .failure(let error):
            return AsyncThrowingStream { $0.finish(throwing: error) }
        case .success(let endpoint):
            events = LLMWireTransport.stream(wireRequest(request), endpoint: endpoint, session: urlSession,
                                             idleTimeout: streamIdleTimeout)
        }
        // 事件原样转发，只把结束时的错误折成 `LLMServiceError`。
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LLMServiceError.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
