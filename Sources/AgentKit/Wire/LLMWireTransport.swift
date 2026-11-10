import Foundation

/// 把一次 `LLMWireRequest` 发出去：流式（SSE → `LLMEvent`）、非流式、以及拉模型列表。
/// 无状态；会话与端点都由调用方传入。
///
/// 抛出的错误：请求层能判定的是 `LLMWireError`；`URLSession` 自己的错误（`URLError`、取消）
/// 原样抛出，由各 app 决定怎么对用户说。
public enum LLMWireTransport {
    /// 出错时最多读这么多响应体。
    static let errorBodyLimit = 4096

    // MARK: - 流式

    /// 流式请求。事件是聚合好的：`.toolCall` 只在参数收齐后出现一次。
    ///
    /// 字节流结束不等于说完了，结束时按解析器记下的收尾方式判定：
    /// 流内报错 → `streamError`；没等到收尾标记 → `incompleteStream`；
    /// 撞输出上限 → `outputLimitReached`（已产出的文字不会收回，错误在其后抛出）。
    ///
    /// - Parameter idleTimeout: 静默超时；nil 不设。从发出请求起算，连续这么久没有**进展**就以
    ///   `streamIdleTimeout` 结束。进展 = 任何内容帧，包括不产出事件的 thinking / 工具参数增量；
    ///   Anthropic 的 thinking 块开着时（新模型不回传思考文本，期间只有 `ping`）任何一行都算。
    ///   其余时候的 keep-alive 不算进展：只发心跳、不出内容的中转会被判超时，而不是永远挂着。
    public static func stream(_ request: LLMWireRequest, endpoint: LLMWireEndpoint,
                              session: URLSession = .shared,
                              idleTimeout: Duration? = nil) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let gate = LLMStreamIdleGate(timeout: idleTimeout, timeoutError: LLMWireError.streamIdleTimeout,
                                         continuation: continuation)
            let task = Task {
                await gate.start()
                do {
                    try await run(request, endpoint: endpoint, session: session, gate: gate,
                                  continuation: continuation)
                    if await gate.complete() { continuation.finish() }
                } catch {
                    if await gate.complete() { continuation.finish(throwing: error) }
                }
            }
            Task { await gate.attach(task) }
            continuation.onTermination = { _ in
                Task { await gate.cancel() }
            }
        }
    }

    private static func run(_ request: LLMWireRequest, endpoint: LLMWireEndpoint, session: URLSession,
                            gate: LLMStreamIdleGate,
                            continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation) async throws {
        let urlRequest = try makeURLRequest(request, endpoint: endpoint, stream: true)
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw LLMWireError.invalidResponse("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            var collected = Data()
            // 读错误体本身失败不该盖过 HTTP 状态这个更有用的信息。
            do {
                for try await byte in bytes {
                    collected.append(byte)
                    if collected.count >= errorBodyLimit { break }
                }
            } catch {}
            throw LLMWireError.http(status: http.statusCode,
                                    body: String(decoding: collected, as: UTF8.self),
                                    retryAfter: retryAfter(http))
        }
        await gate.touch()
        switch endpoint.wireProtocol {
        case .anthropic:
            var parser = AnthropicSSEParser()
            for try await line in bytes.lines {
                let before = parser.contentFrameCount
                for event in parser.parse(line: line) { continuation.yield(event) }
                if parser.contentFrameCount != before || parser.isThinking { await gate.touch() }
                if let message = parser.streamError { throw LLMWireError.streamError(message) }
            }
            if parser.endedEarly { throw LLMWireError.incompleteStream }
            if parser.stopReason == "max_tokens" { throw LLMWireError.outputLimitReached }
        case .openAICompatible:
            var parser = OpenAISSEParser()
            for try await line in bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let before = parser.contentFrameCount
                for event in parser.parse(line: trimmed) { continuation.yield(event) }
                if parser.contentFrameCount != before { await gate.touch() }
                if let message = parser.streamError { throw LLMWireError.streamError(message) }
            }
            // 有的兼容端点以 finish_reason "stop"/"length" 收尾且不发 [DONE]，
            // 累积的工具调用不会在循环内 flush；这里再冲一次（幂等）。
            for event in parser.flush() { continuation.yield(event) }
            if parser.endedEarly { throw LLMWireError.incompleteStream }
            if parser.finishReason == "length" { throw LLMWireError.outputLimitReached }
        }
    }

    // MARK: - 非流式

    public static func send(_ request: LLMWireRequest, endpoint: LLMWireEndpoint,
                            session: URLSession = .shared) async throws -> LLMWireResponse {
        let urlRequest = try makeURLRequest(request, endpoint: endpoint, stream: false)
        let (data, response) = try await session.data(for: urlRequest)
        try checkStatus(response, body: data)
        switch endpoint.wireProtocol {
        case .anthropic: return try AnthropicWire.decodeResponse(data, fallbackModel: request.model)
        case .openAICompatible: return try OpenAIWire.decodeResponse(data, fallbackModel: request.model)
        }
    }

    public static func makeURLRequest(_ request: LLMWireRequest, endpoint: LLMWireEndpoint,
                                      stream: Bool) throws -> URLRequest {
        do {
            switch endpoint.wireProtocol {
            case .anthropic: return try AnthropicWire.urlRequest(request, endpoint: endpoint, stream: stream)
            case .openAICompatible: return try OpenAIWire.urlRequest(request, endpoint: endpoint, stream: stream)
            }
        } catch {
            throw LLMWireError.invalidResponse("Failed to serialize request body: \(error)")
        }
    }

    // MARK: - 模型列表

    /// `GET` 模型列表。`url` 是完整地址（Anthropic 的 `?limit=1000` 由调用方带上）。
    /// 两家的响应都是 `{ "data": [ { "id": … } ] }`。
    public static func fetchModelIDs(url: URL, apiKey: String, wireProtocol: AgentWireProtocol,
                                     session: URLSession = .shared) async throws -> [String] {
        let request = modelListRequest(url: url, apiKey: apiKey, wireProtocol: wireProtocol)
        let (data, response) = try await session.data(for: request)
        try checkStatus(response, body: data)
        return try decodeModelIDs(data)
    }

    public static func modelListRequest(url: URL, apiKey: String,
                                        wireProtocol: AgentWireProtocol) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch wireProtocol {
        case .openAICompatible:
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .anthropic:
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            request.setValue(AnthropicWire.version, forHTTPHeaderField: "anthropic-version")
        }
        return request
    }

    /// 取 `data[].id`：去首尾空白、去空、去重，保持服务端顺序。
    public static func decodeModelIDs(_ data: Data) throws -> [String] {
        struct ModelList: Decodable {
            struct Entry: Decodable { let id: String }
            let data: [Entry]
        }
        let list: ModelList
        do {
            list = try JSONDecoder().decode(ModelList.self, from: data)
        } catch {
            throw LLMWireError.invalidResponse("Failed to decode models: \(error)")
        }
        var seen = Set<String>()
        return list.data.compactMap { entry in
            let id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
            return !id.isEmpty && seen.insert(id).inserted ? id : nil
        }
    }

    // MARK: - 辅助

    static func checkStatus(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMWireError.invalidResponse("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMWireError.http(status: http.statusCode,
                                    body: String(decoding: body.prefix(errorBodyLimit), as: UTF8.self),
                                    retryAfter: retryAfter(http))
        }
    }

    /// `Retry-After`：秒数，或 HTTP 日期。
    static func retryAfter(_ http: HTTPURLResponse) -> TimeInterval? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(raw) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw).map { max(0, $0.timeIntervalSinceNow) }
    }
}
