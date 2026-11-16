import AgentKit
import Foundation

/// 把共享 provider 接到 AgentKit 的 `AgentModelCatalog`（全部 provider 的可用模型列表，Agent
/// 输入区模型下拉的数据来源）。取代 uTerm / uTable 各自的 `AgentModelDirectory`。
///
/// 目录本身仍由各 app 持有（`AgentModelCatalog(describe: ProviderModelCatalog.describe)`，
/// 缓存在各自的 `.standard` 里），这里只给 `Source` 与错误文案。
public enum ProviderModelCatalog {
    /// 一个 provider 的拉取方式。Key 在拉取时现读（换了 Key 不必重建 source）。
    public static func source(for provider: ProviderSnapshot, secrets: any ProviderSecretStore,
                              session: URLSession = .shared) -> AgentModelCatalog.Source {
        let id = provider.id
        let endpoint = provider.endpoint
        return AgentModelCatalog.Source(providerID: id, endpoint: endpoint.catalogIdentity) {
            let key = (try? secrets.load(for: id)) ?? nil
            return try await endpoint.fetchModelIDs(apiKey: key ?? "", session: session)
        }
    }

    public static func sources(for providers: [ProviderSnapshot],
                               secrets: any ProviderSecretStore) -> [AgentModelCatalog.Source] {
        providers.map { source(for: $0, secrets: secrets) }
    }

    /// 打开模型下拉时调：先清掉已删除 provider 的条目，再刷新过期 / 出错 / 换了端点的；
    /// `force` 全部重拉。
    @MainActor
    public static func refresh(_ catalog: AgentModelCatalog, providers: [ProviderSnapshot],
                               secrets: any ProviderSecretStore, force: Bool = false) {
        catalog.retainOnly(Set(providers.map(\.id)))
        catalog.refresh(sources(for: providers, secrets: secrets), force: force)
    }

    /// 目录与「测试连接」共用的失败文案。
    public static func describe(_ error: Error) -> String {
        LLMServiceError.describe(error)
    }
}
