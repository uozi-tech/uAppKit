import AgentKit
import AgentProviders
import Foundation
import Observation

/// agent 循环每一步开始前现取的东西：system prompt 与给工具的运行环境。
public struct AgentTurnStep<Context: Sendable>: Sendable {
    public var systemPrompt: String
    public var toolContext: Context

    public init(systemPrompt: String, toolContext: Context) {
        self.systemPrompt = systemPrompt
        self.toolContext = toolContext
    }
}

/// app 给 agent 循环的环境。每一步（每次请求模型之前）调一次 `prepareStep`：当前选中的仓库 /
/// 表、编辑器内容这类会在一轮之内变化的东西，在这里取到最新值。
public struct AgentTurnEnvironment<Context: Sendable>: Sendable {
    public var prepareStep: @Sendable () async -> AgentTurnStep<Context>

    public init(prepareStep: @escaping @Sendable () async -> AgentTurnStep<Context>) {
        self.prepareStep = prepareStep
    }

    /// 固定的 prompt 与环境。
    public static func fixed(systemPrompt: String, toolContext: Context) -> Self {
        let step = AgentTurnStep(systemPrompt: systemPrompt, toolContext: toolContext)
        return Self { step }
    }
}

/// agent 循环：把用户消息发给模型，按需派发工具（需要时过审批策略与审批门），把结果追加回
/// 会话，再续轮，直到模型不再调用工具。由 uTable `AgentSession` 泛化而来。
///
/// 要点：
/// - **turn 身份**：每一轮一个 id。取消 / 重置 / 新一轮之后，旧循环可能晚一拍才从模型或工具
///   里回来，那时它已经无权再写会话（否则会把结果写进别的对话，或盖掉新一轮的状态）。
/// - **取消时结算未完成的工具调用**：assistant 消息里没等到结果的调用会让下一次请求被拒
///   （tool_use 没有对应的 tool_result），所以补一条说明 —— 没轮到的写「未执行」，正在跑的写
///   「可能已生效」。
/// - **排队**：忙碌时 `submit` 入队（AgentKit `AgentMessageQueue`）。`.afterTurn` 整轮结束后作为
///   新一轮发出；`.nextStep` 这一步的工具结果齐了、下一次请求之前并入会话（不打断在途回复）。
/// - 最多 `maxIterations`（缺省 16）次模型请求。
/// - **thinking 回放**：本轮工具循环里 assistant 消息的 thinking 块原样回传，跨轮不传。
/// - **压缩只作用于出站副本**：内存 `messages` 与聊天记录始终保留全文。
/// - `recorder` 每追加一条会话消息调一次（system 不经此路），接到 `AgentChatStore` 写穿持久化。
@MainActor
@Observable
public final class AgentRuntimeSession<Context: Sendable> {
    public enum State: Sendable, Equatable {
        case idle
        /// 已发出请求，还没收到任何文字。
        case sending
        /// 模型正在吐文字（见 `streamingText`）。
        case streaming
        /// 审批策略正在判（可能在请 AI 审查）。
        case reviewingTool(name: String)
        case waitingForApproval(toolName: String)
        case runningTool(name: String)
        case error(String)
    }

    // MARK: - 可观察状态

    public private(set) var messages: [AgentMessage] = []
    /// 与 `messages` 一一对应的展示身份。SwiftUI 的行身份必须独立于数组位置：恢复 / 插入消息后，
    /// 后续行的展开态不该被当成另一行。
    public private(set) var messageIDs: [UUID] = []
    public private(set) var state: State = .idle
    /// 正在吐的这条回复（还没进 `messages`）；不在吐时为 nil。按 `streamingPublishInterval` 节流更新。
    public private(set) var streamingText: String?
    /// 正在 `tool.run` 里的那条调用。
    public private(set) var runningToolCallID: String?
    /// 最近一次带用量的回复（只有非流式回退带）。
    public private(set) var lastUsage: LLMUsage?
    /// user 消息的展示别名（按 `messages` 下标）：`/` 命令展开成长 prompt 发送，气泡里只显示原文。
    public private(set) var userDisplayOverrides: [Int: String] = [:]
    /// 排队消息的展示别名。
    public private(set) var queuedDisplayOverrides: [UUID: String] = [:]
    private var queue = AgentMessageQueue()

    // MARK: - 配置

    /// 聊天记录写穿回调：每 append 一条会话消息调一次（system 除外）。
    @ObservationIgnored public var recorder: (@MainActor (AgentMessage, String?) -> Void)?
    /// 思考深度（已按当前模型折算）。每次请求现取：输入区改了档位，下一次请求就生效。
    @ObservationIgnored public var reasoningProvider: (@MainActor () -> AgentReasoningRequest?)?

