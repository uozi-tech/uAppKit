import Foundation

/// OpenAI Chat Completions（及兼容端点：DeepSeek / Groq / Ollama / OpenRouter…）的请求序列化、
/// 非流式响应解码与 SSE 解析。
public enum OpenAIWire {
    /// 带思考深度或是推理模型时 `max_completion_tokens` 的下限：推理 token 也算在里面。
    public static let reasoningMinimumCompletionTokens = 16_000

    // MARK: - 请求

    public static func urlRequest(_ request: LLMWireRequest, endpoint: LLMWireEndpoint,
                                  stream: Bool) throws -> URLRequest {
        var urlRequest = URLRequest(url: endpoint.url)
        urlRequest.httpMethod = "POST"
        let key = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // 本机的免 Key 服务（Ollama 等）不带这个头。
        if !key.isEmpty { urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody(request, stream: stream))
        return urlRequest
    }

    public static func requestBody(_ request: LLMWireRequest, stream: Bool) -> [String: Any] {
        var root: [String: Any] = [
            "model": request.model,
            "stream": stream,
            "messages": encodeMessages(request.messages),
        ]
        let isReasoningModel = !AgentReasoningSupport.acceptsSamplingParameters(
            protocol: .openAICompatible, modelID: request.model)
        if request.reasoning != nil || isReasoningModel {
            // 推理模型（o 系列 / gpt-5）只收默认 temperature，且不认 max_tokens、要
            // max_completion_tokens。没选思考深度（默认档）也一样，只是不带 reasoning_effort。
            root.merge(request.reasoning?.openAIBody ?? [:]) { _, new in new }
            if let maxTokens = request.maxTokens {
                root["max_completion_tokens"] = max(maxTokens, reasoningMinimumCompletionTokens)
            }
        } else {
            if let temperature = request.temperature { root["temperature"] = temperature }
            if let maxTokens = request.maxTokens { root["max_tokens"] = maxTokens }
        }
        if !request.tools.isEmpty {
            root["tools"] = request.tools.map { schema -> [String: Any] in
                ["type": "function",
                 "function": ["name": schema.name, "description": schema.description,
                              "parameters": schema.parametersObject] as [String: Any]]
            }
            if let choice = request.toolChoice { root["tool_choice"] = encodeToolChoice(choice) }
        }
        return root
    }

    /// 一条消息编成一个元素，顺序不变。assistant 的 `text` 为 nil 时 `content` 是 `null`，
    /// 空串就是空串；thinking 块不属于这个协议，不发。
    public static func encodeMessages(_ messages: [LLMWireMessage]) -> [[String: Any]] {
        messages.map { message in
            switch message {
            case .system(let text):
                return ["role": "system", "content": text]
            case .user(let text):
                return ["role": "user", "content": text]
            case .assistant(let text, let toolCalls, _):
                var dict: [String: Any] = ["role": "assistant", "content": text ?? NSNull()]
                if !toolCalls.isEmpty {
                    dict["tool_calls"] = toolCalls.map { call -> [String: Any] in
                        ["id": call.id, "type": "function",
                         "function": ["name": call.name, "arguments": call.argumentsJSON]]
                    }
                }
                return dict
            case .toolResult(let id, let content, _):
                return ["role": "tool", "tool_call_id": id, "content": content]
            }
        }
    }

    static func encodeToolChoice(_ choice: LLMToolChoice) -> Any {
        switch choice {
        case .auto: return "auto"
        case .required: return "required"
        case .none: return "none"
        case .named(let name): return ["type": "function", "function": ["name": name]]
        }
    }

    // MARK: - 非流式响应

    /// 取第一个 choice。
    public static func decodeResponse(_ data: Data, fallbackModel: String) throws -> LLMWireResponse {
        let raw: ChatCompletionResponse
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            raw = try decoder.decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw LLMWireError.invalidResponse("Failed to decode response: \(error)")
        }
        guard let choice = raw.choices.first else {
            throw LLMWireError.invalidResponse("Response has no choices")
        }
        let toolCalls = (choice.message.toolCalls ?? []).map {
            LLMToolCall(id: $0.id, name: $0.function.name, argumentsJSON: $0.function.arguments ?? "")
        }
        // 有的兼容端点（Ollama / llama.cpp）带着 tool_calls 却报 finish_reason "stop" /
        // "function_call"：有调用就算 toolCalls，调用方才会去执行。
        let finishReason: LLMFinishReason = !toolCalls.isEmpty
            ? .toolCalls
            : choice.finishReason.flatMap(LLMFinishReason.init(rawValue:)) ?? .unknown
        return LLMWireResponse(
            id: raw.id ?? "",
            model: raw.model ?? fallbackModel,
            text: choice.message.content,
            toolCalls: toolCalls,
            finishReason: finishReason,
            usage: raw.usage.map {
                LLMUsage(promptTokens: $0.promptTokens, completionTokens: $0.completionTokens,
                         totalTokens: $0.totalTokens)
            })
    }

    private struct ChatCompletionResponse: Decodable {
        let id: String?
        let model: String?
        let choices: [Choice]
        let usage: Usage?

        struct Choice: Decodable {
            let message: Message
            let finishReason: String?
        }
        struct Message: Decodable {
            let content: String?
            let toolCalls: [ToolCallWire]?
        }
        struct Usage: Decodable {
            let promptTokens: Int
            let completionTokens: Int
            let totalTokens: Int
        }
        struct ToolCallWire: Decodable {
            let id: String
            let function: FunctionWire
        }
        struct FunctionWire: Decodable {
            let name: String
            let arguments: String?
        }
    }
}

