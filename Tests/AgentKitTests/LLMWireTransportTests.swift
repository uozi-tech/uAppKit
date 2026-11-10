import XCTest
@testable import AgentKit

final class LLMWireTransportTests: XCTestCase {
    private let anthropic = LLMWireEndpoint(url: URL(string: "https://api.anthropic.com/v1/messages")!,
                                            apiKey: " sk-ant ", wireProtocol: .anthropic)
    private let openAI = LLMWireEndpoint(url: URL(string: "https://api.openai.com/v1/chat/completions")!,
                                         apiKey: "sk-oai", wireProtocol: .openAICompatible)
    private let request = LLMWireRequest(model: "m", messages: [.system("S"), .user("hi")])

    override func tearDown() {
        WireStubURLProtocol.reset()
        super.tearDown()
    }

    private func collect(_ endpoint: LLMWireEndpoint) async -> (events: [LLMEvent], error: Error?) {
        var events: [LLMEvent] = []
        do {
            for try await event in LLMWireTransport.stream(request, endpoint: endpoint,
                                                           session: WireStubURLProtocol.makeSession()) {
                events.append(event)
            }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    // MARK: - 请求

    func testAnthropicRequestHeadersAndBody() async {
        WireStubURLProtocol.install(body: #"data: {"type":"message_stop"}"# + "\n")
        _ = await collect(anthropic)
        let sent = WireStubURLProtocol.capturedRequest
        XCTAssertEqual(sent?.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(sent?.httpMethod, "POST")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "x-api-key"), "sk-ant", "Key 去首尾空白")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "anthropic-version"), AnthropicWire.version)
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        let body = WireStubURLProtocol.capturedJSON
        XCTAssertEqual(body?["system"] as? String, "S")
        XCTAssertEqual(body?["stream"] as? Bool, true)
    }

