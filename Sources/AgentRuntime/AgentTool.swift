import AgentKit
import Foundation

/// 交给模型的工具声明：名字、说明、参数的 JSON Schema（原始 JSON 字符串）。
public struct AgentToolSchema: Sendable, Hashable, Codable {
    public let name: String
    public let description: String
    public let parametersJSON: String

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }

    var wire: LLMToolSchema {
        LLMToolSchema(name: name, description: description, parametersJSON: parametersJSON)
    }
}

/// 工具跑完交回给模型的结果。
public struct AgentToolResult: Sendable, Hashable {
    public let content: String
    public let isError: Bool

    public init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}

/// 这一次调用要不要过审批。由工具按**这次的参数**判断（例如 `run_write` 收到的其实是
/// SELECT 就放行）。
public enum AgentToolApprovalRequirement: Sendable, Hashable {
    /// 直接运行。
    case none
    /// 先问审批策略（`AgentApprovalPolicy`），策略说「问用户」再走审批门。
    /// - Parameter subject: 审批卡上展示、会话放行按它精确匹配的那段内容（SQL、git 参数…）；
    ///   nil 时用原始参数 JSON。
    case ask(subject: String?)
    /// 每次都问用户：跳过策略，也不接受「本会话允许」。删库、强推一类操作用它。
    case alwaysManual
}

/// 一个可被模型调用的工具。`Context` 是 app 给工具的运行环境（数据库连接、仓库路径…），
/// 每一步由 `AgentTurnEnvironment` 现取。
///
/// 实现须是 `Sendable`：工具在 agent 循环之外的并发上下文里跑（`run` 是 nonisolated async）。
public protocol AgentTool<Context>: Sendable {
    associatedtype Context: Sendable

    var schema: AgentToolSchema { get }
    func approvalRequirement(arguments: String) -> AgentToolApprovalRequirement
    func run(arguments: String, context: Context) async throws -> AgentToolResult
}

extension AgentTool {
    /// 缺省不需要审批。
    public func approvalRequirement(arguments: String) -> AgentToolApprovalRequirement { .none }
}

/// 工具注册表：按 `schema.name` 索引。同名后注册的覆盖先注册的。
public actor AgentToolRegistry<Context: Sendable> {
    private var tools: [String: any AgentTool<Context>]
    /// 注册顺序：`allSchemas()` 按它输出，请求体稳定（便于 prompt cache 命中）。
    private var order: [String]

    public init(tools: [any AgentTool<Context>] = []) {
        var map: [String: any AgentTool<Context>] = [:]
        var order: [String] = []
        for tool in tools {
            let name = tool.schema.name
            if map[name] == nil { order.append(name) }
            map[name] = tool
        }
        self.tools = map
        self.order = order
    }

    public func tool(named name: String) -> (any AgentTool<Context>)? {
        tools[name]
    }

    public func allSchemas() -> [AgentToolSchema] {
        order.compactMap { tools[$0]?.schema }
    }

    public func register(_ tool: any AgentTool<Context>) {
        let name = tool.schema.name
        if tools[name] == nil { order.append(name) }
        tools[name] = tool
    }

    public func unregister(named name: String) {
        tools[name] = nil
        order.removeAll { $0 == name }
    }
}