/// 解析 OpenAI Chat Completions（及兼容端点）SSE。逐行喂入，产出 `[LLMEvent]`。
/// 文本增量逐条 `.text`；工具调用按 `tool_calls[].index` 累积 id/name/arguments，
/// 在 `finish_reason == "tool_calls"` 或 `[DONE]` 时一次性 flush 成 `.toolCall`。
///
/// 兜底：有的兼容端点以 `finish_reason == "stop"`/`"length"` 收尾且不发 `[DONE]`，
/// 累积的工具调用就永远不会被 flush。调用方在字节流 EOF 后须再调一次 `flush()`，
/// 借 `flushed` 标记保证幂等——已经 flush 过（经 `[DONE]` 或 `tool_calls`）则不再重复产出。
public struct OpenAISSEParser: Sendable {
    private struct Accum { var id = ""; var name = ""; var args = "" }
    private var calls: [Int: Accum] = [:]
    private var order: [Int] = []
    private var flushed = false

    /// 最后一次非空的 `finish_reason`（`stop` / `tool_calls` / `length` …）。
    public private(set) var finishReason: String?
    /// 收到过 `[DONE]`。
    public private(set) var sawDone = false
    /// 流内 `{"error":…}` 帧的可读文案。
    public private(set) var streamError: String?
    /// 解析出过至少一帧 `choices`（流确实开始了）。
    public private(set) var sawEvent = false
    /// 收到过多少帧 `choices`。只带推理内容或工具参数片段的帧不产出 `LLMEvent`，
    /// 静默超时靠这个数判断流还活着；注释行的 keep-alive 不算。
    public private(set) var contentFrameCount = 0

    /// 流开始了却没有正常收尾：`[DONE]` 与 `finish_reason` 任一即算收尾（有的兼容端点不发
    /// 前者）。一帧都没有的空响应不算（那条路由上层报「模型未返回任何内容」）。
    public var endedEarly: Bool { sawEvent && !sawDone && finishReason == nil }

    public init() {}

    public mutating func parse(line: String) -> [LLMEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { sawDone = true; return flush() }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        if let error = obj["error"] {
            let message = (error as? [String: Any])?["message"] as? String ?? error as? String
            streamError = message.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "未知错误", bundle: .module)
            return []
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first
        else { return [] }
        sawEvent = true
        contentFrameCount += 1
        if let reason = first["finish_reason"] as? String { finishReason = reason }

        var out: [LLMEvent] = []
        if let delta = first["delta"] as? [String: Any] {
            if let content = delta["content"] as? String, !content.isEmpty {
                out.append(.text(content))
            }
            if let tcs = delta["tool_calls"] as? [[String: Any]] {
                for tc in tcs {
                    let idx = tc["index"] as? Int ?? 0
                    if calls[idx] == nil { calls[idx] = Accum(); order.append(idx) }
                    if let id = tc["id"] as? String { calls[idx]?.id = id }
                    if let fn = tc["function"] as? [String: Any] {
                        if let name = fn["name"] as? String { calls[idx]?.name = name }
                        if let args = fn["arguments"] as? String { calls[idx]?.args += args }
                    }
                }
            }
        }
        if first["finish_reason"] as? String == "tool_calls" {
            out.append(contentsOf: flush())
        }
        return out
    }

    /// 产出累积的工具调用并清空缓冲。幂等：已 flush 过直接返回空，故调用方在 EOF 后无脑再调
    /// 一次也不会重复发已发出的调用。
    public mutating func flush() -> [LLMEvent] {
        guard !flushed else { return [] }
        flushed = true
        let events = order.compactMap { idx -> LLMEvent? in
            guard let a = calls[idx] else { return nil }
            return .toolCall(LLMToolCall(id: a.id, name: a.name, argumentsJSON: a.args))
        }
        calls.removeAll(); order.removeAll()
        return events
    }
}
