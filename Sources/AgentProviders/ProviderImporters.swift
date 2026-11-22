import CryptoKit
import Foundation

/// 一条待导入的 provider（导入器的输出、`ProviderStore.apply(_:)` 的输入）。
public struct ImportedProvider: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: ProviderKind
    /// 已按共享约定归一化（openai 带版本前缀、anthropic 根地址）。
    public var baseURL: String
    public var defaultModel: String?
    public var createdAt: Date?
    public var apiKey: String?
    /// 需要用户留意的地方（例如旧地址无法无损换算成新约定）。
    public var warning: String?

    public init(id: UUID, name: String, kind: ProviderKind, baseURL: String, defaultModel: String? = nil,
                createdAt: Date? = nil, apiKey: String? = nil, warning: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.createdAt = createdAt
        self.apiKey = apiKey
        self.warning = warning
    }

    /// 已在共享 store 里的一条，配上它的 Key —— 给 `mergeDuplicates(_:existing:)` 比对用。
    public init(snapshot: ProviderSnapshot, apiKey: String?) {
        self.init(id: snapshot.id, name: snapshot.name, kind: snapshot.kind, baseURL: snapshot.baseURL,
                  defaultModel: snapshot.defaultModel, createdAt: snapshot.createdAt, apiKey: apiKey)
    }

    /// 合并判重的身份：类型 + 归一化 Base URL + Key 的 SHA-256（没有 Key 记为空）。
    public var mergeIdentity: String {
        let keyHash = apiKey.map { key -> String in
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }
            return SHA256.hash(data: Data(trimmed.utf8)).map { String(format: "%02x", $0) }.joined()
        } ?? ""
        return "\(kind.rawValue)|\(ProviderEndpoint.normalizedBaseURL(baseURL))|\(keyHash)"
    }
}

