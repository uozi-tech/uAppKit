import Foundation

/// 测试用 URLProtocol：把请求回放成预设的 (响应, 响应体)。只挂在 `makeStubbedSession()` 造的
/// 会话上，不碰 `URLSession.shared`。
final class WireStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) private static var lastRequest: URLRequest?
    nonisolated(unsafe) private static var lastBody: Data?
    nonisolated(unsafe) private static var script: (chunks: [(after: Duration, text: String)], finish: Bool)?
    private var playback: Task<Void, Never>?

    static func install(status: Int = 200, headers: [String: String] = [:], body: String) {
        install { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!,
             Data(body.utf8))
        }
    }

    static func install(responder: @escaping (URLRequest) -> (HTTPURLResponse, Data)) {
        lock.lock(); defer { lock.unlock() }
        self.responder = responder
        script = nil
        lastRequest = nil
        lastBody = nil
    }

    /// 按时间表分块回放：每块先等 `after` 再送出。`finish` 为 false 时送完不结束连接
    /// （模拟挂着不动的流）。
    static func install(chunks: [(after: Duration, text: String)], finish: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        responder = nil
        script = (chunks, finish)
        lastRequest = nil
        lastBody = nil
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        responder = nil
        script = nil
    }

    static var capturedRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return lastRequest
    }

    /// 请求体（URLSession 会把 `httpBody` 转成流，这里在拦截时读出来）。
    static var capturedJSON: [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return lastBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WireStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = data
        }
        Self.lock.lock()
        Self.lastRequest = request
        Self.lastBody = body
        let responder = Self.responder
        let script = Self.script
        Self.lock.unlock()
        if let script {
            // 带上 Content-Type：不带的话 URLSession 会先攒够一段字节做类型嗅探，小块数据到不了调用方。
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            playback = Task { [weak self] in
                for chunk in script.chunks {
                    try? await Task.sleep(for: chunk.after)
                    guard !Task.isCancelled, let self else { return }
                    self.client?.urlProtocol(self, didLoad: Data(chunk.text.utf8))
                }
                guard script.finish, !Task.isCancelled, let self else { return }
                self.client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        guard let (response, payload) = responder?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        playback?.cancel()
    }
}
