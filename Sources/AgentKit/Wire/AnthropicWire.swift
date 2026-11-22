import Foundation

/// Anthropic Messages API（`/v1/messages`）的请求序列化、非流式响应解码与 SSE 解析。
public enum AnthropicWire {
    public static let version = "2023-06-01"
    /// Anthropic 每次请求都必须带 `max_tokens`；请求没指定时用这个。
    public static let defaultMaxTokens = 4096

    // MARK: - 请求

    public static func urlRequest(_ request: LLMWireRequest, endpoint: LLMWireEndpoint,
                                  stream: Bool) throws -> URLRequest {
        var urlRequest = URLRequest(url: endpoint.url)
        urlRequest.httpMethod = "POST"
        let key = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { urlRequest.setValue(key, forHTTPHeaderField: "x-api-key") }
        urlRequest.setValue(version, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody(request, stream: stream))
        return urlRequest
    }

    public static func requestBody(_ request: LLMWireRequest, stream: Bool) -> [String: Any] {
        var root: [String: Any] = ["model": request.model, "stream": stream]
        let baseMaxTokens = request.maxTokens ?? defaultMaxTokens
        let reasoning = request.reasoning?.anthropicBody(baseMaxTokens: baseMaxTokens)
        root["max_tokens"] = reasoning?.maxTokens ?? baseMaxTokens
        // 开着 thinking 时 temperature 只能是默认值；Opus 4.7 起等新型号干脆不收采样参数。
        if let temperature = request.temperature,
           request.reasoning?.forbidsSamplingParameters != true,
           AgentReasoningSupport.acceptsSamplingParameters(protocol: .anthropic, modelID: request.model) {
            root["temperature"] = temperature
        }
        root.merge(reasoning?.fields ?? [:]) { _, new in new }

        let system = systemPrompt(request.messages)
        if !system.isEmpty { root["system"] = system }
        root["messages"] = encodeMessages(request.messages,
                                          replayThinking: request.reasoning?.replaysThinking == true)

        if !request.tools.isEmpty {
            root["tools"] = request.tools.map { schema -> [String: Any] in
                ["name": schema.name, "description": schema.description,
                 "input_schema": schema.parametersObject]
            }
            if let choice = request.toolChoice { root["tool_choice"] = encodeToolChoice(choice) }
        }
        return root
    }

    /// 全部 `.system` 消息拼成顶层 `system` 字段。
    public static func systemPrompt(_ messages: [LLMWireMessage]) -> String {
        messages.compactMap { message -> String? in
            if case .system(let text) = message { return text }
            return nil
        }.joined(separator: "\n\n")
    }

    /// 编成 `messages[]`：`.system` 不在这里（提到顶层）；相邻的同角色消息并成一条、内容块
    /// 依次排开——工具结果是 `user` 角色的 `tool_result` 块，紧跟其后的用户文字并进同一条
    /// （`tool_result` 在前、`text` 在后），不会出现连续两条 `user`。没有任何内容块的消息
    /// （空的 assistant 回复）跳过：Anthropic 不收空 `content`。
    ///
    /// - Parameter replayThinking: 为真时把 assistant 消息带着的 thinking 块原样放回最前
    ///   （`tool_use` 之前）。开着思考时工具循环里的续轮请求必须这样，否则 API 拒收。
    public static func encodeMessages(_ messages: [LLMWireMessage], replayThinking: Bool) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for message in messages {
            let role: String
            var blocks: [[String: Any]] = []
            switch message {
            case .system:
                continue
            case .user(let text):
                role = "user"
                blocks = [["type": "text", "text": text]]
            case .assistant(let text, let toolCalls, let thinking):
                role = "assistant"
                if replayThinking { blocks = thinking.map(\.anthropicJSON) }
                if let text, !text.isEmpty { blocks.append(["type": "text", "text": text]) }
                for call in toolCalls {
                    blocks.append(["type": "tool_use", "id": call.id, "name": call.name,
                                   "input": argumentsObject(call.argumentsJSON)])
                }
            case .toolResult(let id, let content, let isError):
                role = "user"
                blocks = [["type": "tool_result", "tool_use_id": id,
                           "content": content, "is_error": isError]]
            }
            if blocks.isEmpty { continue }

            if let last = out.last, last["role"] as? String == role,
               var existing = last["content"] as? [[String: Any]] {
                existing.append(contentsOf: blocks)
                out[out.count - 1]["content"] = existing
            } else {
                out.append(["role": role, "content": blocks])
            }
        }
        return out
    }

    static func encodeToolChoice(_ choice: LLMToolChoice) -> [String: Any] {
        switch choice {
        case .auto: return ["type": "auto"]
        case .required: return ["type": "any"]
        case .none: return ["type": "none"]
        case .named(let name): return ["type": "tool", "name": name]
        }
    }

    /// 工具调用的参数：我们内部存 JSON 字符串（OpenAI 的形状），Anthropic 的 `input` 要对象。
    /// 空串或解析不了时给空对象。
    public static func argumentsObject(_ argumentsJSON: String) -> [String: Any] {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    // MARK: - 非流式响应

    public static func decodeResponse(_ data: Data, fallbackModel: String) throws -> LLMWireResponse {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LLMWireError.invalidResponse("Failed to decode Anthropic response")
        }
        var text = ""
        var toolCalls: [LLMToolCall] = []
        var thinking: [LLMThinkingBlock] = []
        for block in object["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "thinking":
                thinking.append(LLMThinkingBlock(thinking: block["thinking"] as? String ?? "",
                                                 signature: block["signature"] as? String ?? ""))
            case "redacted_thinking":
                thinking.append(LLMThinkingBlock(redactedData: block["data"] as? String ?? ""))
            case "text":
                text += block["text"] as? String ?? ""
            case "tool_use":
                let input = block["input"] ?? [String: Any]()
                let argumentsData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
                toolCalls.append(LLMToolCall(id: block["id"] as? String ?? "",
                                             name: block["name"] as? String ?? "",
                                             argumentsJSON: String(decoding: argumentsData, as: UTF8.self)))
            default:
                break
            }
        }
        var usage: LLMUsage?
        if let raw = object["usage"] as? [String: Any] {
            let input = raw["input_tokens"] as? Int ?? 0
            let output = raw["output_tokens"] as? Int ?? 0
            usage = LLMUsage(promptTokens: input, completionTokens: output, totalTokens: input + output)
        }
        return LLMWireResponse(
            id: object["id"] as? String ?? "",
            model: object["model"] as? String ?? fallbackModel,
            text: text.isEmpty ? nil : text,
            toolCalls: toolCalls,
            thinking: thinking,
            finishReason: toolCalls.isEmpty ? finishReason(object["stop_reason"] as? String) : .toolCalls,
            usage: usage)
    }

    public static func finishReason(_ stopReason: String?) -> LLMFinishReason {
        switch stopReason {
        case "tool_use": return .toolCalls
        case "max_tokens": return .length
        case "end_turn", "stop_sequence": return .stop
        default: return .unknown
        }
    }
}

