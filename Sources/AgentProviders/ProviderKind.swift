import AgentKit
import Foundation

/// provider 说的 wire 协议。存进 `LLMProvider.kindRaw` 的就是 `rawValue`，**已冻结**：
/// `anthropic` / `openai`（沿用 uTerm 的写法；uTable 的 `openAICompatible` 导入时折成 `openai`）。
public enum ProviderKind: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    /// Anthropic Messages API。Base URL 写根地址（`https://api.anthropic.com`），
    /// 端点 `/v1/messages`、`/v1/models` 由包里拼。
    case anthropic
    /// OpenAI `/chat/completions` 形状（OpenAI 原生与各家兼容端点）。Base URL **带版本前缀**
    /// （`https://api.openai.com/v1`、`…/api/paas/v4`），端点 `/chat/completions`、`/models`。
    case openai

    public var id: String { rawValue }

    /// 设置页上的类型名。
    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return String(localized: "OpenAI 兼容", bundle: ModuleBundle.bundle)
        }
    }

    /// 判定思考参数、选序列化格式用的协议（AgentKit 共享）。
    public var wireProtocol: AgentWireProtocol {
        switch self {
        case .anthropic: return .anthropic
        case .openai: return .openAICompatible
        }
    }

    /// 新建这一类 provider 时预填的 Base URL。
    public var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openai: return "https://api.openai.com/v1"
        }
    }
}

/// 「添加 provider」菜单里的预置端点（uTable 的 7 个）。只是方便的起点，用户随后能改任何字段。
/// 不预置模型：模型一律从端点的模型列表实时拉。
public struct ProviderPreset: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let kind: ProviderKind
    public let baseURL: String
    /// 本地服务（Ollama / LM Studio）不需要 API Key。
    public let requiresAPIKey: Bool

    public init(id: String, name: String, kind: ProviderKind, baseURL: String, requiresAPIKey: Bool) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.requiresAPIKey = requiresAPIKey
    }

    public static let all: [ProviderPreset] = [
        ProviderPreset(id: "openai", name: "OpenAI", kind: .openai,
                       baseURL: "https://api.openai.com/v1", requiresAPIKey: true),
        ProviderPreset(id: "anthropic", name: "Anthropic", kind: .anthropic,
                       baseURL: "https://api.anthropic.com", requiresAPIKey: true),
        ProviderPreset(id: "deepseek", name: "DeepSeek", kind: .openai,
                       baseURL: "https://api.deepseek.com", requiresAPIKey: true),
        ProviderPreset(id: "moonshot", name: "Moonshot (Kimi)", kind: .openai,
                       baseURL: "https://api.moonshot.cn/v1", requiresAPIKey: true),
        ProviderPreset(id: "zhipu", name: String(localized: "智谱 GLM", bundle: ModuleBundle.bundle, comment: "模型服务预置名（智谱 AI 的 GLM）"), kind: .openai,
                       baseURL: "https://open.bigmodel.cn/api/paas/v4", requiresAPIKey: true),
        ProviderPreset(id: "openrouter", name: "OpenRouter", kind: .openai,
                       baseURL: "https://openrouter.ai/api/v1", requiresAPIKey: true),
        ProviderPreset(id: "ollama", name: String(localized: "本地 Ollama", bundle: ModuleBundle.bundle, comment: "模型服务预置名：本机运行的 Ollama"), kind: .openai,
                       baseURL: "http://localhost:11434/v1", requiresAPIKey: false),
    ]
}
