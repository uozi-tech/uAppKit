import Foundation
import SwiftData

/// 共享 provider 的增删改查、排序、按 id 去重、删除时一并删 Key。
///
/// 每个 app 一个实例（挂在 app 环境上），`context` 来自 `ProviderStoreContainer.make`。
/// 读取一律按 `id` 去重：多台设备 / 多个 app 同时迁移旧数据时，CloudKit 里会出现同 id 的两行；
/// 只是读出来时合并成一行，**不自动删多余的行**：同 id 的两行字段往往完全相同，两台设备各自
/// 「留一删一」时可能恰好互删，结果一行不剩。改动（`update` / `move`）写到同 id 的每一行上，
/// 于是不管哪台设备留下的是哪一行，看到的都一样；用户删除时同 id 的行一并删掉。
@MainActor
public final class ProviderStore {
    public let context: ModelContext
    public let secrets: any ProviderSecretStore
    /// 最近一次写库失败的原因；之后一次成功的写入会清掉它。`add` 这类返回值另有用途的写操作
    /// 失败时，调用方从这里取原因提示用户。
    public private(set) var lastSaveError: Error?

    public init(context: ModelContext, secrets: any ProviderSecretStore) {
        self.context = context
        self.secrets = secrets
    }

    // MARK: - 读

    /// 全部 provider，按 `sortOrder`、`createdAt`、名字排序，同 id 只留一行。
    public func providers() -> [LLMProvider] {
        Self.deduplicated(fetchAll())
    }

    /// 快照版（跨 actor 用）。
    public func snapshots() -> [ProviderSnapshot] {
        providers().map(\.snapshot)
    }

    public func provider(id: UUID) -> LLMProvider? {
        providers().first { $0.id == id }
    }

    /// 当前该用哪个：先按 app 本地存的 id 找，没存或已删掉就取排序第一的；一个都没有时为 nil。
    public func active(preferredID: UUID?) -> LLMProvider? {
        let all = providers()
        if let preferredID, let match = all.first(where: { $0.id == preferredID }) { return match }
        return all.first
    }

    // MARK: - 增删改

    /// 新建一条排在最后。
    @discardableResult
    public func add(
        name: String,
        kind: ProviderKind,
        baseURL: String? = nil,
        defaultModel: String? = nil,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) -> LLMProvider {
        let provider = LLMProvider(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            baseURL: (baseURL ?? kind.defaultBaseURL).trimmingCharacters(in: .whitespacesAndNewlines),
            sortOrder: nextSortOrder(),
            createdAt: createdAt,
            defaultModel: defaultModel)
        context.insert(provider)
        save()
        return provider
    }

    /// 从预置新建（新 UUID）。
    @discardableResult
    public func add(preset: ProviderPreset) -> LLMProvider {
        add(name: preset.name, kind: preset.kind, baseURL: preset.baseURL)
    }

