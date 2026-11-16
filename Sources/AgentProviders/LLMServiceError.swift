import AgentKit
import Foundation

/// 与模型服务打交道时的失败（对话、流式回复、拉模型列表共用）。原先是 uTable 的
/// `LLMProviderError`，这里补了一个 `.invalidEndpoint`：地址校验不再借道 `invalidResponse`。
///
/// `description` 是给人看的中文（Agent 面板的错误行、「[错误：…]」注记、设置页的测试结果）。
/// 要换文案的 app 自己 switch 这个枚举。
public enum LLMServiceError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case unauthenticated
    case rateLimited(retryAfter: TimeInterval?)
    case invalidResponse(String)
    case network(String)
    /// 这个 provider 不支持该操作（例如脚本化的测试 provider 没有非流式通道）。
    case unimplemented
    /// Base URL 不合规（见 `AgentEndpointPolicy`）。
    case invalidEndpoint(AgentEndpointPolicy.ValidationError)
    /// 服务端在流**内部**报错（HTTP 已经是 200）。中转网关上游过载 / 超时最常走这条。
    case streamError(String)
    /// 流结束了，却没等到任何收尾标记 —— 连接被中途掐断，回复不完整。
    case incompleteStream
    /// 模型撞上单次输出上限，回复在半句话处被截断。
    case outputLimitReached
    /// 流连续一段时间没有任何进展。
    case streamIdleTimeout

    public var description: String {
        switch self {
        case .unauthenticated: return "认证失败，请检查 API Key"
        case .rateLimited(let retryAfter):
            if let retryAfter { return "请求过于频繁，约 \(max(1, Int(retryAfter.rounded(.up)))) 秒后再试" }
            return "请求过于频繁，请稍后再试"
        case .invalidResponse(let message): return "模型服务返回了无法处理的响应：\(message)"
        case .network(let message): return "网络错误：\(message)"
        case .unimplemented: return "该服务不支持这个操作"
        case .invalidEndpoint(let error): return "Base URL 无效：\(Self.endpointMessage(error))"
        case .streamError(let message): return "模型服务在回复途中报错：\(message)"
        case .incompleteStream: return "连接中途断开，回复不完整"
        case .outputLimitReached: return "达到单次输出上限，回复被截断"
        case .streamIdleTimeout: return "模型服务长时间没有输出，已停止等待"
        }
    }

    public var errorDescription: String? { description }

    /// 这是对「一条已经开始的流」下的结论，不是「流没建起来」。换成非流式重发一遍帮不上忙，
    /// 所以收集流式回复时不走回退。
    public var isStreamVerdict: Bool {
        switch self {
        case .streamError, .incompleteStream, .outputLimitReached, .streamIdleTimeout: return true
        default: return false
        }
    }

    /// 请求层与 `URLSession` 抛的错误折成本类型。已经是本类型的、以及取消，原样返回；
    /// 请求层不包装网络错误，所以其余一律算 `.network`。
    public static func map(_ error: Error) -> Error {
        if error is LLMServiceError || error is CancellationError { return error }
        if let validation = error as? AgentEndpointPolicy.ValidationError {
            return LLMServiceError.invalidEndpoint(validation)
        }
        if let urlError = error as? URLError, urlError.code == .cancelled { return CancellationError() }
        guard let wire = error as? LLMWireError else {
            return LLMServiceError.network((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
        switch wire {
        case .http(let status, let body, let retryAfter):
            switch status {
            case 401, 403: return LLMServiceError.unauthenticated
            case 429: return LLMServiceError.rateLimited(retryAfter: retryAfter)
            default: return LLMServiceError.invalidResponse("HTTP \(status): \(body)")
            }
        case .invalidResponse(let message): return LLMServiceError.invalidResponse(message)
        case .streamError(let message): return LLMServiceError.streamError(message)
        case .incompleteStream: return LLMServiceError.incompleteStream
        case .outputLimitReached: return LLMServiceError.outputLimitReached
        case .streamIdleTimeout: return LLMServiceError.streamIdleTimeout
        }
    }

    /// 给人看的一句话（任意错误）。设置页「测试连接」、模型目录的失败原因都用它。
    public static func describe(_ error: Error) -> String {
        if let service = map(error) as? LLMServiceError { return service.description }
        if error is CancellationError { return "已取消" }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private static func endpointMessage(_ error: AgentEndpointPolicy.ValidationError) -> String {
        switch error {
        case .invalidURL: return "地址为空或格式不对"
        case .unsupportedScheme: return "只支持 HTTPS（本机地址可用 HTTP）"
        case .embeddedCredentials: return "地址里不能带用户名或密码"
        case .queryOrFragment: return "地址里不能带 ? 查询参数或 # 片段"
        case .insecureHTTP: return "远程地址必须用 HTTPS，HTTP 只允许本机地址"
        }
    }
}
