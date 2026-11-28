import AgentKit
import Foundation
import Observation

/// 编辑 / 新建一条 provider 时的表单值（不进库）。校验与「换类型跟着换 Base URL」都在这里，
/// 设置页只负责把字段绑到控件上。
public struct ProviderDraft: Equatable, Sendable {
    public var name: String
    public var kind: ProviderKind
    public var baseURL: String

    public init(name: String = "", kind: ProviderKind = .anthropic, baseURL: String? = nil) {
        self.name = name
        self.kind = kind
        self.baseURL = baseURL ?? kind.defaultBaseURL
    }

    public init(_ snapshot: ProviderSnapshot) {
        self.init(name: snapshot.name, kind: snapshot.kind, baseURL: snapshot.baseURL)
    }

    public init(preset: ProviderPreset) {
        self.init(name: preset.name, kind: preset.kind, baseURL: preset.baseURL)
    }

    public var endpoint: ProviderEndpoint {
        ProviderEndpoint(kind: kind, baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 名称必填。
    public var nameError: String? {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "名称不能为空", bundle: ModuleBundle.bundle) : nil
    }

    /// Base URL 必填；远程端点须 HTTPS，本机开发服务可用 HTTP。
    public var baseURLError: String? {
        if baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return String(localized: "Base URL 不能为空", bundle: ModuleBundle.bundle) }
        return endpoint.validationError.map { LLMServiceError.invalidEndpoint($0).description }
    }

    public var isValid: Bool { nameError == nil && baseURLError == nil }

    /// 换类型：Base URL 还是旧类型的缺省值时跟着换成新类型的缺省值；用户自定义过的不动。
    public mutating func setKind(_ newKind: ProviderKind) {
        guard newKind != kind else { return }
        if ProviderEndpoint.normalizedBaseURL(baseURL) == ProviderEndpoint.normalizedBaseURL(kind.defaultBaseURL) {
            baseURL = newKind.defaultBaseURL
        }
        kind = newKind
    }
}

/// 「测试连接」的结果。
public struct ProviderConnectionResult: Equatable, Sendable {
    public let ok: Bool
    public let message: String
    /// 测通时拉到的模型（服务端顺序）。
    public let models: [String]

    public init(ok: Bool, message: String, models: [String] = []) {
        self.ok = ok
        self.message = message
        self.models = models
    }
}

/// 测试连接 = 拉一次模型列表：认证、Base URL、网络一次验完，顺带告诉用户有几个模型可选。
public enum ProviderConnectionTest {
    public typealias Fetch = @Sendable (ProviderEndpoint, String) async throws -> [String]

    public static let liveFetch: Fetch = { endpoint, key in
        try await endpoint.fetchModelIDs(apiKey: key)
    }

    /// - Parameters:
    ///   - apiKey: 实际要用的 Key（草稿或钥匙串里的）；空串表示没有。
    ///   - requiresAPIKey: 本地服务可以不要 Key。
    public static func run(endpoint: ProviderEndpoint, apiKey: String, requiresAPIKey: Bool = true,
                           fetch: Fetch = liveFetch) async -> ProviderConnectionResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if requiresAPIKey, key.isEmpty, !isLoopback(endpoint) {
            return ProviderConnectionResult(ok: false, message: String(localized: "先填写或保存 API Key", bundle: ModuleBundle.bundle))
        }
        if let error = endpoint.validationError {
            return ProviderConnectionResult(ok: false, message: LLMServiceError.invalidEndpoint(error).description)
        }
        do {
            let ids = try await fetch(endpoint, key)
            return ProviderConnectionResult(
                ok: true,
                message: ids.isEmpty ? String(localized: "连接成功，但该端点没有列出任何模型", bundle: ModuleBundle.bundle) : String(localized: "连接成功 · \(ids.count) 个可用模型", bundle: ModuleBundle.bundle),
                models: ids)
        } catch {
            return ProviderConnectionResult(ok: false, message: LLMServiceError.describe(error))
        }
    }

    private static func isLoopback(_ endpoint: ProviderEndpoint) -> Bool {
        guard let host = URLComponents(string: endpoint.baseURL)?.host else { return false }
        return AgentEndpointPolicy.isLoopback(host)
    }
}

