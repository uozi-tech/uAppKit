import AgentKit
import Foundation

/// 一个 provider 的端点身份：类型 + Base URL。值类型、`Sendable`，可以跨 actor 传
/// （`@Model LLMProvider` 不行），请求、模型列表、目录缓存都只认它。
///
/// Base URL 约定（共享记录里存的就是这个形状）：
/// - `openai`：**带版本前缀**，端点直接接在后面 —— `{base}/chat/completions`、`{base}/models`。
/// - `anthropic`：根地址，端点带 `/v1` —— `{base}/v1/messages`、`{base}/v1/models?limit=1000`。
///
/// 地址校验走 `AgentEndpointPolicy`：格式不对、远端用了 HTTP、带了账号密码或 query，一律
/// 抛错而不是悄悄换个地址 —— API Key 与上下文会发到这里解析出的主机上。
public struct ProviderEndpoint: Sendable, Hashable, Codable {
    public var kind: ProviderKind
    public var baseURL: String

    public init(kind: ProviderKind, baseURL: String) {
        self.kind = kind
        self.baseURL = baseURL
    }

    /// 对话端点：`openai` → `{base}/chat/completions`；`anthropic` → `{base}/v1/messages`。
    public func chatURL() throws -> URL {
        switch kind {
        case .openai: return try Self.endpoint(baseURL, path: "/chat/completions")
        case .anthropic: return try Self.endpoint(baseURL, path: "/v1/messages")
        }
    }

    /// 模型列表端点：`openai` → `{base}/models`；`anthropic` → `{base}/v1/models?limit=1000`。
    public func modelsURL() throws -> URL {
        switch kind {
        case .openai:
            return try Self.endpoint(baseURL, path: "/models")
        case .anthropic:
            return try Self.endpoint(baseURL, path: "/v1/models",
                                     queryItems: [URLQueryItem(name: "limit", value: "1000")])
        }
    }

    /// 地址不合规的原因；合规返回 nil。
    public var validationError: AgentEndpointPolicy.ValidationError? {
        if case .failure(let error) = AgentEndpointPolicy.validatedBaseURL(baseURL) { return error }
        return nil
    }

    /// 模型目录缓存的端点身份（`AgentModelCatalog.Source.endpoint`）：变了说明换了端点，旧列表作废。
    public var catalogIdentity: String {
        "\(kind.rawValue)|\(Self.normalizedBaseURL(baseURL))"
    }

    /// 拉一次模型列表。错误折成 `LLMServiceError`（地址不合规是 `.invalidEndpoint`）。
    public func fetchModelIDs(apiKey: String, session: URLSession = .shared) async throws -> [String] {
        let url: URL
        do {
            url = try modelsURL()
        } catch {
            throw LLMServiceError.map(error)
        }
        do {
            return try await LLMWireTransport.fetchModelIDs(
                url: url, apiKey: apiKey, wireProtocol: kind.wireProtocol, session: session)
        } catch LLMWireError.http(let status, let body, let retryAfter) {
            // 错误体会直接显示在设置页里，先截短：一整页 HTML 不该撑爆提示。
            throw LLMServiceError.map(
                LLMWireError.http(status: status, body: Self.shortBody(body), retryAfter: retryAfter))
        } catch {
            throw LLMServiceError.map(error)
        }
    }

    // MARK: - 归一化

    /// 比较 / 去重用的 Base URL：去首尾空白、去末尾的 `/`、scheme 与 host 小写。
    /// 不改路径大小写（有的网关路径区分大小写），也不补或删版本段。
    public static func normalizedBaseURL(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard var components = URLComponents(string: trimmed), components.host != nil else { return trimmed }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.string ?? trimmed
    }

    // MARK: - 私有

    private static func endpoint(_ baseURL: String, path: String,
                                 queryItems: [URLQueryItem] = []) throws -> URL {
        try AgentEndpointPolicy.endpoint(baseURL: baseURL, path: path, queryItems: queryItems)
    }

    private static func shortBody(_ text: String) -> String {
        text.count > 300 ? String(text.prefix(300)) + "…" : text
    }
}
