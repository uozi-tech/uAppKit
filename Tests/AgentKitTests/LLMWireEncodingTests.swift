import XCTest
@testable import AgentKit

final class LLMWireEncodingTests: XCTestCase {
    private let call = LLMToolCall(id: "c1", name: "run_command", argumentsJSON: #"{"command":"ls"}"#)
    private let thinking = LLMThinkingBlock(thinking: "", signature: "sig-1")
    private let schema = LLMToolSchema(
        name: "run_command", description: "run",
        parametersJSON: #"{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}"#)

    private func types(_ message: [String: Any]) -> [String?] {
        (message["content"] as? [[String: Any]] ?? []).map { $0["type"] as? String }
    }

    // MARK: - Anthropic 消息

    func testAnthropicHoistsSystemAndEncodesToolLoop() {
        let messages: [LLMWireMessage] = [
            .system("S1"), .user("hi"),
            .assistant(text: "run it", toolCalls: [call], thinking: []),
            .toolResult(toolCallID: "c1", content: "a", isError: false),
            .system("S2"),
        ]
        XCTAssertEqual(AnthropicWire.systemPrompt(messages), "S1\n\nS2")
        let out = AnthropicWire.encodeMessages(messages, replayThinking: false)
        XCTAssertEqual(out.map { $0["role"] as? String }, ["user", "assistant", "user"])
        XCTAssertEqual(types(out[0]), ["text"])
        XCTAssertEqual(types(out[1]), ["text", "tool_use"])
        let toolUse = (out[1]["content"] as? [[String: Any]])?[1]
        XCTAssertEqual(toolUse?["id"] as? String, "c1")
        XCTAssertEqual((toolUse?["input"] as? [String: Any])?["command"] as? String, "ls")
        let result = (out[2]["content"] as? [[String: Any]])?.first
        XCTAssertEqual(result?["tool_use_id"] as? String, "c1")
        XCTAssertEqual(result?["content"] as? String, "a")
        XCTAssertEqual(result?["is_error"] as? Bool, false)
    }

    /// 工具结果后面的用户文字并进同一条 user 消息：tool_result 在前、text 在后。
    func testAnthropicMergesConsecutiveSameRoleMessages() {
        let out = AnthropicWire.encodeMessages([
            .user("hi"),
            .assistant(text: nil, toolCalls: [call], thinking: []),
            .toolResult(toolCallID: "c1", content: "a", isError: true),
            .user("只看隐藏文件"), .user("再补一句"),
        ], replayThinking: false)
        XCTAssertEqual(out.map { $0["role"] as? String }, ["user", "assistant", "user"])
        XCTAssertEqual(types(out[2]), ["tool_result", "text", "text"])
        XCTAssertEqual((out[2]["content"] as? [[String: Any]])?.first?["is_error"] as? Bool, true)
    }

    /// 空的 assistant 回复不产生内容块，整条跳过（Anthropic 不收空 content）；两边的 user 随之并成一条。
    func testAnthropicSkipsEmptyAssistantMessage() {
        let out = AnthropicWire.encodeMessages([
            .user("a"), .assistant(text: "", toolCalls: [], thinking: []), .user("b"),
        ], replayThinking: false)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(types(out[0]), ["text", "text"])
    }

    func testAnthropicReplaysThinkingOnlyWhenAsked() {
        let messages: [LLMWireMessage] = [
            .user("hi"), .assistant(text: nil, toolCalls: [call], thinking: [thinking]),
        ]
        let replayed = AnthropicWire.encodeMessages(messages, replayThinking: true)
        XCTAssertEqual(types(replayed[1]), ["thinking", "tool_use"])
        XCTAssertEqual((replayed[1]["content"] as? [[String: Any]])?.first?["signature"] as? String, "sig-1")
        XCTAssertEqual(types(AnthropicWire.encodeMessages(messages, replayThinking: false)[1]), ["tool_use"])
    }

    func testAnthropicInvalidArgumentsBecomeEmptyObject() {
        XCTAssertTrue(AnthropicWire.argumentsObject("").isEmpty)
        XCTAssertTrue(AnthropicWire.argumentsObject("not json").isEmpty)
        XCTAssertTrue(AnthropicWire.argumentsObject("[1]").isEmpty)
    }

    // MARK: - Anthropic 请求体

    func testAnthropicBodyDefaultsAndOptionalFields() {
        var request = LLMWireRequest(model: "claude-sonnet-4-5", messages: [.system("S"), .user("hi")])
        var body = AnthropicWire.requestBody(request, stream: true)
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-4-5")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["system"] as? String, "S")
        XCTAssertEqual(body["max_tokens"] as? Int, AnthropicWire.defaultMaxTokens)
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["tool_choice"])

        request.maxTokens = 8192
        request.temperature = 0.2
        request.tools = [schema]
        body = AnthropicWire.requestBody(request, stream: false)
        XCTAssertEqual(body["max_tokens"] as? Int, 8192)
        XCTAssertEqual(body["temperature"] as? Double, 0.2)
        XCTAssertEqual(body["stream"] as? Bool, false)
        let tool = (body["tools"] as? [[String: Any]])?.first
        XCTAssertEqual(tool?["name"] as? String, "run_command")
        XCTAssertEqual((tool?["input_schema"] as? [String: Any])?["type"] as? String, "object")
        XCTAssertNil(body["tool_choice"], "没指定 toolChoice 时不带")

        request.toolChoice = .required
        XCTAssertEqual((AnthropicWire.requestBody(request, stream: false)["tool_choice"] as? [String: Any])?["type"] as? String, "any")
    }

    func testAnthropicBodyOmitsSystemWhenEmptyAndTemperatureWhenForbidden() {
        // 不收采样参数的型号：给了 temperature 也不带。
        let request = LLMWireRequest(model: "claude-opus-4-7", messages: [.user("hi")], temperature: 0.2)
        let body = AnthropicWire.requestBody(request, stream: true)
        XCTAssertNil(body["system"])
        XCTAssertNil(body["temperature"])
    }

    func testAnthropicBodyCarriesReasoningAndReplaysThinking() throws {
        let reasoning = try XCTUnwrap(AgentReasoningRequest.make(
            protocol: .anthropic, modelID: "claude-opus-4-7", effort: .high))
        let request = LLMWireRequest(
            model: "claude-opus-4-7",
            messages: [.user("hi"), .assistant(text: nil, toolCalls: [call], thinking: [thinking]),
                       .toolResult(toolCallID: "c1", content: "a", isError: false)],
            maxTokens: 8192, reasoning: reasoning)
        let body = AnthropicWire.requestBody(request, stream: true)
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        XCTAssertEqual(body["max_tokens"] as? Int, AgentReasoningRequest.adaptiveMinimumMaxTokens)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(types(messages[1]), ["thinking", "tool_use"])
    }

    func testBrokenToolSchemaFallsBackToEmptyObjectSchema() {
        let broken = LLMToolSchema(name: "t", description: "d", parametersJSON: "{")
        let request = LLMWireRequest(model: "m", messages: [.user("hi")], tools: [broken])
        let tool = (AnthropicWire.requestBody(request, stream: true)["tools"] as? [[String: Any]])?.first
        XCTAssertEqual((tool?["input_schema"] as? [String: Any])?["type"] as? String, "object")
    }

    // MARK: - OpenAI

    func testOpenAIMessagesKeepOrderAndNullVersusEmptyContent() {
        let out = OpenAIWire.encodeMessages([
            .system("S"), .user("hi"),
            .assistant(text: nil, toolCalls: [call], thinking: [thinking]),
            .toolResult(toolCallID: "c1", content: "a", isError: true),
            .assistant(text: "", toolCalls: [], thinking: []),
            .user("next"),
        ])
        XCTAssertEqual(out.map { $0["role"] as? String },
                       ["system", "user", "assistant", "tool", "assistant", "user"])
        XCTAssertTrue(out[2]["content"] is NSNull)
        let toolCall = (out[2]["tool_calls"] as? [[String: Any]])?.first
        XCTAssertEqual(toolCall?["id"] as? String, "c1")
        XCTAssertEqual((toolCall?["function"] as? [String: Any])?["arguments"] as? String, #"{"command":"ls"}"#)
        XCTAssertEqual(out[3]["tool_call_id"] as? String, "c1")
        XCTAssertNil(out[3]["is_error"])
        XCTAssertEqual(out[4]["content"] as? String, "")
        XCTAssertNil(out[4]["tool_calls"])
    }

    func testOpenAIBodyForPlainModel() {
        var request = LLMWireRequest(model: "deepseek-chat", messages: [.user("hi")])
        var body = OpenAIWire.requestBody(request, stream: true)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["max_tokens"])
        XCTAssertNil(body["tools"])

        request.temperature = 0.2
        request.maxTokens = 4096
        request.tools = [schema]
        request.toolChoice = .auto
        body = OpenAIWire.requestBody(request, stream: false)
        XCTAssertEqual(body["temperature"] as? Double, 0.2)
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
        XCTAssertEqual(body["tool_choice"] as? String, "auto")
        let function = ((body["tools"] as? [[String: Any]])?.first?["function"]) as? [String: Any]
        XCTAssertEqual(function?["name"] as? String, "run_command")
        XCTAssertEqual((function?["parameters"] as? [String: Any])?["type"] as? String, "object")
    }

    /// 推理模型：不带 temperature，max_tokens 换成 max_completion_tokens 并抬到下限。
    func testOpenAIBodyForReasoningModel() throws {
        var request = LLMWireRequest(model: "gpt-5", messages: [.user("hi")], temperature: 0.2, maxTokens: 4096)
        var body = OpenAIWire.requestBody(request, stream: true)
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["max_tokens"])
        XCTAssertEqual(body["max_completion_tokens"] as? Int, OpenAIWire.reasoningMinimumCompletionTokens)
        XCTAssertNil(body["reasoning_effort"], "默认档不带 reasoning_effort")

        request.reasoning = try XCTUnwrap(AgentReasoningRequest.make(
            protocol: .openAICompatible, modelID: "gpt-5", effort: .high))
        body = OpenAIWire.requestBody(request, stream: true)
        XCTAssertEqual(body["reasoning_effort"] as? String, "high")
    }