/// 设置页「API Key 草稿 + 保存 + 测试连接」的状态（由 uTerm `ProviderDraftModel` 泛化）。
/// 名称 / 类型 / Base URL 走 `draft`；Key 草稿非空时测试用草稿（先试再保存），否则用已存的。
@MainActor
@Observable
public final class ProviderEditorModel {
    public var draft: ProviderDraft
    public var keyDraft = ""
    public private(set) var providerID: UUID
    public private(set) var hasSavedKey = false
    public private(set) var keySaveError: String?
    /// 读钥匙串失败的原因（钥匙串被锁、无权访问…）；读到或确认没有 Key 时为 nil。
    /// 这时 `hasSavedKey` 为 false 只代表「没读到」，不代表没有。
    public private(set) var keyLoadError: String?
    public private(set) var testInFlight = false
    public private(set) var testResult: ProviderConnectionResult?

    @ObservationIgnored private let secrets: any ProviderSecretStore
    @ObservationIgnored private let fetch: ProviderConnectionTest.Fetch
    @ObservationIgnored private var testTask: Task<Void, Never>?

    public init(providerID: UUID = UUID(), draft: ProviderDraft, secrets: any ProviderSecretStore,
                fetch: @escaping ProviderConnectionTest.Fetch = ProviderConnectionTest.liveFetch) {
        self.providerID = providerID
        self.draft = draft
        self.secrets = secrets
        self.fetch = fetch
        refreshSavedKey()
    }

    public var trimmedKeyDraft: String {
        keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var canSaveKey: Bool { !trimmedKeyDraft.isEmpty }

    /// 把 Key 草稿存进钥匙串；成功后清空草稿。
    @discardableResult
    public func saveKey() -> Bool {
        guard canSaveKey else { return false }
        do {
            try secrets.save(trimmedKeyDraft, for: providerID)
            keyDraft = ""
            keySaveError = nil
            keyLoadError = nil
            hasSavedKey = true
            return true
        } catch {
            keySaveError = String(localized: "保存到钥匙串失败：\(Self.keychainReason(error))", bundle: ModuleBundle.bundle)
            return false
        }
    }

    /// 从钥匙串删掉 Key。删除失败时 `hasSavedKey` 保持原样并给出 `keySaveError`：界面不能在
    /// Key 其实还在（并且还在经 iCloud 钥匙串同步）的时候显示「已移除」。
    @discardableResult
    public func removeKey() -> Bool {
        do {
            try secrets.delete(for: providerID)
            hasSavedKey = false
            keySaveError = nil
            keyLoadError = nil
            return true
        } catch {
            keySaveError = String(localized: "从钥匙串移除失败：\(Self.keychainReason(error))", bundle: ModuleBundle.bundle,
                                  comment: "移除 API Key 失败；参数是钥匙串给的原因")
            return false
        }
    }

    /// 测试连接。重复点击时上一次作废。
    public func testConnection(requiresAPIKey: Bool = true) async {
        testTask?.cancel()
        let endpoint = draft.endpoint
        let key: String
        if trimmedKeyDraft.isEmpty {
            do {
                key = try secrets.load(for: providerID) ?? ""
            } catch {
                // 读不到已存的 Key 不等于没有 Key：如实报钥匙串的错，别让用户以为要重新填。
                testInFlight = false
                testResult = ProviderConnectionResult(ok: false, message: Self.loadErrorMessage(error))
                return
            }
        } else {
            key = trimmedKeyDraft
        }
        let fetch = fetch
        testInFlight = true
        testResult = nil
        let task = Task { @MainActor [weak self] in
            let result = await ProviderConnectionTest.run(endpoint: endpoint, apiKey: key,
                                                          requiresAPIKey: requiresAPIKey, fetch: fetch)
            guard !Task.isCancelled, let self else { return }
            self.testResult = result
            self.testInFlight = false
        }
        testTask = task
        await task.value
    }

    /// 换了编辑对象：清掉上一条的草稿与结果。
    public func reset(providerID: UUID, draft: ProviderDraft) {
        testTask?.cancel()
        self.providerID = providerID
        self.draft = draft
        keyDraft = ""
        keySaveError = nil
        testInFlight = false
        testResult = nil
        refreshSavedKey()
    }

    /// 重读「有没有已存的 Key」。读失败记进 `keyLoadError`，不当成「没有」悄悄吞掉。
    private func refreshSavedKey() {
        do {
            hasSavedKey = try secrets.load(for: providerID) != nil
            keyLoadError = nil
        } catch {
            hasSavedKey = false
            keyLoadError = Self.loadErrorMessage(error)
        }
    }

    /// 钥匙串错误的说明。不走 `LLMServiceError.describe`：那条路把不认识的错误都折成「网络错误」。
    private static func keychainReason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func loadErrorMessage(_ error: Error) -> String {
        String(localized: "读取钥匙串失败：\(Self.keychainReason(error))", bundle: ModuleBundle.bundle,
               comment: "读已保存的 API Key 失败；参数是钥匙串给的原因")
    }
}
