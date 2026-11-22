import Foundation

/// provider 端点说的 wire 协议。两个 app 各有自己的 provider 类型（uTerm `ProviderKind`、
/// uTable `LLMProviderKind`），判定思考参数时先折算成这一个。
public enum AgentWireProtocol: String, Sendable, Codable, Hashable {
    /// Anthropic Messages API（`/v1/messages`）。
    case anthropic
    /// OpenAI `/chat/completions` 形状（OpenAI 原生与各家兼容端点）。
    case openAICompatible
}

/// 思考 / 推理深度。用户在输入区挑一档，按 provider 与模型折算成真正的请求参数。
///
/// 「默认」不是这里的一档：没选过（存的是 nil）就什么参数都不带，交给模型自己的默认值。
public enum AgentReasoningEffort: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case off
    case low
    case medium
    case high
    case xhigh
    case max

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off:    return String(localized: "关闭", bundle: ModuleBundle.bundle, comment: "思考深度：关闭")
        case .low:    return String(localized: "低", bundle: ModuleBundle.bundle, comment: "思考深度：低")
        case .medium: return String(localized: "中", bundle: ModuleBundle.bundle, comment: "思考深度：中")
        case .high:   return String(localized: "高", bundle: ModuleBundle.bundle, comment: "思考深度：高")
        case .xhigh:  return String(localized: "超高", bundle: ModuleBundle.bundle, comment: "思考深度：超高")
        case .max:    return String(localized: "最高", bundle: ModuleBundle.bundle, comment: "思考深度：最高")
        }
    }
}

/// 某个模型支持哪几档思考深度、用哪种参数表达。
///
/// 判定只看模型 id —— `/v1/models` 不报思考能力（OpenAI 兼容端点更不报），只能按家族
/// 认。认不出的模型返回 nil：输入区不显示思考深度，请求里也不加任何参数，宁可少给也不
/// 让请求 400。
public struct AgentReasoningSupport: Sendable, Equatable {
    public enum Style: Sendable, Equatable {
        /// Anthropic 4.6 起：`thinking: {type: adaptive}` + `output_config.effort`。
        case anthropicAdaptive(off: AnthropicOff?)
        /// Anthropic 4.5 及以前：`thinking: {type: enabled, budget_tokens}`；关 = 不带。
        case anthropicBudget
        /// OpenAI 兼容：`reasoning_effort`。`offValue` 是「关」在该模型上的取值
        /// （gpt-5 是 `minimal`、gpt-5.1 起是 `none`）；nil = 不能关。
        case openAIReasoningEffort(offValue: String?)
        /// DeepSeek V4（OpenAI 兼容）：`thinking: {type: enabled|disabled}` + `reasoning_effort: low|high|max`。
        /// 默认就在思考（high）；关 = `thinking: {type: disabled}`，且不能再带 `reasoning_effort`。
        case deepSeekThinking
        /// DeepSeek V4 走 Anthropic 协议（官方 `/anthropic` 端点或按 Anthropic 协议转发的网关）：
        /// `thinking: {type: enabled|disabled}` + `output_config: {effort: low|high|max}`。
        /// 默认就在思考（high）；带工具续轮要把 thinking 块原样放回去。
        case deepSeekAnthropic
    }

    /// adaptive 模型「关闭思考」的写法。
    public enum AnthropicOff: Sendable, Equatable {
        /// `thinking: {type: disabled}`。
        case disabled
        /// Claude Sonnet 5.5 不收 `disabled`，关思考要写 `between_tools`（且不能再带 effort）。
        case betweenTools
    }

    public let style: Style
    /// 可选档位，由浅到深；含 `.off` 表示能关。
    public let levels: [AgentReasoningEffort]

    public init(style: Style, levels: [AgentReasoningEffort]) {
        self.style = style
        self.levels = levels
    }