    public let model: String
    public let maxIterations: Int
    public let temperature: Double?
    /// 出站上下文压缩；nil = 全量发送。
    public let contextPolicy: AgentContextCompressor.Policy?

    @ObservationIgnored private let provider: any AgentLLMProvider
    @ObservationIgnored private let tools: AgentToolRegistry<Context>
    @ObservationIgnored private let environment: AgentTurnEnvironment<Context>
    @ObservationIgnored private let approvalGate: any ApprovalGate
    @ObservationIgnored private let approvalPolicy: any AgentApprovalPolicy
    @ObservationIgnored private let auditLog: AgentAuditLog?

    @ObservationIgnored private var inflightTask: Task<Void, Never>?
    @ObservationIgnored private var currentTurnID: UUID?
    /// 本轮工具循环里 assistant 消息的 thinking 块（按其第一个 tool call 的 id）。新的用户消息
    /// 一来就清空 —— 跨轮不回传是 API 允许的「从历史前端移除」。
    @ObservationIgnored private var thinkingReplay: [String: [LLMThinkingBlock]] = [:]
    /// 重置 / 恢复时清审批门放行列表的那次调用；下一轮开始前等它完成。
    @ObservationIgnored private var gateReset: Task<Void, Never>?
    @ObservationIgnored private var streamingBuffer = ""
    @ObservationIgnored private var lastStreamingPublish: ContinuousClock.Instant?

    /// 文字增量最多每隔这么久刷新一次 `streamingText`，免得每个 SSE 碎片都失效一次视图。
    public static var streamingPublishInterval: Duration { .milliseconds(50) }

    // MARK: - 交回模型的固定文案（不是界面文案，所以用英文短句）

    public nonisolated static var userDenied: String { "user_denied" }
    public nonisolated static var cancelledBeforeRunning: String { AgentRuntimeSessionText.cancelledBeforeRunning }
    public nonisolated static var cancelledWhileRunning: String {
        "cancelled_by_user: the user stopped this turn while the tool was running; "
            + "it may or may not have taken effect — verify before retrying."
    }
    public nonisolated static var interruptedBeforeRestore: String {
        "interrupted: the session ended before this tool reported a result; "
            + "it may or may not have taken effect — verify before retrying."
    }
    public nonisolated static func policyDenied(_ reason: String) -> String { "policy_denied: \(reason)" }
    public nonisolated static func unknownTool(_ name: String) -> String { "Error: unknown tool \(name)" }

    // MARK: - 界面文案

    public nonisolated static var noModelMessage: String { "还没有选择模型：在输入区的模型菜单里选一个" }
    public nonisolated static func iterationLimitMessage(_ limit: Int) -> String {
        "工具调用超过 \(limit) 步上限，已停止。可以接着发消息让它继续。"
    }

    public init(
        provider: any AgentLLMProvider,
        model: String,
        tools: AgentToolRegistry<Context>,
        environment: AgentTurnEnvironment<Context>,
        approvalGate: any ApprovalGate,
        approvalPolicy: any AgentApprovalPolicy = AlwaysAskApprovalPolicy(),
        auditLog: AgentAuditLog? = nil,
        contextPolicy: AgentContextCompressor.Policy? = AgentContextCompressor.Policy(),
        maxIterations: Int = 16,
        temperature: Double? = 0.2
    ) {
        self.provider = provider
        self.model = model
        self.tools = tools
        self.environment = environment
        self.approvalGate = approvalGate
        self.approvalPolicy = approvalPolicy
        self.auditLog = auditLog
        self.contextPolicy = contextPolicy
        self.maxIterations = max(1, maxIterations)
        self.temperature = temperature
    }

    // MARK: - 公开 API

    /// 排着队、还没发出去的消息，按送达顺序。
    public var queuedMessages: [AgentQueuedMessage] { queue.items }

    /// 有一轮正拥有这个会话。比 `state` 早一拍为真，「该发还是该排队」看它。
    public var isBusy: Bool { currentTurnID != nil }

    /// 面板的提交入口：空闲时开新一轮（并等到这一轮及其后排队的各轮都结束才返回），
    /// 忙碌时排队 —— 不打断在途的这一轮。
    /// - Parameter delivery: 只在忙碌时有意义：排到整轮结束（缺省），还是这一步的工具跑完就并入会话。
    public func submit(_ text: String, displayAs display: String? = nil,
                       delivery: AgentQueuedMessage.Delivery = .afterTurn) async {
        guard isBusy else {
            await send(userMessage: text, displayAs: display)
            return
        }
        if let item = queue.enqueue(text, delivery: delivery), let display {
            queuedDisplayOverrides[item.id] = display
        }
    }