    // MARK: - 非流式响应

    func testAnthropicResponseDecoding() throws {
        let json = """
        {"id":"msg_1","model":"claude-x","stop_reason":"tool_use","usage":{"input_tokens":3,"output_tokens":4},
         "content":[{"type":"thinking","thinking":"t","signature":"s"},{"type":"text","text":"hi"},
                    {"type":"tool_use","id":"c1","name":"run_command","input":{"command":"ls"}}]}
        """
        let response = try AnthropicWire.decodeResponse(Data(json.utf8), fallbackModel: "fallback")
        XCTAssertEqual(response.id, "msg_1")
        XCTAssertEqual(response.model, "claude-x")
        XCTAssertEqual(response.text, "hi")
        XCTAssertEqual(response.toolCalls.first?.id, "c1")
        XCTAssertEqual(AnthropicWire.argumentsObject(response.toolCalls[0].argumentsJSON)["command"] as? String, "ls")
        XCTAssertEqual(response.thinking, [LLMThinkingBlock(thinking: "t", signature: "s")])
        XCTAssertEqual(response.finishReason, .toolCalls)
        XCTAssertEqual(response.usage, LLMUsage(promptTokens: 3, completionTokens: 4, totalTokens: 7))

        let truncated = try AnthropicWire.decodeResponse(
            Data(#"{"stop_reason":"max_tokens","content":[]}"#.utf8), fallbackModel: "fallback")
        XCTAssertEqual(truncated.model, "fallback")
        XCTAssertNil(truncated.text)
        XCTAssertEqual(truncated.finishReason, .length)
        XCTAssertThrowsError(try AnthropicWire.decodeResponse(Data("nope".utf8), fallbackModel: "m"))
    }

    func testOpenAIResponseDecoding() throws {
        let json = """
        {"id":"x","model":"gpt","usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3},
         "choices":[{"index":0,"finish_reason":"stop","message":{"content":null,
           "tool_calls":[{"id":"c1","type":"function","function":{"name":"run_command","arguments":"{}"}}]}}]}
        """
        let response = try OpenAIWire.decodeResponse(Data(json.utf8), fallbackModel: "fallback")
        XCTAssertNil(response.text)
        XCTAssertEqual(response.toolCalls, [LLMToolCall(id: "c1", name: "run_command", argumentsJSON: "{}")])
        XCTAssertEqual(response.finishReason, .toolCalls, "带着调用却报 stop 的端点也按 toolCalls 算")
        XCTAssertEqual(response.usage?.totalTokens, 3)

        let plain = try OpenAIWire.decodeResponse(
            Data(#"{"choices":[{"finish_reason":"length","message":{"content":"hi"}}]}"#.utf8), fallbackModel: "fallback")
        XCTAssertEqual(plain.text, "hi")
        XCTAssertEqual(plain.model, "fallback")
        XCTAssertEqual(plain.finishReason, .length)
        XCTAssertThrowsError(try OpenAIWire.decodeResponse(Data(#"{"choices":[]}"#.utf8), fallbackModel: "m"))
    }
}
