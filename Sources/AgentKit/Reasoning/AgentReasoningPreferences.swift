import Foundation
import Observation

/// 用户为每个「provider + 模型」挑的思考深度，存本机 `UserDefaults`（不跨设备同步：
/// 同一个模型在 Mac 上想深一点、手机上想快一点，各管各的）。
///
/// 按模型分开记，是因为档位本身因模型而异（有的能关、有的有 xhigh）：换一个模型再换
/// 回来，原先的选择还在。没记录 = 「默认」，请求里不带任何思考参数。
@MainActor
@Observable
public final class AgentReasoningPreferences {
    public static let shared = AgentReasoningPreferences()

    static let defaultsKey = "agent.reasoningEffort.v1"

    @ObservationIgnored private let defaults: UserDefaults
    private var values: [String: AgentReasoningEffort]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        values = raw.compactMapValues(AgentReasoningEffort.init(rawValue:))
    }

    /// 该模型上记下的档位；nil = 默认。
    public func effort(providerID: UUID, model: String) -> AgentReasoningEffort? {
        values[Self.key(providerID, model)]
    }

    /// 记下（`nil` = 回到默认）。
    public func setEffort(_ effort: AgentReasoningEffort?, providerID: UUID, model: String) {
        let key = Self.key(providerID, model)
        guard values[key] != effort else { return }
        values[key] = effort
        defaults.set(values.mapValues(\.rawValue), forKey: Self.defaultsKey)
    }

    /// 直接给出这次请求该带的参数（没选 / 模型不支持都是 nil）。
    public func request(providerID: UUID, protocol wire: AgentWireProtocol,
                        model: String) -> AgentReasoningRequest? {
        AgentReasoningRequest.make(protocol: wire, modelID: model,
                                   effort: effort(providerID: providerID, model: model))
    }

    private static func key(_ providerID: UUID, _ model: String) -> String {
        "\(providerID.uuidString)|\(model)"
    }
}