    /// 按协议与模型 id 判定；不支持返回 nil。
    public static func resolve(protocol wire: AgentWireProtocol, modelID: String) -> AgentReasoningSupport? {
        switch wire {
        case .anthropic:
            return anthropic(modelID)
        case .openAICompatible:
            // 经 OpenAI 兼容中转（OpenRouter 等）的 Claude 不认：中转怎么转写思考参数各不相同。
            return openAI(modelID)
        }
    }

    /// 这个模型收不收 `temperature` / `top_p` / `top_k`（不管选没选思考深度）。
    ///
    /// Claude Opus 4.7 起、Sonnet 5 / 5.5、Haiku 5.5、Fable / Mythos 把采样参数拿掉了，
    /// 带了就 400；OpenAI 的推理模型（o 系列、gpt-5）只收默认值。认不出的模型照旧收。
    public static func acceptsSamplingParameters(protocol wire: AgentWireProtocol, modelID: String) -> Bool {
        switch wire {
        case .anthropic:
            guard let model = ClaudeModel(modelID) else { return true }
            if model.family == "fable" || model.family == "mythos" { return false }
            return !model.atLeast(4, 7)
        case .openAICompatible:
            guard case .openAIReasoningEffort? = openAI(modelID)?.style else { return true }
            // 同属 reasoning_effort 一族，但 grok / gemini 照收 temperature。
            var id = modelID.lowercased()
            if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) }
            return !(id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") || id.hasPrefix("gpt-5"))
        }
    }

    // MARK: - Anthropic

    /// 解析出来的 Claude 型号：家族 + 版本。
    struct ClaudeModel: Equatable {
        var family: String
        var major: Int
        var minor: Int

        init(family: String, major: Int, minor: Int) {
            self.family = family
            self.major = major
            self.minor = minor
        }

        /// 认 `claude-opus-4-7`、`claude-sonnet-4-5-20250929`、`claude-opus-5`、
        /// `claude-3-7-sonnet-latest`，以及 `anthropic/…`、`us.anthropic.…` 这类前缀。
        init?(_ raw: String) {
            var id = raw.lowercased()
            if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) }
            guard let range = id.range(of: "claude-") else { return nil }
            let parts = id[range.upperBound...].split(separator: "-").map(String.init)
            let families = ["opus", "sonnet", "haiku", "fable", "mythos"]
            if let first = parts.first, families.contains(first) {
                // claude-<family>-<major>[-<minor>][-<date>]
                guard parts.count >= 2, let major = Int(parts[1]) else { return nil }
                family = first
                self.major = major
                // 日期后缀（8 位）不是小版本号。
                if parts.count >= 3, let minor = Int(parts[2]), parts[2].count <= 2 {
                    self.minor = minor
                } else {
                    self.minor = 0
                }
            } else {
                // 旧式 claude-<major>[-<minor>]-<family>
                guard let major = parts.first.flatMap(Int.init) else { return nil }
                self.major = major
                var rest = parts.dropFirst()
                if let next = rest.first, let minor = Int(next) {
                    self.minor = minor
                    rest = rest.dropFirst()
                } else {
                    self.minor = 0
                }
                guard let name = rest.first, families.contains(name) else { return nil }
                family = name
            }
        }

        func atLeast(_ major: Int, _ minor: Int) -> Bool {
            (self.major, self.minor) >= (major, minor)
        }
    }

    private static func anthropic(_ modelID: String) -> AgentReasoningSupport? {
        if isDeepSeekV4(modelID) {
            return .init(style: .deepSeekAnthropic, levels: [.off, .low, .high, .max])
        }
        guard let model = ClaudeModel(modelID) else { return nil }
        let full: [AgentReasoningEffort] = [.low, .medium, .high, .xhigh, .max]

        // Fable / Mythos：思考恒开，只能调 effort。
        if model.family == "fable" || model.family == "mythos" {
            return .init(style: .anthropicAdaptive(off: nil), levels: full)
        }
        // 4.6 起是 adaptive。
        if model.atLeast(4, 6) {
            switch (model.family, model.major, model.minor) {
            case ("opus", 4, 6), ("sonnet", 4, 6):
                // xhigh 从 Opus 4.7 才有。
                return .init(style: .anthropicAdaptive(off: .disabled),
                             levels: [.off, .low, .medium, .high, .max])
            case ("opus", 4, _), ("opus", 5, 0), ("sonnet", 5, 0), ("haiku", 5, 5):
                return .init(style: .anthropicAdaptive(off: .disabled), levels: [.off] + full)
            case ("sonnet", 5, 5):
                return .init(style: .anthropicAdaptive(off: .betweenTools), levels: [.off] + full)
            default:
                // Opus 5.5 与更新、认不全的新型号：思考关不掉（`disabled` 会 400），不给「关」。
                return .init(style: .anthropicAdaptive(off: nil), levels: full)
            }
        }
        // 3.7 Sonnet 与 4.x（≤4.5）：budget_tokens。更早的型号没有 extended thinking。
        if model.atLeast(4, 0) || (model.major == 3 && model.minor == 7 && model.family == "sonnet") {
            return .init(style: .anthropicBudget, levels: [.off, .low, .medium, .high])
        }
        return nil
    }

    // MARK: - OpenAI 兼容

    private static func openAI(_ modelID: String) -> AgentReasoningSupport? {
        var id = modelID.lowercased()
        if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) }

        // o 系列推理模型。
        if id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") {
            return .init(style: .openAIReasoningEffort(offValue: nil), levels: [.low, .medium, .high])
        }
        if id.hasPrefix("gpt-5") {
            // gpt-5-chat-* 是不推理的对话版。
            if id.contains("chat") { return nil }
            // gpt-5 / gpt-5-mini / gpt-5-nano 的最低档叫 minimal；gpt-5.1 起叫 none。
            let isFirstGeneration = id == "gpt-5" || id.hasPrefix("gpt-5-")
            return .init(style: .openAIReasoningEffort(offValue: isFirstGeneration ? "minimal" : "none"),
                         levels: [.off, .low, .medium, .high])
        }
        if id.hasPrefix("grok-3-mini") {
            return .init(style: .openAIReasoningEffort(offValue: nil), levels: [.low, .high])
        }
        if id.hasPrefix("gemini-2.5") || id.hasPrefix("gemini-3") {
            return .init(style: .openAIReasoningEffort(offValue: nil), levels: [.low, .medium, .high])
        }
        // DeepSeek V4：deepseek-v4-flash / deepseek-v4-pro，以及官方示例里的 deepseek-flash / deepseek-pro。
        // 旧 id deepseek-chat / deepseek-reasoner 固定一种模式，不给档位。
        if isDeepSeekV4(id) {
            return .init(style: .deepSeekThinking, levels: [.off, .low, .high, .max])
        }
        return nil
    }

    /// DeepSeek V4：deepseek-v4-flash / deepseek-v4-pro，以及官方示例里的 deepseek-flash / deepseek-pro
    /// （可带 `deepseek/` 这类中转前缀）。旧 id deepseek-chat / deepseek-reasoner 固定一种模式，不算。
    static func isDeepSeekV4(_ modelID: String) -> Bool {
        var id = modelID.lowercased()
        if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) }
        return id.hasPrefix("deepseek-v4") || id.hasPrefix("deepseek-flash") || id.hasPrefix("deepseek-pro")
    }
}

