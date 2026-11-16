import Foundation
import SwiftData

/// 三个 app 共享的一条 AI provider 配置，镜像到 CloudKit 容器 `iCloud.com.uozi.shared`。
///
/// **实体名与字段已冻结**（schema 部署到 Production 之后不能改名、不能改类型、不能删）：
/// SwiftData / CloudKit 只按类名识别实体，所以类名是 `LLMProvider` 而不是 uTerm 的
/// `AIProvider` —— 迁移期 uTerm 的旧类还要继续读。
///
/// CloudKit 镜像约束：所有存储属性都有默认值、`init()` 无参、没有 `.unique`、没有关系。
/// 同一个 `id` 在多台设备 / 多个 app 同时迁移时可能出现两行，读取一律按 `id` 去重
/// （见 `ProviderStore`）。
///
/// 不存 API Key（在共享钥匙串组里，见 `ProviderKeychain`），也不存「当前选中的模型」：
/// 那是各 app 自己的本地选择，共享的话在 uGit 里切模型会悄悄改掉 uTerm 的选择。
/// `defaultModel` 只是新建时的提示（例如从旧数据导入时带过来的那个）。
@Model
public final class LLMProvider {
    public var id: UUID = UUID()
    /// 用户起的名字。
    public var name: String = ""
    /// `ProviderKind.rawValue`：`anthropic` / `openai`。
    public var kindRaw: String = ProviderKind.openai.rawValue
    /// 约定见 `ProviderEndpoint`：openai 带版本前缀、anthropic 写根地址。
    public var baseURL: String = ""
    public var sortOrder: Int = 0
    public var createdAt: Date = Date()
    /// 模型提示；nil = 没有。不是「当前选中的模型」。
    public var defaultModel: String? = nil

    public init() {}

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ProviderKind,
        baseURL: String,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        defaultModel: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.baseURL = baseURL
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.defaultModel = defaultModel
    }

    /// 认不出的类型（未来版本写入的新值）按 `openai` 处理：保守、不掉链子。
    public var kind: ProviderKind {
        get { ProviderKind(rawValue: kindRaw) ?? .openai }
        set { kindRaw = newValue.rawValue }
    }

    public var endpoint: ProviderEndpoint {
        ProviderEndpoint(kind: kind, baseURL: baseURL)
    }

    /// 可以跨 actor 传的只读快照。
    public var snapshot: ProviderSnapshot {
        ProviderSnapshot(id: id, name: name, kind: kind, baseURL: baseURL, sortOrder: sortOrder,
                         createdAt: createdAt, defaultModel: defaultModel)
    }
}

/// `LLMProvider` 的值类型快照。`@Model` 对象不是 `Sendable`，进后台任务 / 网络请求的一律用它。
public struct ProviderSnapshot: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var name: String
    public var kind: ProviderKind
    public var baseURL: String
    public var sortOrder: Int
    public var createdAt: Date
    public var defaultModel: String?

    public init(id: UUID, name: String, kind: ProviderKind, baseURL: String, sortOrder: Int = 0,
                createdAt: Date = Date(), defaultModel: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.defaultModel = defaultModel
    }

    public var endpoint: ProviderEndpoint {
        ProviderEndpoint(kind: kind, baseURL: baseURL)
    }

    /// 列表行名称下面那行：类型 · 主机（如「Anthropic · api.anthropic.com」）。
    public var summary: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = URLComponents(string: trimmed).flatMap { components in
            components.host.map { host in components.port.map { "\(host):\($0)" } ?? host }
        } ?? trimmed
        return "\(kind.displayName) · \(address)"
    }
}