/// 解析 Anthropic Messages SSE。逐行喂入，产出 `[LLMEvent]`。
/// 文本块 `text_delta` → `.text`；`tool_use` 块的 `input_json_delta` 按 index 累积，
/// `content_block_stop` 时 flush 成 `.toolCall`。thinking / redacted_thinking 块同样按 index
/// 收齐（`LLMThinkingBlockAccumulator`），收尾时产出 `.thinking` 供续轮原样回传。
///
/// 另记三样「流是怎么结束的」，供调用方在 EOF 时判定回复是否完整 —— 不记的话，
/// 流内报错 / 连接被掐 / 撞输出上限全都长得像「正常说完了」，用户只看到话说一半就停。
public struct AnthropicSSEParser: Sendable {
    private struct Tool { var id = ""; var name = ""; var args = "" }
    private var tools: [Int: Tool] = [:]   // 仅 tool_use 块进表
    private var thinking = LLMThinkingBlockAccumulator()

    /// `message_delta.delta.stop_reason`（`end_turn` / `tool_use` / `max_tokens` …）。
    public private(set) var stopReason: String?
    /// 收到过 `message_stop`。
    public private(set) var sawMessageStop = false
    /// 流内 `error` 事件的可读文案（`类型：消息`）。
    public private(set) var streamError: String?
    /// 解析出过至少一个事件（流确实开始了）。
    public private(set) var sawEvent = false
    /// 收到过多少帧「内容在推进」的数据（块的开头 / 增量 / 收尾、消息的开头 / 收尾）。`ping`
    /// 不算。thinking 与工具参数的增量不产出 `LLMEvent`，静默超时靠这个数判断流还活着。
    public private(set) var contentFrameCount = 0
    /// 有 thinking 块还没收尾。新模型默认不回传思考文本，这期间服务端只发 `ping`，
    /// 一帧内容都没有 —— 不是卡住。
    public var isThinking: Bool { thinking.hasOpenBlock }

    /// 流开始了却没有正常收尾。`stop_reason` 与 `message_stop` 任一即算收尾 —— 个别中转
    /// 不转发后者。一个事件都没有的空响应不算（那条路由上层报「模型未返回任何内容」）。
    public var endedEarly: Bool { sawEvent && !sawMessageStop && stopReason == nil }

    public init() {}

    public mutating func parse(line: String) -> [LLMEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let jsonText = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return [] }
        sawEvent = true
        if type != "ping", type != "error" { contentFrameCount += 1 }
        let index = obj["index"] as? Int ?? 0

        switch type {
        case "content_block_start":
            guard let block = obj["content_block"] as? [String: Any] else { return [] }
            if block["type"] as? String == "tool_use" {
                tools[index] = Tool(id: block["id"] as? String ?? "",
                                    name: block["name"] as? String ?? "", args: "")
            } else {
                thinking.start(index: index, block: block)
            }
            return []
        case "content_block_delta":
            guard let delta = obj["delta"] as? [String: Any] else { return [] }
            if thinking.delta(index: index, delta: delta) { return [] }
            if delta["type"] as? String == "text_delta", let t = delta["text"] as? String {
                return [.text(t)]
            }
            if delta["type"] as? String == "input_json_delta",
               let frag = delta["partial_json"] as? String {
                tools[index]?.args += frag
            }
            return []
        case "content_block_stop":
            if let block = thinking.stop(index: index) { return [.thinking(block)] }
            guard let t = tools.removeValue(forKey: index) else { return [] }
            return [.toolCall(LLMToolCall(id: t.id, name: t.name, argumentsJSON: t.args))]
        case "message_delta":
            if let delta = obj["delta"] as? [String: Any],
               let reason = delta["stop_reason"] as? String {
                stopReason = reason
            }
            return []
        case "message_stop":
            sawMessageStop = true
            return []
        case "error":
            let error = obj["error"] as? [String: Any]
            let parts = [error?["type"] as? String, error?["message"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }
            streamError = parts.isEmpty ? String(localized: "未知错误", bundle: ModuleBundle.bundle) : parts.joined(separator: "：")
            return []
        default:
            return []
        }
    }
}
