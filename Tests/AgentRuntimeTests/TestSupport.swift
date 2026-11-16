import AgentKit
import AgentProviders
import Foundation
import XCTest
@testable import AgentRuntime

/// 一次性闸门：`wait()` 挂起直到 `open()`；所在任务被取消时提前返回。
actor Latch {
    private var isOpen = false

    func open() { isOpen = true }

    func wait() async {
        while !isOpen, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// 脚本化的模型服务：每次 `stream` 按顺序取一步回放。记录收到的请求。
final class ScriptedProvider: AgentLLMProvider, @unchecked Sendable {
    struct Step {
        var events: [LLMEvent]
        var error: Error?
        /// 非 nil 时先等它打开再回放（模拟一直在吐 / 挂着的流）。
        var latch: Latch?

        static func reply(_ events: LLMEvent..., error: Error? = nil, latch: Latch? = nil) -> Step {
            Step(events: events, error: error, latch: latch)
        }
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var recorded: [AgentChatRequest] = []
    /// 用完之后一直重复最后一步。
    private let repeatsLast: Bool
    /// 非流式回退返回的回复；nil = 不支持（`.unimplemented`）。
    var chatResponse: AgentChatResponse?
    private(set) var chatCalls = 0

    init(_ steps: [Step], repeatsLast: Bool = false) {
        self.steps = steps
        self.repeatsLast = repeatsLast
    }

    var requests: [AgentChatRequest] { lock.withLock { recorded } }

    func stream(_ request: AgentChatRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let step: Step = lock.withLock {
            recorded.append(request)
            if steps.count > 1 || !repeatsLast { return steps.isEmpty ? .reply(.text("(脚本用完)")) : steps.removeFirst() }
            return steps[0]
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let latch = step.latch { await latch.wait() }
                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                for event in step.events { continuation.yield(event) }
                if let error = step.error { continuation.finish(throwing: error) } else { continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func chat(_ request: AgentChatRequest) async throws -> AgentChatResponse {
        let response: AgentChatResponse? = lock.withLock {
            chatCalls += 1
            return chatResponse
        }
        guard let response else { throw LLMServiceError.unimplemented }
        return response
    }
}

func call(_ id: String, _ name: String, _ arguments: String = "{}") -> LLMEvent {
    .toolCall(LLMToolCall(id: id, name: name, argumentsJSON: arguments))
}

struct TestContext: Sendable {
    var label: String
}

/// 记录工具实际被执行了几次。
actor RunLog {
    private(set) var runs: [String] = []
    func record(_ entry: String) { runs.append(entry) }
}

struct EchoTool: AgentTool {
    let log: RunLog
    var schema: AgentToolSchema { AgentToolSchema(name: "echo", description: "echo", parametersJSON: "{}") }

    func run(arguments: String, context: TestContext) async throws -> AgentToolResult {
        await log.record("echo \(arguments)")
        return AgentToolResult(content: "echo[\(context.label)]:\(arguments)")
    }
}

/// `.ask(subject: sql)`：按参数里的 `sql` 审批。
struct WriteTool: AgentTool {
    let log: RunLog
    var schema: AgentToolSchema { AgentToolSchema(name: "write", description: "write", parametersJSON: "{}") }

    func approvalRequirement(arguments: String) -> AgentToolApprovalRequirement {
        let sql = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any])?["sql"] as? String
        return .ask(subject: sql)
    }

    func run(arguments: String, context: TestContext) async throws -> AgentToolResult {
        await log.record("write \(arguments)")
        return AgentToolResult(content: "ok")
    }
}

struct DropTool: AgentTool {
    let log: RunLog
    var schema: AgentToolSchema { AgentToolSchema(name: "drop", description: "drop", parametersJSON: "{}") }
    func approvalRequirement(arguments: String) -> AgentToolApprovalRequirement { .alwaysManual }

    func run(arguments: String, context: TestContext) async throws -> AgentToolResult {
        await log.record("drop")
        return AgentToolResult(content: "dropped")
    }
}

/// 等闸门打开才返回的工具（取消时机测试用）。
struct SlowTool: AgentTool {
    let log: RunLog
    let latch: Latch
    var schema: AgentToolSchema { AgentToolSchema(name: "slow", description: "slow", parametersJSON: "{}") }

    func run(arguments: String, context: TestContext) async throws -> AgentToolResult {
        await log.record("slow-start")
        await latch.wait()
        await log.record("slow-end")
        return AgentToolResult(content: "slow done")
    }
}

struct FailingTool: AgentTool {
    struct Boom: Error, LocalizedError { var errorDescription: String? { "炸了" } }
    var schema: AgentToolSchema { AgentToolSchema(name: "fail", description: "fail", parametersJSON: "{}") }
    func run(arguments: String, context: TestContext) async throws -> AgentToolResult { throw Boom() }
}

/// 按脚本回答的审批门。
actor ScriptedGate: ApprovalGate {
    private var decisions: [ApprovalDecision]
    private(set) var requests: [AgentApprovalRequest] = []
    private(set) var resets = 0

    init(_ decisions: [ApprovalDecision]) {
        self.decisions = decisions
    }

    func request(_ request: AgentApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return decisions.isEmpty ? .denied : decisions.removeFirst()
    }

    func resetSession() async { resets += 1 }
}

struct FixedPolicy: AgentApprovalPolicy {
    let verdict: AgentApprovalVerdict
    func evaluate(_ request: AgentApprovalRequest) async -> AgentApprovalVerdict { verdict }
}

@MainActor
func makeSession(
    _ provider: ScriptedProvider,
    tools: [any AgentTool<TestContext>],
    gate: any ApprovalGate = AutoDenyApprovalGate(),
    policy: any AgentApprovalPolicy = AlwaysAskApprovalPolicy(),
    auditLog: AgentAuditLog? = nil,
    contextPolicy: AgentContextCompressor.Policy? = nil,
    maxIterations: Int = 16
) -> AgentRuntimeSession<TestContext> {
    AgentRuntimeSession(
        provider: provider, model: "test-model",
        tools: AgentToolRegistry(tools: tools),
        environment: .fixed(systemPrompt: "SYSTEM", toolContext: TestContext(label: "ctx")),
        approvalGate: gate, approvalPolicy: policy, auditLog: auditLog,
        contextPolicy: contextPolicy, maxIterations: maxIterations)
}

/// 轮询直到条件成立（最多 2 秒）。
@MainActor
func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition() {
        if ContinuousClock.now > deadline {
            XCTFail("等待超时", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}
