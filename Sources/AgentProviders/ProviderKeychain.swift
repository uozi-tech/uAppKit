import Foundation
import Security

/// API Key 的存取。`ProviderStore` 只认这个协议，测试换成 `InMemoryProviderSecretStore`。
public protocol ProviderSecretStore: Sendable {
    /// 写入（覆盖）。空串等同删除。
    func save(_ key: String, for providerID: UUID) throws
    /// 条目不存在返回 nil；钥匙串被锁等其余错误抛出。
    func load(for providerID: UUID) throws -> String?
    /// 不存在不算错。
    func delete(for providerID: UUID) throws
}

/// 钥匙串错误。
public enum ProviderKeychainError: Error, Equatable, Sendable, LocalizedError {
    case unexpectedStatus(Int32)
    case dataEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = (SecCopyErrorMessageString(status, nil) as String?) ?? String(localized: "未知", bundle: ModuleBundle.bundle, comment: "钥匙串错误没有系统说明时的占位")
            return String(localized: "钥匙串错误 \(String(status))（\(message)）", bundle: ModuleBundle.bundle)
        case .dataEncodingFailed:
            return String(localized: "密钥数据编码失败", bundle: ModuleBundle.bundle)
        }
    }
}

/// `SecItem*` 三个调用的可注入外壳：单测换成内存实现，并能检查写入时带的属性
/// （访问组、可同步、数据保护钥匙串、可访问性）。
public protocol KeychainBackend: Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?)
    func delete(_ query: [String: Any]) -> OSStatus
}

/// 真钥匙串。
public struct SystemKeychainBackend: KeychainBackend {
    public init() {}

    public func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }

    public func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// 三个 app 共享的 provider API Key：钥匙串访问组 `<TEAMID>.com.uozi.shared`，
/// service `com.uozi.llm-providers`，account = provider UUID。
///
/// - 写入显式带 `kSecAttrAccessGroup`（由 app 传入完整的 `"<TEAMID>.com.uozi.shared"`）、
///   `kSecAttrSynchronizable = true`（经 iCloud 钥匙串端到端加密同步）、
///   `kSecUseDataProtectionKeychain = true`（macOS 上走 iOS 风格的数据保护钥匙串，
///   访问组才生效；不弹 ACL 授权框）、`kSecAttrAccessibleWhenUnlocked`。
/// - **读取与删除一律用 `kSecAttrSynchronizableAny`**：`kSecAttrSynchronizable` 参与匹配，
///   以 true 写入的条目用 false 查不到（uTerm 曾因此升级后读不到任何凭据）。
/// - entitlements 里 `keychain-access-groups` 要包含 `$(AppIdentifierPrefix)com.uozi.shared`，
///   且**不能排第一**：排第一会改掉 app 现有条目的默认写入组。
public struct ProviderKeychain: ProviderSecretStore {
    public static let service = "com.uozi.llm-providers"
    /// 访问组的后半截；完整值是 `<TEAMID>.com.uozi.shared`。
    public static let accessGroupSuffix = "com.uozi.shared"

    public let accessGroup: String?
    public let service: String
    private let backend: any KeychainBackend

    /// - Parameters:
    ///   - accessGroup: 完整访问组，即 `"<TEAMID>.com.uozi.shared"`。nil 只用于没有
    ///     keychain 能力的测试宿主（落到 app 的默认组，不共享）。
    public init(accessGroup: String?, service: String = ProviderKeychain.service,
                backend: any KeychainBackend = SystemKeychainBackend()) {
        self.accessGroup = accessGroup
        self.service = service
        self.backend = backend
    }

    /// 读条目的公共匹配键。`synchronizable` 只在写入时给具体值。
    func baseQuery(account: String, synchronizable: Any = kSecAttrSynchronizableAny) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func save(_ key: String, for providerID: UUID) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try delete(for: providerID)
            return
        }
        guard let data = trimmed.data(using: .utf8) else { throw ProviderKeychainError.dataEncodingFailed }
        let account = providerID.uuidString
        // 先按 Any 删干净，再写唯一一条可同步条目：历史上以 false 写入的条目一并收敛。
        try delete(account: account)
        var attributes = baseQuery(account: account, synchronizable: kCFBooleanTrue as Any)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = backend.add(attributes)
        guard status == errSecSuccess else { throw ProviderKeychainError.unexpectedStatus(status) }
    }

    public func load(for providerID: UUID) throws -> String? {
        var query = baseQuery(account: providerID.uuidString)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = backend.copyMatching(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ProviderKeychainError.unexpectedStatus(status) }
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    public func delete(for providerID: UUID) throws {
        try delete(account: providerID.uuidString)
    }

    private func delete(account: String) throws {
        let status = backend.delete(baseQuery(account: account))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderKeychainError.unexpectedStatus(status)
        }
    }
}

/// 内存实现：单测、预览、没有钥匙串能力的宿主。
public final class InMemoryProviderSecretStore: ProviderSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String]

    public init(_ values: [UUID: String] = [:]) {
        self.values = values
    }

    public func save(_ key: String, for providerID: UUID) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock { values[providerID] = trimmed.isEmpty ? nil : trimmed }
    }

    public func load(for providerID: UUID) throws -> String? {
        lock.withLock { values[providerID] }
    }

    public func delete(for providerID: UUID) throws {
        lock.withLock { values[providerID] = nil }
    }

    public var all: [UUID: String] {
        lock.withLock { values }
    }
}

/// 读旧数据用的「普通」钥匙串条目（迁移期只读）：uTerm 的 (`com.uozi.uTerm`, uuid)、
/// uTable 的 (`com.uozi.uTable`, `<uuid>__llmAPIKey`)、Electron 版 uGit 的
/// (`uGit - Third-party AI provider`, provider id)。
///
/// 不带访问组、可同步属性用 Any；`useDataProtectionKeychain` 为 false 时查的是 macOS 的
/// 文件型登录钥匙串 —— Electron 版（keytar）写在那里，读取时系统可能弹出 ACL 授权框，
/// UI 上要先告诉用户。
public struct LegacyKeychainReader: Sendable {
    private let backend: any KeychainBackend

    public init(backend: any KeychainBackend = SystemKeychainBackend()) {
        self.backend = backend
    }

    public func genericPassword(service: String, account: String,
                                useDataProtectionKeychain: Bool = false) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if useDataProtectionKeychain { query[kSecUseDataProtectionKeychain as String] = true }
        let (status, data) = backend.copyMatching(query)
        guard status == errSecSuccess, let data else { return nil }
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}