    func testOpenAIRequestHeadersAndKeylessEndpoint() async {
        WireStubURLProtocol.install(body: "data: [DONE]\n")
        _ = await collect(openAI)
        XCTAssertEqual(WireStubURLProtocol.capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-oai")
        XCTAssertEqual((WireStubURLProtocol.capturedJSON?["messages"] as? [[String: Any]])?.first?["role"] as? String, "system")

        let local = LLMWireEndpoint(url: URL(string: "http://localhost:11434/v1/chat/completions")!,
                                    apiKey: "  ", wireProtocol: .openAICompatible)
        WireStubURLProtocol.install(body: "data: [DONE]\n")
        _ = await collect(local)
        XCTAssertNil(WireStubURLProtocol.capturedRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - 流式

    func testAnthropicStreamYieldsAggregatedEvents() async {
        WireStubURLProtocol.install(body: """
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}

        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"c1","name":"run_command"}}

        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"command\\":"}}

        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"ls\\"}"}}

        data: {"type":"content_block_stop","index":1}

        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}

        data: {"type":"message_stop"}

        """)
        let (events, error) = await collect(anthropic)
        XCTAssertNil(error)
        XCTAssertEqual(events, [.text("Hi"),
                                .toolCall(LLMToolCall(id: "c1", name: "run_command", argumentsJSON: #"{"command":"ls"}"#))])
    }

    func testAnthropicStreamEndings() async {
        // 没等到收尾标记：连接被掐。
        WireStubURLProtocol.install(body: #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}"# + "\n")
        var result = await collect(anthropic)
        XCTAssertEqual(result.events, [.text("Hi")], "已产出的文字不收回")
        XCTAssertEqual(result.error as? LLMWireError, .incompleteStream)

        // 撞输出上限。
        WireStubURLProtocol.install(body: """
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}
        data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}
        data: {"type":"message_stop"}

        """)
        result = await collect(anthropic)
        XCTAssertEqual(result.error as? LLMWireError, .outputLimitReached)

        // 流内报错。
        WireStubURLProtocol.install(body: #"data: {"type":"error","error":{"type":"overloaded_error","message":"busy"}}"# + "\n")
        result = await collect(anthropic)
        XCTAssertEqual(result.error as? LLMWireError, .streamError("overloaded_error：busy"))

        // 只有 stop_reason、没有 message_stop（个别中转不转发后者）也算正常收尾。
        WireStubURLProtocol.install(body: #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"# + "\n")
        result = await collect(anthropic)
        XCTAssertNil(result.error)
    }

    func testOpenAIStreamFlushesToolCallAtEOFAndReportsEndings() async {
        // finish_reason "stop" 收尾、不发 [DONE]：累积的调用在 EOF 冲出来，且只出一次。
        WireStubURLProtocol.install(body: """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"run_command","arguments":"{}"}}]}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        """)
        var result = await collect(openAI)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events, [.toolCall(LLMToolCall(id: "c1", name: "run_command", argumentsJSON: "{}"))])

        WireStubURLProtocol.install(body: #"data: {"choices":[{"delta":{"content":"Hi"}}]}"# + "\n")
        result = await collect(openAI)
        XCTAssertEqual(result.events, [.text("Hi")])
        XCTAssertEqual(result.error as? LLMWireError, .incompleteStream)

        WireStubURLProtocol.install(body: #"data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":"length"}]}"# + "\n")
        result = await collect(openAI)
        XCTAssertEqual(result.error as? LLMWireError, .outputLimitReached)

        WireStubURLProtocol.install(body: #"data: {"error":{"message":"upstream timeout"}}"# + "\n")
        result = await collect(openAI)
        XCTAssertEqual(result.error as? LLMWireError, .streamError("upstream timeout"))
    }

    func testHTTPErrorCarriesStatusBodyAndRetryAfter() async {
        WireStubURLProtocol.install(status: 429, headers: ["Retry-After": "7"], body: #"{"error":"slow down"}"#)
        let result = await collect(openAI)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.error as? LLMWireError,
                       .http(status: 429, body: #"{"error":"slow down"}"#, retryAfter: 7))
    }

    // MARK: - 非流式

    func testSendDecodesPerProtocolAndMapsHTTPErrors() async throws {
        WireStubURLProtocol.install(body: #"{"id":"m1","model":"claude-x","stop_reason":"end_turn","content":[{"type":"text","text":"hi"}]}"#)
        let session = WireStubURLProtocol.makeSession()
        let reply = try await LLMWireTransport.send(request, endpoint: anthropic, session: session)
        XCTAssertEqual(reply.text, "hi")
        XCTAssertEqual(reply.finishReason, .stop)
        XCTAssertEqual(WireStubURLProtocol.capturedJSON?["stream"] as? Bool, false)
        XCTAssertEqual(WireStubURLProtocol.capturedRequest?.value(forHTTPHeaderField: "Accept"), "application/json")

        WireStubURLProtocol.install(status: 401, body: "nope")
        do {
            _ = try await LLMWireTransport.send(request, endpoint: openAI, session: session)
            XCTFail("401 应当抛错")
        } catch {
            XCTAssertEqual(error as? LLMWireError, .http(status: 401, body: "nope", retryAfter: nil))
        }
    }

    // MARK: - 模型列表

    func testFetchModelIDs() async throws {
        WireStubURLProtocol.install(body: #"{"data":[{"id":" a "},{"id":"b"},{"id":"a"},{"id":""}]}"#)
        let session = WireStubURLProtocol.makeSession()
        let url = URL(string: "https://api.anthropic.com/v1/models?limit=1000")!
        let ids = try await LLMWireTransport.fetchModelIDs(url: url, apiKey: "k", wireProtocol: .anthropic, session: session)
        XCTAssertEqual(ids, ["a", "b"])
        let sent = WireStubURLProtocol.capturedRequest
        XCTAssertEqual(sent?.httpMethod, "GET")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "anthropic-version"), AnthropicWire.version)

        let openAIRequest = LLMWireTransport.modelListRequest(
            url: URL(string: "https://api.openai.com/v1/models")!, apiKey: "k", wireProtocol: .openAICompatible)
        XCTAssertEqual(openAIRequest.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        XCTAssertThrowsError(try LLMWireTransport.decodeModelIDs(Data("[]".utf8)))

        WireStubURLProtocol.install(status: 404, body: "not found")
        do {
            _ = try await LLMWireTransport.fetchModelIDs(url: url, apiKey: "k", wireProtocol: .anthropic, session: session)
            XCTFail("404 应当抛错")
        } catch {
            XCTAssertEqual(error as? LLMWireError, .http(status: 404, body: "not found", retryAfter: nil))
        }
    }

    // MARK: - 传输层的静默超时

    private func collect(_ endpoint: LLMWireEndpoint, idleTimeout: Duration) async -> (events: [LLMEvent], error: Error?) {
        var events: [LLMEvent] = []
        do {
            for try await event in LLMWireTransport.stream(request, endpoint: endpoint,
                                                           session: WireStubURLProtocol.makeSession(),
                                                           idleTimeout: idleTimeout) {
                events.append(event)
            }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    private func pings(_ count: Int, every interval: Duration) -> [(after: Duration, text: String)] {
        (0..<count).map { _ in (interval, "event: ping\ndata: {\"type\":\"ping\"}\n\n") }
    }

    /// 出了一段文字之后连接挂着不动：超时，已产出的文字保留。
    func testTransportIdleTimeoutEndsAStalledStream() async {
        WireStubURLProtocol.install(chunks: [
            (.zero, #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"# + "\n\n"),
        ], finish: false)
        let result = await collect(anthropic, idleTimeout: .milliseconds(150))
        XCTAssertEqual(result.events, [.text("Hi")])
        XCTAssertEqual(result.error as? LLMWireError, .streamIdleTimeout)
    }

    /// 只发心跳、不出内容：照样判超时，不会被心跳吊着永远不返回。
    func testKeepAliveAloneDoesNotCountAsProgress() async {
        WireStubURLProtocol.install(chunks: pings(20, every: .milliseconds(40)), finish: false)
        let result = await collect(anthropic, idleTimeout: .milliseconds(200))
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.error as? LLMWireError, .streamIdleTimeout)
    }

    /// thinking 块开着时服务端只发心跳（新模型不回传思考文本）：这不是卡住，不能超时。
    /// 这段沉默（约 0.6 秒）是超时时长的三倍。
    func testPingsWhileThinkingKeepTheStreamAlive() async {
        var chunks: [(after: Duration, text: String)] = [
            (.zero, #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"# + "\n\n"),
        ]
        chunks += pings(15, every: .milliseconds(40))
        chunks.append((.zero, [
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"done"}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            #"data: {"type":"message_stop"}"#,
        ].joined(separator: "\n\n") + "\n\n"))
        WireStubURLProtocol.install(chunks: chunks)
        let result = await collect(anthropic, idleTimeout: .milliseconds(200))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events, [.thinking(LLMThinkingBlock(thinking: "", signature: "sig")), .text("done")])
    }

    /// 工具参数一片一片到、一个事件都没有：算进展，不超时。
    func testToolArgumentFragmentsCountAsProgress() async {
        var chunks: [(after: Duration, text: String)] = [
            (.zero, #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"c1","name":"run_command"}}"# + "\n\n"),
        ]
        chunks += (0..<12).map { _ in
            (Duration.milliseconds(40), #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":" "}}"# + "\n\n")
        }
        chunks.append((.zero, [
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
        ].joined(separator: "\n\n") + "\n\n"))
        WireStubURLProtocol.install(chunks: chunks)
        let result = await collect(anthropic, idleTimeout: .milliseconds(200))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events.count, 1)
    }

    // MARK: - 按事件计时的静默超时

    func testIdleTimeoutEndsASilentStream() async {
        let silent = AsyncThrowingStream<LLMEvent, Error> { continuation in
            continuation.yield(.text("a"))
            // 之后不再出声，也不结束。
        }
        var events: [LLMEvent] = []
        do {
            for try await event in withIdleTimeout(silent, timeout: .milliseconds(40)) { events.append(event) }
            XCTFail("静默的流应当超时")
        } catch {
            XCTAssertEqual(error as? LLMWireError, .streamIdleTimeout)
        }
        XCTAssertEqual(events, [.text("a")])
    }

    func testIdleTimeoutPassesThroughAHealthyStreamAndCustomError() async throws {
        struct Custom: Error, Equatable {}
        let healthy = AsyncThrowingStream<LLMEvent, Error> { continuation in
            continuation.yield(.text("a")); continuation.yield(.text("b")); continuation.finish()
        }
        var events: [LLMEvent] = []
        for try await event in withIdleTimeout(healthy, timeout: .seconds(5)) { events.append(event) }
        XCTAssertEqual(events, [.text("a"), .text("b")])

        let silent = AsyncThrowingStream<LLMEvent, Error> { _ in }
        do {
            for try await _ in withIdleTimeout(silent, timeout: .milliseconds(30), timeoutError: Custom()) {}
            XCTFail("应当超时")
        } catch {
            XCTAssertTrue(error is Custom)
        }
    }
}