/// uTerm 旧 `AIProvider` 记录的值快照（包里不认识 uTerm 的 `@Model`，由 uTerm 自己填）。
public struct UTermAIProviderRecord: Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// `anthropic` / `openai`。
    public var kindRaw: String
    /// uTerm 约定：根地址（不含 `/v1`）；空时用该类型的预置。
    public var baseURL: String
    /// uTerm 存在记录上的当前模型；导入后只作 `defaultModel` 提示。
    public var model: String
    public var sortOrder: Int
    public var createdAt: Date

    public init(id: UUID, name: String, kindRaw: String, baseURL: String, model: String,
                sortOrder: Int, createdAt: Date) {
        self.id = id
        self.name = name
        self.kindRaw = kindRaw
        self.baseURL = baseURL
        self.model = model
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

/// 旧数据导入器。都是纯函数：数据与 Key 的读取方式由调用方注入，这里不碰磁盘、不碰钥匙串。
///
/// 规则（不丢数据）：
/// - 旧 id 是 UUID 的原样保留（`activeProviderID`、推理偏好、模型目录缓存都靠它对应）；
///   不是 UUID 的（Electron 版）按来源 + 旧 id 派生一个确定性 UUID，重复导入得到同一个 id。
/// - Base URL 换算成共享约定（见各函数）。
/// - 只读取，不删除任何旧记录或旧钥匙串条目 —— 迁移期新旧并存。
/// - 等共享 store 首次同步完成后再导（`ProviderCloudKitMonitor.isReadyForMigration`），
///   写入走 `ProviderStore.apply(_:)`（id 已存在的跳过）。
public enum ProviderImporters {
    // MARK: - uTerm

    /// uTerm 的 `AIProvider` → 共享 provider。
    ///
    /// - openai：uTerm 存根地址、client 自己补 `/v1/chat/completions`；共享约定带版本前缀，
    ///   所以补上 `/v1`。
    /// - anthropic：本来就是根地址，原样。
    /// - `model` 挪成 `defaultModel` 提示（当前选择由 uTerm 自己存到本地）。
    /// - Parameter readKey: 读 (`com.uozi.uTerm`, uuid) 的 Key。
    public static func importUTermAIProviders(
        _ records: [UTermAIProviderRecord],
        readKey: (UUID) -> String?
    ) -> [ImportedProvider] {
        records.sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }.map { record in
            let kind = ProviderKind(rawValue: record.kindRaw) ?? .openai
            var base = trimmedBase(record.baseURL)
            if base.isEmpty {
                base = kind == .anthropic ? ProviderKind.anthropic.defaultBaseURL : "https://api.openai.com"
            }
            if kind == .openai { base += "/v1" }
            let model = record.model.trimmingCharacters(in: .whitespacesAndNewlines)
            return ImportedProvider(
                id: record.id,
                name: displayName(record.name, kind: kind),
                kind: kind,
                baseURL: base,
                defaultModel: model.isEmpty ? nil : model,
                createdAt: record.createdAt,
                apiKey: nonEmpty(readKey(record.id)))
        }
    }

    // MARK: - uTable

    /// uTable 存在 `UserDefaults` `agent.providers` 里的 JSON（`[LLMProviderConfig]`）→ 共享 provider。
    ///
    /// - `openAICompatible` 映射成 `openai`；Base URL 本来就是共享约定，原样。
    /// - `defaultModel`（uTable 的当前模型）作提示。
    /// - 解不出来的数据返回空数组（不抛：没有可导入的就是没有）。
    /// - Parameter readKey: 读 (`com.uozi.uTable`, `<uuid>__llmAPIKey`) 的 Key，读不到时回退
    ///   TablePro 的 service —— 由调用方实现。
    public static func importUTableProviders(
        defaultsData: Data?,
        readKey: (UUID) -> String?
    ) -> [ImportedProvider] {
        struct Stored: Decodable {
            let id: UUID
            let name: String
            let kind: String
            let baseURL: String
            let defaultModel: String?
        }
        guard let defaultsData,
              let stored = try? JSONDecoder().decode([LossyDecodable<Stored>].self, from: defaultsData)
        else { return [] }
        return stored.compactMap(\.value).map { item in
            let kind: ProviderKind = item.kind == "anthropic" ? .anthropic : .openai
            let model = item.defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ImportedProvider(
                id: item.id,
                name: displayName(item.name, kind: kind),
                kind: kind,
                baseURL: trimmedBase(item.baseURL),
                defaultModel: model.isEmpty ? nil : model,
                apiKey: nonEmpty(readKey(item.id)))
        }
    }

    // MARK: - Electron 版 uGit

    /// Electron 版的 Key 所在钥匙串 service（keytar，文件型登录钥匙串）。开发构建是 `uGit Dev - …`。
    public static let electronUGitKeychainService = "uGit - Third-party AI provider"
    public static let electronUGitDevKeychainService = "uGit Dev - Third-party AI provider"
    /// Electron 版 localStorage 里的 key。
    public static let electronUGitStorageKey = "ai-providers"

    /// Electron 版 uGit 的 localStorage `ai-providers`（`IAIProvider[]` 的 JSON 字符串）→ 共享 provider。
    ///
    /// 形状见 Electron 版 `app/src/lib/ai/providers.ts`：`{ id, name, protocol: "openai"|"anthropic",
    /// baseUrl, apiKeyAuth, requestTimeoutSeconds?, models: [{id, name}] }`。它拼端点的方式是
    /// `{baseUrl}/chat/completions`、`{baseUrl}/messages`、`{baseUrl}/models`，即两种协议都带版本前缀：
    /// - openai：原样（本来就是共享约定）。
    /// - anthropic：去掉末尾的 `/v1` 得到根地址；不以 `/v1` 结尾的地址无法无损换算，原样保留并给 warning。
    ///
    /// `apiKeyAuth == false`（本地服务）不读 Key。`selection` 是 Electron 版存的模型选择
    /// （`providerId:modelId`），命中的那条带上 `defaultModel`；否则用该 provider 的第一个模型。
    /// 校验与原实现一致：形状不对、或地址不是 HTTPS / 本机 HTTP 的条目丢弃。
    /// - Parameter readKey: 按 Electron provider id 读 Key（service 见 `electronUGitKeychainService`）。
    public static func importElectronUGitProviders(
        localStorageJSON: String?,
        selection: String? = nil,
        readKey: (String) -> String?
    ) -> [ImportedProvider] {
        struct Model: Decodable { let id: String }
        struct Stored: Decodable {
            let id: String
            let name: String
            let `protocol`: String
            let baseUrl: String
            let apiKeyAuth: Bool
            let models: [Model]
        }
        guard let data = localStorageJSON?.data(using: .utf8),
              let stored = try? JSONDecoder().decode([LossyDecodable<Stored>].self, from: data)
        else { return [] }
        let selected = selection.flatMap(parseElectronSelection)
        return stored.compactMap(\.value).compactMap { item -> ImportedProvider? in
            guard let kind = ProviderKind(rawValue: item.protocol),
                  isValidElectronBaseURL(item.baseUrl) else { return nil }
            var base = trimmedBase(item.baseUrl)
            var warning: String?
            if kind == .anthropic {
                if base.lowercased().hasSuffix("/v1") {
                    base.removeLast(3)
                } else {
                    warning = String(localized: "原地址不以 /v1 结尾，换算后请求路径可能不同，请检查 Base URL", bundle: .module)
                }
            }
            let model: String? = if let selected, selected.providerID == item.id {
                selected.modelID
            } else {
                item.models.first?.id
            }
            return ImportedProvider(
                id: UUID(uuidString: item.id) ?? DeterministicUUID.make(namespace: "ugit-electron", name: item.id),
                name: displayName(item.name, kind: kind),
                kind: kind,
                baseURL: base,
                defaultModel: model,
                apiKey: item.apiKeyAuth ? nonEmpty(readKey(item.id)) : nil,
                warning: warning)
        }
    }

    // MARK: - 合并

    /// 可选的去重：类型、归一化 Base URL、Key 哈希三者都相同的视为同一个 provider，只留先出现的
    /// （`existing` 里已有的优先）。用于「同一个服务在 uTerm、uTable 里各配了一份」的场景。
    public static func mergeDuplicates(_ imported: [ImportedProvider],
                                       existing: [ImportedProvider] = []) -> [ImportedProvider] {
        var seen = Set(existing.map(\.mergeIdentity))
        var seenIDs = Set(existing.map(\.id))
        return imported.filter { item in
            guard !seenIDs.contains(item.id) else { return true }   // 同 id 交给 apply 跳过
            seenIDs.insert(item.id)
            return seen.insert(item.mergeIdentity).inserted
        }
    }

    // MARK: - 私有

    private static func trimmedBase(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func displayName(_ raw: String, kind: ProviderKind) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.displayName : trimmed
    }

    private static func parseElectronSelection(_ value: String) -> (providerID: String, modelID: String)? {
        guard let separator = value.firstIndex(of: ":"),
              separator > value.startIndex,
              value.index(after: separator) < value.endIndex else { return nil }
        return (String(value[..<separator]), String(value[value.index(after: separator)...]))
    }

    /// 与 Electron 版 `isValidAIBaseUrl` 同规则：HTTPS，或本机 HTTP。
    private static func isValidElectronBaseURL(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw), let scheme = components.scheme?.lowercased(),
              let host = components.host else { return false }
        if scheme == "https" { return true }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return scheme == "http" && (bare == "localhost" || bare == "::1" || bare.hasPrefix("127."))
    }
}

/// 数组里坏掉的一项不拖垮整个数组。
struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// 名字型确定性 UUID：SHA-256(namespace + 0 + name) 取前 16 字节，按 RFC 9562 标成 v8。
/// 同一输入永远得到同一个 UUID —— 重复导入、不同设备导入都落在同一个 id 上。
public enum DeterministicUUID {
    public static func make(namespace: String, name: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data((namespace + "\u{0}" + name).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80   // version 8
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
