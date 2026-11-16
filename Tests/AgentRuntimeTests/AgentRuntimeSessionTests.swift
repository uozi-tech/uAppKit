import AgentKit
import AgentProviders
import XCTest
@testable import AgentRuntime

/// agent 循环：工具续轮、审批各条路径、取消时机、排队两种投递、迭代上限、恢复、
/// 半截回复、回退、压缩只作用于出站副本、thinking 回放。
@MainActor
final class AgentRuntimeSessionTests: XCTestCase {

    // MARK: - 工具循环

    func testToolLoopRunsToolFeedsResultBackAndStops() async {
        let log = RunLog()
        let provider = ScriptedProvider([
            .reply(.text("先看看"), call("c1", "echo", #"{"q":1}"#)),
            .reply(.text("完成")),
        ])
        let session = makeSession(provider, tools: [EchoTool(log: log)])
        var recorded: [AgentMessage] = []
        session.recorder = { message, _ in recorded.append(message) }

        await session.submit("你好")

        XCTAssertEqual(session.messages, [
            .user("你好"),
            .assistant(content: "先看看", toolCalls: [AgentToolCall(id: "c1", name: "echo", arguments: #"{"q":1}"#)]),
            .toolResult(toolCallID: "c1", content: #"echo[ctx]:{"q":1}"#, isError: false),
            .assistant(content: "完成", toolCalls: []),
        ])
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.isBusy)
        XCTAssertEqual(session.messageIDs.count, session.messages.count)
        XCTAssertEqual(recorded, session.messages, "每条会话消息都经 recorder 写穿，system 不写")

        let requests = provider.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].messages.first, .system("SYSTEM"))
        XCTAssertEqual(requests[0].tools.map(\.name), ["echo"])
        XCTAssertEqual(requests[1].messages.last,
                       .toolResult(toolCallID: "c1", content: #"echo[ctx]:{"q":1}"#, isError: false))
        let runs = await log.runs
        XCTAssertEqual(runs, [#"echo {"q":1}"#])
    }

    func testUnknownToolAndThrowingToolBecomeErrorResults() async {
        let provider = ScriptedProvider([
            .reply(call("c1", "missing"), call("c2", "fail")),
            .reply(.text("ok")),
        ])
        let session = makeSession(provider, tools: [FailingTool()])
        await session.submit("go")
        XCTAssertEqual(session.messages[2], .toolResult(toolCallID: "c1", content: "Error: unknown tool missing", isError: true))
        XCTAssertEqual(session.messages[3], .toolResult(toolCallID: "c2", content: "Error: 炸了", isError: true))
    }

    func testEmptyModelFailsWithoutRequest() async {
        let provider = ScriptedProvider([])
        let session = AgentRuntimeSession(
            provider: provider, model: "", tools: AgentToolRegistry<TestContext>(),
            environment: .fixed(systemPrompt: "", toolContext: TestContext(label: "")),
            approvalGate: AutoDenyApprovalGate())
        await session.submit("hi")
        XCTAssertEqual(session.state, .error(AgentRuntimeSession<TestContext>.noModelMessage))
        XCTAssertTrue(provider.requests.isEmpty)
    }

    // MARK: - 审批

    func testDeniedApprovalWritesUserDeniedAndSkipsTool() async {
        let log = RunLog()
        let gate = ScriptedGate([.denied])
        let provider = ScriptedProvider([
            .reply(call("c1", "write", #"{"sql":"DELETE FROM t","reason":"清理"}"#)),
            .reply(.text("好的")),
        ])
        let session = makeSession(provider, tools: [WriteTool(log: log)], gate: gate)
        await session.submit("删")
        XCTAssertEqual(session.messages[2], .toolResult(toolCallID: "c1", content: "user_denied", isError: true))
        let runs = await log.runs
        XCTAssertTrue(runs.isEmpty)
        let requests = await gate.requests
        XCTAssertEqual(requests.first?.subject, "DELETE FROM t")
        XCTAssertEqual(requests.first?.reason, "清理")
        XCTAssertEqual(requests.first?.allowsSessionGrant, true)
    }

    func testInteractiveGateSessionGrantIsExactAndClearedOnReset() async {
        let log = RunLog()
        var presented: [AgentApprovalRequest] = []
        var answers: [ApprovalDecision] = [.grantedForSession, .granted, .granted]
        let gate = InteractiveApprovalGate { request in
            presented.append(request)
            return answers.removeFirst()
        }
        let sql = #"{"sql":"UPDATE t SET a=1"}"#
        let provider = ScriptedProvider([
            .reply(call("c1", "write", sql)), .reply(.text("1")),
            .reply(call("c2", "write", sql)), .reply(.text("2")),               // 精确相同：不再问
            .reply(call("c3", "write", #"{"sql":"UPDATE t SET a=2"}"#)), .reply(.text("3")), // 改了字面量：要问
            .reply(call("c4", "write", sql)), .reply(.text("4")),               // reset 之后：要问
        ])
        let session = makeSession(provider, tools: [WriteTool(log: log)], gate: gate)
        await session.submit("a")
        await session.submit("b")
        XCTAssertEqual(presented.count, 1)
        await session.submit("c")
        XCTAssertEqual(presented.count, 2)
        session.reset()
        await session.submit("d")
        XCTAssertEqual(presented.count, 3, "新对话清掉本会话放行列表")
        let runs = await log.runs
        XCTAssertEqual(runs.count, 4)
    }

    func testAlwaysManualSkipsPolicyAndNeverAcceptsSessionGrant() async {
        let log = RunLog()
        var presented: [AgentApprovalRequest] = []
        let gate = InteractiveApprovalGate { request in
            presented.append(request)
            return .grantedForSession
        }
        let provider = ScriptedProvider([
            .reply(call("c1", "drop")), .reply(.text("1")),
            .reply(call("c2", "drop")), .reply(.text("2")),
        ])
        let session = makeSession(provider, tools: [DropTool(log: log)], gate: gate,
                                  policy: FixedPolicy(verdict: .allow(reason: "策略放行")))
        await session.submit("a")
        await session.submit("b")
        XCTAssertEqual(presented.count, 2, "每次都问；策略的放行不作用于 alwaysManual")
        XCTAssertEqual(presented.first?.allowsSessionGrant, false)
        let count = await gate.sessionAllowListCount
        XCTAssertEqual(count, 0)
    }

    func testPolicyAllowSkipsGateAndPolicyDenyIsReportedToModel() async {
        let log = RunLog()
        let gate = ScriptedGate([])
        let allow = ScriptedProvider([.reply(call("c1", "write", #"{"sql":"SELECT 1"}"#)), .reply(.text("ok"))])
        let allowed = makeSession(allow, tools: [WriteTool(log: log)], gate: gate,
                                  policy: FixedPolicy(verdict: .allow(reason: "只读")))
        await allowed.submit("x")
        XCTAssertEqual(allowed.messages[2], .toolResult(toolCallID: "c1", content: "ok", isError: false))
        let asked = await gate.requests
        XCTAssertTrue(asked.isEmpty)

        let deny = ScriptedProvider([.reply(call("c1", "write", "{}")), .reply(.text("ok"))])
        let denied = makeSession(deny, tools: [WriteTool(log: log)], gate: gate,
                                 policy: FixedPolicy(verdict: .deny(reason: "只读模式")))
        await denied.submit("x")
        XCTAssertEqual(denied.messages[2], .toolResult(toolCallID: "c1", content: "policy_denied: 只读模式", isError: true))
    }

    func testPolicyAskUserNoteReachesGate() async {
        let gate = ScriptedGate([.granted])
        let provider = ScriptedProvider([.reply(call("c1", "write", "{}")), .reply(.text("ok"))])
        let session = makeSession(provider, tools: [WriteTool(log: RunLog())], gate: gate,
                                  policy: FixedPolicy(verdict: .askUser(note: "不是只读命令")))
        await session.submit("x")
        let requests = await gate.requests
        XCTAssertEqual(requests.first?.policyNote, "不是只读命令")
    }

    func testApprovalQueueDrivesInteractiveGate() async {
        let queue = AgentApprovalQueue()
        let gate = InteractiveApprovalGate(presenter: queue.presenter)
        let provider = ScriptedProvider([.reply(call("c1", "write", #"{"sql":"X"}"#)), .reply(.text("ok"))])
        let session = makeSession(provider, tools: [WriteTool(log: RunLog())], gate: gate)
        let turn = Task { await session.submit("go") }
        await waitUntil { queue.pending != nil }
        XCTAssertEqual(session.state, .waitingForApproval(toolName: "write"))
        XCTAssertEqual(queue.pending?.request.displayText, "X")
        queue.decide(.granted, for: queue.pending!.id)
        await turn.value
        XCTAssertEqual(session.messages[2], .toolResult(toolCallID: "c1", content: "ok", isError: false))
        XCTAssertNil(queue.pending)
    }

    // MARK: - 取消

    func testCancelMidToolSettlesAsMayHaveRunAndLateResultIsDropped() async {
        let log = RunLog()
        let latch = Latch()
        let provider = ScriptedProvider([.reply(.text("跑"), call("c1", "slow"), call("c2", "echo"))])
        let session = makeSession(provider, tools: [SlowTool(log: log, latch: latch), EchoTool(log: log)])
        var recorded: [AgentMessage] = []
        session.recorder = { message, _ in recorded.append(message) }
        let turn = Task { await session.submit("go") }
        await waitUntil { session.runningToolCallID == "c1" }

        session.cancel()
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.isBusy)
        XCTAssertEqual(Array(session.messages.suffix(2)), [
            .toolResult(toolCallID: "c1", content: AgentRuntimeSession<TestContext>.cancelledWhileRunning, isError: true),
            .toolResult(toolCallID: "c2", content: AgentRuntimeSession<TestContext>.cancelledBeforeRunning, isError: true),
        ])
        await latch.open()
        await turn.value
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(session.messages.count, 4, "工具晚一拍回来也写不进来")
        XCTAssertEqual(recorded.count, 4, "取消补的结果同样写穿")
        let runs = await log.runs
        XCTAssertFalse(runs.contains { $0.hasPrefix("echo") }, "没轮到的调用不执行")
    }

    func testCancelWhileWaitingForApprovalDeniesPendingAndSettles() async {
        let queue = AgentApprovalQueue()
        let gate = InteractiveApprovalGate(presenter: queue.presenter)
        let provider = ScriptedProvider([.reply(call("c1", "write", "{}"))])
        let session = makeSession(provider, tools: [WriteTool(log: RunLog())], gate: gate)
        let turn = Task { await session.submit("go") }
        await waitUntil { queue.pending != nil }
        session.cancel()
        await turn.value
        await waitUntil { queue.pending == nil }
        XCTAssertEqual(session.messages.last,
                       .toolResult(toolCallID: "c1", content: AgentRuntimeSession<TestContext>.cancelledBeforeRunning,
                                   isError: true))
        XCTAssertFalse(session.messages.contains(.toolResult(toolCallID: "c1", content: "user_denied", isError: true)))
    }

    func testCancelWhileStreamingKeepsSessionUsable() async {
        let latch = Latch()
        let provider = ScriptedProvider([.reply(.text("never"), latch: latch), .reply(.text("second"))])
        let session = makeSession(provider, tools: [])
        let turn = Task { await session.submit("first") }
        await waitUntil { session.state == .sending }
        session.cancel()
        await turn.value
        XCTAssertEqual(session.messages, [.user("first")])
        await session.submit("again")
        XCTAssertEqual(session.messages.last, .assistant(content: "second", toolCalls: []))
    }

    // MARK: - 排队

    func testAfterTurnQueueStartsNewTurnsInOrder() async {
        let latch = Latch()
        let provider = ScriptedProvider([
            .reply(.text("one"), latch: latch),
            .reply(.text("two")),
            .reply(.text("three")),
        ])
        let session = makeSession(provider, tools: [])
        let turn = Task { await session.submit("first") }
        await waitUntil { session.isBusy && session.state == .sending }
        await session.submit("second", displayAs: "/2")
        await session.submit("third")
        XCTAssertEqual(session.queuedMessages.map(\.text), ["second", "third"])
        await latch.open()
        await turn.value
        XCTAssertEqual(session.messages, [
            .user("first"), .assistant(content: "one", toolCalls: []),
            .user("second"), .assistant(content: "two", toolCalls: []),
            .user("third"), .assistant(content: "three", toolCalls: []),
        ])
        XCTAssertEqual(session.userDisplayOverrides[2], "/2")
        XCTAssertTrue(session.queuedMessages.isEmpty)
    }

    func testNextStepMessageJoinsAfterToolResultsWithoutNewTurn() async {
        let latch = Latch()
        let log = RunLog()
        let provider = ScriptedProvider([
            .reply(call("c1", "slow")),
            .reply(.text("看到了")),
        ])
        let session = makeSession(provider, tools: [SlowTool(log: log, latch: latch)])
        let turn = Task { await session.submit("go") }
        await waitUntil { session.runningToolCallID == "c1" }
        await session.submit("顺便看下这个", delivery: .nextStep)
        await latch.open()
        await turn.value
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertEqual(Array(provider.requests[1].messages.suffix(2)), [
            .toolResult(toolCallID: "c1", content: "slow done", isError: false),
            .user("顺便看下这个"),
        ])
    }

    func testQueueEditingAndPromotion() async {
        let latch = Latch()
        let provider = ScriptedProvider([.reply(.text("x"), latch: latch)], repeatsLast: false)
        let session = makeSession(provider, tools: [])
        let turn = Task { await session.submit("first") }
        await waitUntil { session.isBusy }
        await session.submit("a", displayAs: "/a")
        await session.submit("b")
        let a = session.queuedMessages[0].id, b = session.queuedMessages[1].id
        session.sendQueuedAtNextStep(id: b)
        XCTAssertEqual(session.queuedMessages.map(\.text), ["b", "a"])
        XCTAssertEqual(session.takeQueuedForEditing(id: a), "/a", "交还用户敲的原文")
        session.removeQueued(id: b)
        XCTAssertTrue(session.queuedMessages.isEmpty)
        session.cancel()
        await latch.open()
        await turn.value
    }

    // MARK: - 上限 / 恢复 / 失败

    func testIterationCapStopsRunawayToolLoop() async {
        let provider = ScriptedProvider([.reply(call("c", "echo"))], repeatsLast: true)
        let session = makeSession(provider, tools: [EchoTool(log: RunLog())], maxIterations: 3)
        await session.submit("loop")
        XCTAssertEqual(provider.requests.count, 3)
        XCTAssertEqual(session.state, .error(AgentRuntimeSession<TestContext>.iterationLimitMessage(3)))
    }

    func testRestoreMarksInterruptedCallsWithoutRecording() async {
        let provider = ScriptedProvider([.reply(.text("继续"))])
        let gate = ScriptedGate([])
        let session = makeSession(provider, tools: [], gate: gate)
        var recorded: [AgentMessage] = []
        session.recorder = { message, _ in recorded.append(message) }
        session.restore(messages: [
            .user("hi"),
            .assistant(content: nil, toolCalls: [AgentToolCall(id: "a", name: "echo", arguments: "{}"),
                                                  AgentToolCall(id: "b", name: "echo", arguments: "{}")]),
            .toolResult(toolCallID: "a", content: "done", isError: false),
        ], displayOverrides: [0: "/hi"])
        XCTAssertEqual(session.messages.last,
                       .toolResult(toolCallID: "b", content: AgentRuntimeSession<TestContext>.interruptedBeforeRestore,
                                   isError: true))
        XCTAssertEqual(session.userDisplayOverrides, [0: "/hi"])
        XCTAssertTrue(recorded.isEmpty, "恢复补的结果不写回记录（记录里本来就没有）")
        await session.submit("next")
        let resets = await gate.resets
        XCTAssertEqual(resets, 1, "恢复历史同样清本会话放行列表")
    }

    func testPartialReplyKeepsTextAndAbandonsToolCalls() async {
        let provider = ScriptedProvider([
            .reply(.text("写到一半"), call("c1", "echo"), error: LLMServiceError.incompleteStream),
        ])
        let log = RunLog()
        let session = makeSession(provider, tools: [EchoTool(log: log)])
        await session.submit("go")
        XCTAssertEqual(session.messages.last,
                       .assistant(content: "写到一半\n\n[错误：连接中途断开，回复不完整；模型发起的 1 个工具调用没有执行]",
                                  toolCalls: []))
        XCTAssertEqual(session.state, .error("连接中途断开，回复不完整"))
        let runs = await log.runs
        XCTAssertTrue(runs.isEmpty)
    }

    func testStreamFailureBeforeAnyEventFallsBackToChat() async {
        let provider = ScriptedProvider([.reply(error: LLMServiceError.network("建流失败"))])
        provider.chatResponse = AgentChatResponse(message: .assistant(content: "非流式", toolCalls: []),
                                                  finishReason: .stop,
                                                  usage: LLMUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3))
        let session = makeSession(provider, tools: [])
        await session.submit("go")
        XCTAssertEqual(session.messages.last, .assistant(content: "非流式", toolCalls: []))
        XCTAssertEqual(session.lastUsage?.totalTokens, 3)

        // 「流已开始的结论」不回退。
        let verdict = ScriptedProvider([.reply(error: LLMServiceError.streamIdleTimeout)])
        verdict.chatResponse = provider.chatResponse
        let s2 = makeSession(verdict, tools: [])
        await s2.submit("go")
        XCTAssertEqual(verdict.chatCalls, 0)
        XCTAssertEqual(s2.state, .error(LLMServiceError.streamIdleTimeout.description))
    }

    // MARK: - 压缩 / thinking / 流式文字

    func testCompressionTouchesOnlyTheOutboundCopy() async {
        let huge = String(repeating: "x", count: 20_000)
        let provider = ScriptedProvider([.reply(.text("ok"))])
        let session = makeSession(provider, tools: [],
                                  contextPolicy: AgentContextCompressor.Policy(tokenBudget: 1_000, keptRecentMessages: 2,
                                                                                foldedToolResultCap: 50,
                                                                                foldedTextCap: 50))
        session.restore(messages: [
            .user("old"),
            .assistant(content: nil, toolCalls: [AgentToolCall(id: "t", name: "echo", arguments: "{}")]),
            .toolResult(toolCallID: "t", content: huge, isError: false),
            .assistant(content: "done", toolCalls: []),
            .user("mid"),
            .assistant(content: "mid answer", toolCalls: []),
        ])
        await session.submit("new question")
        XCTAssertEqual(session.messages[2], .toolResult(toolCallID: "t", content: huge, isError: false),
                       "内存里保留全文")
        let outbound = provider.requests[0].messages
        let sentBytes = outbound.reduce(0) { $0 + $1.payloadByteCount }
        XCTAssertLessThan(sentBytes, 5_000, "发出去的是压缩后的副本")
        XCTAssertEqual(outbound.last, .user("new question"))
    }

    func testThinkingIsReplayedWithinTurnOnly() async {
        let block = LLMThinkingBlock(thinking: "想", signature: "sig")
        let provider = ScriptedProvider([
            .reply(.thinking(block), call("c1", "echo")),
            .reply(.text("ok")),
            .reply(.text("next turn")),
        ])
        let session = makeSession(provider, tools: [EchoTool(log: RunLog())])
        await session.submit("a")
        XCTAssertEqual(provider.requests[1].thinkingReplay["c1"], [block])
        await session.submit("b")
        XCTAssertTrue(provider.requests[2].thinkingReplay.isEmpty, "跨轮不回传")
    }

    func testStreamingTextIsPublishedWhileStreamingAndClearedAfter() async {
        let latch = Latch()
        final class Provider: AgentLLMProvider, @unchecked Sendable {
            let latch: Latch
            init(latch: Latch) { self.latch = latch }
            func stream(_ request: AgentChatRequest) -> AsyncThrowingStream<LLMEvent, Error> {
                AsyncThrowingStream { continuation in
                    Task {
                        continuation.yield(.text("半句"))
                        await self.latch.wait()
                        continuation.yield(.text("话"))
                        continuation.finish()
                    }
                }
            }
        }
        let session = AgentRuntimeSession(
            provider: Provider(latch: latch), model: "m", tools: AgentToolRegistry<TestContext>(),
            environment: .fixed(systemPrompt: "", toolContext: TestContext(label: "")),
            approvalGate: AutoDenyApprovalGate())
        let turn = Task { await session.submit("go") }
        await waitUntil { session.streamingText == "半句" }
        XCTAssertEqual(session.state, .streaming)
        await latch.open()
        await turn.value
        XCTAssertNil(session.streamingText)
        XCTAssertEqual(session.messages.last, .assistant(content: "半句话", toolCalls: []))
    }

    // MARK: - 审计

    func testAuditLogWritesOneJSONLinePerDispatch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString)/a.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = AgentAuditLog(url: url)
        let provider = ScriptedProvider([
            .reply(call("c1", "echo"), call("c2", "write", "{}")),
            .reply(.text("ok")),
        ])
        let session = makeSession(provider, tools: [EchoTool(log: RunLog()), WriteTool(log: RunLog())],
                                  gate: ScriptedGate([.denied]), auditLog: log)
        await session.submit("go")
        await log.flush()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        let second = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any]
        XCTAssertEqual(first?["tool"] as? String, "echo")
        XCTAssertNil(first?["approved"])
        XCTAssertEqual(first?["approval"] as? String, "not_required")
        XCTAssertEqual(second?["approved"] as? Bool, false)
        XCTAssertEqual(second?["approval"] as? String, "user_denied")
    }
}