    public func removeQueued(id: UUID) {
        queue.remove(id: id)
        queuedDisplayOverrides[id] = nil
    }

    /// 「立即发送」：不打断在途回复，把这条排队消息改成下一步送达。
    public func sendQueuedAtNextStep(id: UUID) {
        queue.sendAtNextStep(id: id)
    }

    /// 把一条排队消息取出来交还给输入框编辑：出队，返回用户当初敲的文字（`/` 命令返回原文）。
    public func takeQueuedForEditing(id: UUID) -> String? {
        guard let item = queue.remove(id: id) else { return nil }
        return queuedDisplayOverrides.removeValue(forKey: id) ?? item.text
    }

    /// 立刻开新一轮。在途的一轮会被取消（想排队而不是打断，走 `submit`）。这一轮结束后
    /// （空闲或出错）接着把排队消息一轮一轮发完才返回。
    public func send(userMessage: String, displayAs display: String? = nil) async {
        guard !model.isEmpty else {
            state = .error(Self.noModelMessage)
            return
        }
        abandonInflightTurn()
        settleUnansweredToolCalls()

        let turnID = UUID()
        currentTurnID = turnID
        if let gateReset {
            await gateReset.value
            self.gateReset = nil
        }
        guard owns(turnID) else { return }

        var prompts = [Prompt(text: userMessage, display: display)]
        var turn = turnID
        while !prompts.isEmpty {
            for prompt in prompts {
                append(.user(prompt.text), display: prompt.display)
            }
            thinkingReplay.removeAll()
            currentTurnID = turn
            let thisTurn = turn
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runLoop(turnID: thisTurn)
            }
            inflightTask = task
            await task.value
            // 这一轮被停止 / 重置 / 另一次 `send` 接管了：队列归接管方处置，这里收手。
            guard owns(thisTurn) else { return }
            // 出错也接着发：否则排队消息卡在条带里，下一条手动发送还会插到它们前面。
            prompts = dequeued(queue.takeNextTurn())
            turn = UUID()
        }
        inflightTask = nil
        currentTurnID = nil
    }

    /// 停掉当前这一轮，会话留在可以接着聊的状态（见类型注释「取消时结算」）。
    /// 排队消息一并清空：用户要的是停下来，不是停完这一轮再自动开下一轮。
    public func cancel() {
        abandonInflightTurn()
        settleUnansweredToolCalls()
        clearQueue()
        clearStreaming()
        state = .idle
    }

    /// 新对话：清空一切，审批门的本会话放行列表一并清掉。
    public func reset() {
        abandonInflightTurn()
        runningToolCallID = nil
        messageIDs.removeAll()
        messages.removeAll()
        userDisplayOverrides.removeAll()
        state = .idle
        lastUsage = nil
        thinkingReplay.removeAll()
        clearQueue()
        clearStreaming()
        resetGate()
    }

    /// 从聊天记录恢复会话内容。记录可能停在「assistant 发起了调用、结果还没写」的地方
    /// （应用退出 / 崩溃）：补上「中断」结果，否则接着聊的第一轮就会被拒。
    public func restore(messages restored: [AgentMessage], displayOverrides: [Int: String] = [:]) {
        abandonInflightTurn()
        clearQueue()
        clearStreaming()
        runningToolCallID = nil
        thinkingReplay.removeAll()
        messageIDs = restored.map { _ in UUID() }
        messages = restored
        userDisplayOverrides = displayOverrides
        state = .idle
        resetGate()
        settleUnansweredToolCalls(otherwise: Self.interruptedBeforeRestore, record: false)
    }

    /// 等在途的一轮结束（测试用）。
    public func waitUntilIdle() async {
        while let task = inflightTask {
            await task.value
            if inflightTask == task { break }
        }
    }

    // MARK: - 私有：所有权与队列

    private struct Prompt {
        let text: String
        let display: String?
    }

    private func dequeued(_ items: [AgentQueuedMessage]) -> [Prompt] {
        items.map { Prompt(text: $0.text, display: queuedDisplayOverrides.removeValue(forKey: $0.id)) }
    }

    private func clearQueue() {
        queue.removeAll()
        queuedDisplayOverrides.removeAll()
    }

    private func abandonInflightTurn() {
        inflightTask?.cancel()
        inflightTask = nil
        currentTurnID = nil
    }

    private func owns(_ turnID: UUID) -> Bool { currentTurnID == turnID }

    private func resetGate() {
        let gate = approvalGate
        let previous = gateReset
        gateReset = Task {
            await previous?.value
            await gate.resetSession()
        }
    }

    /// 给末尾那条 assistant 消息里还没有结果的 tool call 各补一条说明。只看会话尾部：
    /// 从后往前遇到 user 消息就停 —— 更早的历史不在这里动。
    private func settleUnansweredToolCalls(otherwise notRunning: String = AgentRuntimeSessionText.cancelledBeforeRunning,
                                           record: Bool = true) {
        let interrupted = runningToolCallID
        runningToolCallID = nil
        var answered: Set<String> = []
        var pending: [AgentToolCall] = []
        scan: for message in messages.reversed() {
            switch message {
            case .toolResult(let id, _, _):
                answered.insert(id)
            case .assistant(_, let calls):
                pending = calls.filter { !answered.contains($0.id) }
                break scan
            case .user, .system:
                break scan
            }
        }
        for call in pending {
            let content = call.id == interrupted ? Self.cancelledWhileRunning : notRunning
            append(.toolResult(toolCallID: call.id, content: content, isError: true), record: record)
        }
    }

    /// 统一的消息落点：进内存数组 + 展示别名 + 写穿记录。
    private func append(_ message: AgentMessage, display: String? = nil, record: Bool = true) {
        messageIDs.append(UUID())
        messages.append(message)
        if let display { userDisplayOverrides[messages.count - 1] = display }
        if record { recorder?(message, display) }
    }

    // MARK: - 私有：流式文字

    private func receiveText(_ delta: String, turnID: UUID) {
        guard owns(turnID) else { return }
        streamingBuffer += delta
        if state == .sending { state = .streaming }
        let now = ContinuousClock.now
        if let last = lastStreamingPublish, now - last < Self.streamingPublishInterval { return }
        lastStreamingPublish = now
        streamingText = streamingBuffer
    }

    private func clearStreaming() {
        streamingBuffer = ""
        lastStreamingPublish = nil
        streamingText = nil
    }

    // MARK: - 私有：循环

    private func runLoop(turnID: UUID) async {
        var iterations = 0
        while iterations < maxIterations {
            iterations += 1
            guard owns(turnID) else { return }

            let step = await environment.prepareStep()
            guard owns(turnID) else { return }
            let schemas = await tools.allSchemas()
            guard owns(turnID) else { return }

            // 出站压缩副本：内存 messages / 聊天记录始终保留全文。
            let outbound = contextPolicy.map { AgentContextCompressor.compress(messages, policy: $0) } ?? messages
            let request = AgentChatRequest(
                model: model,
                messages: [.system(step.systemPrompt)] + outbound,
                tools: schemas,
                toolChoice: .auto,
                temperature: temperature,
                maxTokens: nil,
                reasoning: reasoningProvider?(),
                thinkingReplay: thinkingReplay)

            state = .sending
            clearStreaming()
            let response: AgentChatResponse
            do {
                response = try await AgentReplyCollector.collect(provider, request) { [weak self] delta in
                    self?.receiveText(delta, turnID: turnID)
                }
            } catch {
                // 被收回所有权后 provider 抛什么都不关这一轮的事（多半就是取消）。
                guard owns(turnID) else { return }
                clearStreaming()
                if error is CancellationError {
                    state = .idle
                } else {
                    if let partial = error as? AgentPartialReplyFailure { appendPartialReply(partial) }
                    state = .error(LLMErrorText.describe(error))
                }
                return
            }
            guard owns(turnID) else { return }
            clearStreaming()
            if let usage = response.usage { lastUsage = usage }

            append(response.message)
            let calls = response.toolCalls
            if let first = calls.first, !response.thinking.isEmpty {
                thinkingReplay[first.id] = response.thinking
            }

            guard !calls.isEmpty else {
                state = .idle
                return
            }
            for call in calls {
                guard owns(turnID) else { return }
                await dispatch(call, context: step.toolContext, turnID: turnID)
            }
            guard owns(turnID) else { return }
            deliverNextStepMessages()
        }
        guard owns(turnID) else { return }
        state = .error(Self.iterationLimitMessage(maxIterations))
    }

    /// 回复说到一半就失败了：已经收到的文字留在对话里，末尾注明原因。已经收齐的工具调用不执行、
    /// 也不进历史（带着 tool_use 却没有结果的消息会让下一次请求被拒），只在注记里交代个数。
    private func appendPartialReply(_ failure: AgentPartialReplyFailure) {
        var note = "[错误：\(failure)"
        if failure.abandonedToolCalls > 0 {
            note += "；模型发起的 \(failure.abandonedToolCalls) 个工具调用没有执行"
        }
        note += "]"
        let text = failure.text.map { $0 + "\n\n" + note } ?? note
        append(.assistant(content: text, toolCalls: []))
    }

    /// 一步结束、下一次请求之前：把标成「下一步送达」的排队消息并进会话。这不是新一轮，
    /// `thinkingReplay` 不清。
    private func deliverNextStepMessages() {
        for prompt in dequeued(queue.takeNextStep()) {
            append(.user(prompt.text), display: prompt.display)
        }
    }

    // MARK: - 私有：工具派发

    private func dispatch(_ call: AgentToolCall, context: Context, turnID: UUID) async {
        state = .runningTool(name: call.name)
        let registered = await tools.tool(named: call.name)
        guard owns(turnID) else { return }
        guard let tool = registered else {
            let content = Self.unknownTool(call.name)
            append(.toolResult(toolCallID: call.id, content: content, isError: true))
            audit(call, approval: nil, isError: true, length: content.utf8.count)
            return
        }

        var approval: AgentAuditEntry.Approval = .notRequired
        let requirement = tool.approvalRequirement(arguments: call.arguments)
        if requirement != .none {
            let request: AgentApprovalRequest
            var askUser = true
            switch requirement {
            case .none:
                return
            case .ask(let subject):
                request = AgentApprovalRequest(toolCallID: call.id, toolName: call.name,
                                               arguments: call.arguments, subject: subject)
            case .alwaysManual:
                request = AgentApprovalRequest(toolCallID: call.id, toolName: call.name,
                                               arguments: call.arguments, allowsSessionGrant: false)
            }
            var gated = request
            if case .ask = requirement {
                state = .reviewingTool(name: call.name)
                let verdict = await approvalPolicy.evaluate(request)
                guard owns(turnID) else { return }
                switch verdict {
                case .allow:
                    approval = .policy
                    askUser = false
                case .deny(let reason):
                    let content = Self.policyDenied(reason)
                    append(.toolResult(toolCallID: call.id, content: content, isError: true))
                    audit(call, approval: .policyDenied, isError: true, length: content.utf8.count)
                    return
                case .askUser(let note):
                    gated = request.with(policyNote: note)
                }
            }
            if askUser {
                state = .waitingForApproval(toolName: call.name)
                let decision = await approvalGate.request(gated)
                // 等审批期间整轮被取消：gate 已按拒绝收场，这条调用的结果由取消方补
                // （或消息已被 reset 清空），别再写 user_denied。
                guard owns(turnID) else { return }
                if decision == .denied {
                    append(.toolResult(toolCallID: call.id, content: Self.userDenied, isError: true))
                    audit(call, approval: .userDenied, isError: true, length: Self.userDenied.utf8.count)
                    return
                }
                approval = .user
            }
        }

        state = .runningTool(name: call.name)
        runningToolCallID = call.id
        let result: AgentToolResult
        do {
            result = try await tool.run(arguments: call.arguments, context: context)
        } catch {
            result = AgentToolResult(content: "Error: \(LLMErrorText.describeToolError(error))", isError: true)
        }
        // 工具跑完时这一轮可能已经被停掉：会话里那条结果已由取消方补上，这里不再写第二条。
        // 审计日志照记 —— 工具确实跑过了。
        if owns(turnID) {
            runningToolCallID = nil
            append(.toolResult(toolCallID: call.id, content: result.content, isError: result.isError))
        }
        audit(call, approval: approval, isError: result.isError, length: result.content.utf8.count)
    }

    private func audit(_ call: AgentToolCall, approval: AgentAuditEntry.Approval?, isError: Bool, length: Int) {
        auditLog?.append(AgentAuditEntry(tool: call.name, arguments: call.arguments, approval: approval,
                                         isError: isError, contentLength: length))
    }
}

/// 非泛型的文案入口（泛型类型的静态成员不能作缺省参数值）。
enum AgentRuntimeSessionText {
    static let cancelledBeforeRunning =
        "cancelled_by_user: the user stopped this turn before the tool ran; it was not executed."
}

/// 错误 → 给人看的一句话。
enum LLMErrorText {
    static func describe(_ error: Error) -> String {
        if let partial = error as? AgentPartialReplyFailure { return partial.description }
        return LLMServiceError.describe(error)
    }

    /// 工具自己抛的错交回模型：原样的说明，不套模型服务的文案。
    static func describeToolError(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