/// 一次请求要带的思考参数（已按模型折算好）。nil 表示什么都不带。
public struct AgentReasoningRequest: Sendable, Equatable {
    public let support: AgentReasoningSupport
    public let effort: AgentReasoningEffort

    /// budget_tokens 档位（仅 `anthropicBudget`）。必须 ≥1024 且小于 max_tokens。
    public static let anthropicBudgets: [AgentReasoningEffort: Int] = [
        .low: 2_048, .medium: 8_192, .high: 24_576,
    ]

    /// adaptive 思考时 max_tokens 的下限：思考 token 计入 max_tokens，沿用不思考时的
    /// 4K / 8K 上限，深一点的档位一想就撞线。
    public static let adaptiveMinimumMaxTokens = 32_000

    /// 选了档位且该模型支持这一档才返回值；`effort` 为 nil（「默认」）或模型不支持都返回 nil。
    public static func make(protocol wire: AgentWireProtocol,
                            modelID: String,
                            effort: AgentReasoningEffort?) -> AgentReasoningRequest? {
        guard let effort,
              let support = AgentReasoningSupport.resolve(protocol: wire, modelID: modelID),
              support.levels.contains(effort) else { return nil }
        return AgentReasoningRequest(support: support, effort: effort)
    }

    /// 这一档真的会让模型思考（不是「关」）。
    public var thinks: Bool { effort != .off }

