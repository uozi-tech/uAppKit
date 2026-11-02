import Foundation
import Observation

/// 全部已配置 provider 的可用模型列表 —— Agent 输入区模型下拉的数据来源。
///
/// 每个 provider 一份，取自它的 `/v1/models`（怎么请求由 app 给 `Source.fetch`：两个 app
/// 的端点拼法与鉴权各不相同）。上次拉到的列表存本机 `UserDefaults`，所以重启后打开下拉
/// 立刻有内容，同时在后台按需重拉；拉失败时保留旧列表并标出原因，不把能用的模型清空。
@MainActor
@Observable
public final class AgentModelCatalog {
    /// 一个 provider 的拉取方式。
    public struct Source: Sendable {
        public let providerID: UUID
        /// 端点身份（如 `kind|baseURL`）。变了说明换了端点，旧列表作废、必须重拉。
        public let endpoint: String
        public let fetch: @Sendable () async throws -> [String]

        public init(providerID: UUID, endpoint: String,
                    fetch: @escaping @Sendable () async throws -> [String]) {
            self.providerID = providerID
            self.endpoint = endpoint
            self.fetch = fetch
        }
    }

    /// 一个 provider 的列表状态。
    public struct Entry: Equatable, Codable, Sendable {
        /// 最近一次成功拉到的模型（服务端顺序）。
        public var models: [String]
        public var endpoint: String
        public var fetchedAt: Date?
        /// 最近一次拉取失败的原因；成功后清空。不落盘。
        public var error: String?
        public var isLoading: Bool

        private enum CodingKeys: String, CodingKey { case models, endpoint, fetchedAt }

        public init(models: [String] = [], endpoint: String, fetchedAt: Date? = nil,
                    error: String? = nil, isLoading: Bool = false) {
            self.models = models
            self.endpoint = endpoint
            self.fetchedAt = fetchedAt
            self.error = error
            self.isLoading = isLoading
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            models = try c.decode([String].self, forKey: .models)
            endpoint = try c.decode(String.self, forKey: .endpoint)
            fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt)
            error = nil
            isLoading = false
        }
    }

    /// 列表多久算过期（打开下拉时过期才重拉）。
    public static let freshness: TimeInterval = 10 * 60
    static let defaultsKey = "agent.modelCatalog.v1"

    public private(set) var entries: [UUID: Entry]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let describe: @Sendable (Error) -> String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    /// - Parameter describe: 拉取失败时给用户看的原因（各 app 有自己的错误类型）。
    public init(defaults: UserDefaults = .standard,
                describe: @escaping @Sendable (Error) -> String,
                now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.describe = describe
        self.now = now
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
        } else {
            entries = [:]
        }
    }

    public func entry(for providerID: UUID) -> Entry? {
        entries[providerID]
    }

    /// 是否有 provider 正在拉。
    public var isRefreshing: Bool {
        entries.values.contains(where: \.isLoading)
    }

    /// 刷新这些 provider 的列表：`force` 时全部重拉，否则只拉没有列表、换了端点、已过期或
    /// 上次失败的。只动 `sources` 里的 provider，别的不碰（设置页单独刷新一个时用）。
    public func refresh(_ sources: [Source], force: Bool = false) {
        for source in sources where force || needsRefresh(source) {
            load(source)
        }
        persist()
    }

    /// 只留这些 provider 的列表，其余（已删除的 provider）清掉。
    public func retainOnly(_ providerIDs: Set<UUID>) {
        let stale = entries.keys.filter { !providerIDs.contains($0) }
        guard !stale.isEmpty else { return }
        for id in stale {
            tasks.removeValue(forKey: id)?.cancel()
            entries.removeValue(forKey: id)
        }
        persist()
    }

    /// 等所有在途请求落定；测试用。
    public func waitUntilSettled() async {
        for task in tasks.values { await task.value }
    }

    /// 模型下拉里某个 provider 该列出的模型：拉到的列表，外加「已选中但不在列表里」的
    /// 那一个（端点不再提供 / 还没拉到），放在最前面，免得当前选择从菜单里消失。
    public func models(for providerID: UUID, including selected: String?) -> [String] {
        let fetched = entries[providerID]?.models ?? []
        guard let selected, !selected.isEmpty, !fetched.contains(selected) else { return fetched }
        return [selected] + fetched
    }

    private func needsRefresh(_ source: Source) -> Bool {
        guard let entry = entries[source.providerID] else { return true }
        if entry.isLoading { return false }
        if entry.endpoint != source.endpoint || entry.error != nil { return true }
        guard let fetchedAt = entry.fetchedAt else { return true }
        return now().timeIntervalSince(fetchedAt) > Self.freshness
    }

    private func load(_ source: Source) {
        let id = source.providerID
        tasks[id]?.cancel()
        var entry = entries[id] ?? Entry(endpoint: source.endpoint)
        if entry.endpoint != source.endpoint {
            entry = Entry(endpoint: source.endpoint)
        }
        entry.isLoading = true
        entries[id] = entry

        let fetch = source.fetch
        let describe = describe
        tasks[id] = Task { [weak self] in
            let result: Outcome
            do {
                result = .loaded(try await fetch())
            } catch {
                result = .failed(describe(error))
            }
            guard !Task.isCancelled, let self else { return }
            self.finish(id, endpoint: source.endpoint, result: result)
        }
    }

    private enum Outcome {
        case loaded([String])
        case failed(String)
    }

    private func finish(_ id: UUID, endpoint: String, result: Outcome) {
        guard var entry = entries[id], entry.endpoint == endpoint else { return }
        entry.isLoading = false
        switch result {
        case .loaded(let models):
            entry.models = models
            entry.fetchedAt = now()
            entry.error = nil
        case .failed(let message):
            entry.error = message
        }
        entries[id] = entry
        tasks[id] = nil
        persist()
    }

    private func persist() {
        let saved = Dictionary(uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