    /// 改字段后调用；也可以直接改对象属性再 `save()`。
    /// 写到同 id 的每一行上（见类型注释）。`defaultModel` 传 `.some(nil)` 表示清掉提示。
    /// - Returns: 写库失败的原因；nil = 成功。
    @discardableResult
    public func update(_ provider: LLMProvider, name: String? = nil, kind: ProviderKind? = nil,
                       baseURL: String? = nil, defaultModel: String?? = nil) -> Error? {
        for row in rows(id: provider.id) {
            if let name { row.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let kind { row.kind = kind }
            if let baseURL { row.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let defaultModel { row.defaultModel = defaultModel }
        }
        return save()
    }

    /// 删除这个 id 的所有行，连同钥匙串里的 Key。Key 删除失败不阻止删行（返回错误供提示）。
    /// 写库本身失败记在 `lastSaveError`（返回值的含义沿用「Key 删除失败」）。
    @discardableResult
    public func delete(_ provider: LLMProvider) -> Error? {
        let id = provider.id
        var keyError: Error?
        do { try secrets.delete(for: id) } catch { keyError = error }
        for row in rows(id: id) {
            context.delete(row)
        }
        save()
        return keyError
    }

    /// 按列表拖动后的顺序重写 `sortOrder`（与 SwiftUI `move(fromOffsets:toOffset:)` 同语义，
    /// `destination` 是移动前的下标）。`ordered` 须是当前显示顺序。
    /// - Returns: 写库失败的原因；nil = 成功。
    @discardableResult
    public func move(_ ordered: [LLMProvider], fromOffsets source: IndexSet, toOffset destination: Int) -> Error? {
        let moving = source.map { ordered[$0] }
        var result = ordered.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        result.insert(contentsOf: moving, at: destination - source.count(in: 0..<destination))
        for (index, provider) in result.enumerated() {
            for row in rows(id: provider.id) where row.sortOrder != index {
                row.sortOrder = index
            }
        }
        return save()
    }

    /// 写库。失败不抛（读路径照常可用），原因既作返回值、也记进 `lastSaveError`。
    @discardableResult
    public func save() -> Error? {
        do {
            try context.save()
            lastSaveError = nil
            return nil
        } catch {
            lastSaveError = error
            return error
        }
    }

    // MARK: - Key

    public func hasKey(for id: UUID) -> Bool {
        ((try? secrets.load(for: id)) ?? nil) != nil
    }

    /// nil = 没存或读不到。
    public func apiKey(for id: UUID) -> String? {
        (try? secrets.load(for: id)) ?? nil
    }

    public func saveKey(_ key: String, for id: UUID) throws {
        try secrets.save(key, for: id)
    }

    // MARK: - 导入

    /// 把导入器的结果写进来：id 已存在的跳过（不覆盖别的设备 / 别的 app 已经迁过、也许还改过的
    /// 记录），Key 只在这个 id 还没有 Key 时写。从不删除任何东西。
    @discardableResult
    public func apply(_ imported: [ImportedProvider]) -> ProviderImportReport {
        var report = ProviderImportReport()
        var existing = Set(providers().map(\.id))
        var order = nextSortOrder()
        for item in imported {
            if existing.contains(item.id) {
                report.skippedExisting.append(item.id)
            } else {
                let provider = LLMProvider(
                    id: item.id, name: item.name, kind: item.kind, baseURL: item.baseURL,
                    sortOrder: order, createdAt: item.createdAt ?? Date(), defaultModel: item.defaultModel)
                order += 1
                context.insert(provider)
                existing.insert(item.id)
                report.inserted.append(item.id)
            }
            if let key = item.apiKey, !key.isEmpty, !hasKey(for: item.id) {
                do {
                    try secrets.save(key, for: item.id)
                    report.keysWritten.append(item.id)
                } catch {
                    report.keyFailures[item.id] = LLMServiceError.describe(error)
                }
            }
        }
        save()
        return report
    }

    // MARK: - 私有

    private func fetchAll() -> [LLMProvider] {
        (try? context.fetch(FetchDescriptor<LLMProvider>())) ?? []
    }

    private func rows(id: UUID) -> [LLMProvider] {
        let descriptor = FetchDescriptor<LLMProvider>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(descriptor)) ?? []
    }

    private func nextSortOrder() -> Int {
        (fetchAll().map(\.sortOrder).max() ?? -1) + 1
    }

    /// 排序后按 id 去重：同 id 留排在前面的（`createdAt` 早的）。
    static func deduplicated(_ rows: [LLMProvider]) -> [LLMProvider] {
        let ordered = rows.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        var seen = Set<UUID>()
        return ordered.filter { seen.insert($0.id).inserted }
    }
}

/// `ProviderStore.apply(_:)` 的结果。
public struct ProviderImportReport: Equatable, Sendable {
    public var inserted: [UUID] = []
    public var skippedExisting: [UUID] = []
    public var keysWritten: [UUID] = []
    /// Key 写入失败的 provider 与原因。
    public var keyFailures: [UUID: String] = [:]

    public init() {}
}