    /// Anthropic 请求体里要并进去的字段，以及调整后的 `max_tokens`。
    public func anthropicBody(baseMaxTokens: Int) -> (fields: [String: Any], maxTokens: Int) {
        switch support.style {
        case .anthropicAdaptive(let off):
            guard thinks else {
                switch off {
                case .disabled?:     return (["thinking": ["type": "disabled"]], baseMaxTokens)
                case .betweenTools?: return (["thinking": ["type": "between_tools"]], baseMaxTokens)
                case nil:            return ([:], baseMaxTokens)
                }
            }
            return ([
                "thinking": ["type": "adaptive"],
                "output_config": ["effort": effort.rawValue],
            ], max(baseMaxTokens, Self.adaptiveMinimumMaxTokens))
        case .anthropicBudget:
            guard thinks, let budget = Self.anthropicBudgets[effort] else { return ([:], baseMaxTokens) }
            return (["thinking": ["type": "enabled", "budget_tokens": budget]], baseMaxTokens + budget)
        case .deepSeekAnthropic:
            guard thinks else { return (["thinking": ["type": "disabled"]], baseMaxTokens) }
            // 思考 token 计入 max_tokens，同 adaptive 抬到下限。
            return ([
                "thinking": ["type": "enabled"],
                "output_config": ["effort": deepSeekEffort],
            ], max(baseMaxTokens, Self.adaptiveMinimumMaxTokens))
        case .openAIReasoningEffort, .deepSeekThinking:
            return ([:], baseMaxTokens)
        }
    }

    /// DeepSeek 只有 low / high / max：medium 按官方映射算 high，xhigh 也是 high。
    private var deepSeekEffort: String {
        switch effort {
        case .low: "low"
        case .max: "max"
        default: "high"
        }
    }

    /// 请求里不能带 `temperature` / `top_p` / `top_k`：开着 Anthropic thinking 时非默认值
    /// 会 400；OpenAI 的推理模型（o 系列、gpt-5）一律只收默认值。
    public var forbidsSamplingParameters: Bool {
        switch support.style {
        case .anthropicAdaptive, .anthropicBudget: return thinks
        case .openAIReasoningEffort: return true
        // 思考模式下 DeepSeek 不理 temperature 等（不报错，只是无效）：不带，免得以为生效了。
        case .deepSeekThinking, .deepSeekAnthropic: return thinks
        }
    }

    /// 续轮请求要不要把本轮 assistant 消息的 thinking 块原样放回去（只有 Anthropic 有）。
    public var replaysThinking: Bool {
        switch support.style {
        case .anthropicAdaptive, .anthropicBudget, .deepSeekAnthropic: return thinks
        case .openAIReasoningEffort, .deepSeekThinking: return false
        }
    }

    /// OpenAI 兼容请求体里要并进去的字段。
    public var openAIBody: [String: Any] {
        if case .deepSeekThinking = support.style {
            guard thinks else { return ["thinking": ["type": "disabled"]] }
            return ["thinking": ["type": "enabled"], "reasoning_effort": deepSeekEffort]
        }
        guard case .openAIReasoningEffort(let offValue) = support.style else { return [:] }
        if effort == .off {
            return offValue.map { ["reasoning_effort": $0] } ?? [:]
        }
        // OpenAI 没有 max 档，最深就是 high。
        let value: String
        switch effort {
        case .xhigh, .max: value = "high"
        default: value = effort.rawValue
        }
        return ["reasoning_effort": value]
    }
}
