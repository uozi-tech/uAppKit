import AgentKit
import AgentProviders
import SwiftData
import XCTest
@testable import AgentRuntime

/// 会话生命周期的边角：重置 / 恢复与审批门清理的先后、恢复时清掉旧用量、没选模型时不收消息、
/// 面板行缓存的修订号，以及聊天记录的删除结果与「最后一条」的取法。
@MainActor
final class AgentRuntimeSessionLifecycleTests: XCTestCase {

    // MARK: - 审批门清理

    /// 第 n 次 `resetSession` 等第 n 个闸门打开才返回。
    actor LatchedResetGate: ApprovalGate {
        private let latches: [Latch]
        private(set) var started = 0
        private(set) var finished = 0

        init(_ latches: [Latch]) {
            self.latches = latches
        }

        func request(_ request: AgentApprovalRequest) async -> ApprovalDecision { .denied }

        func resetSession() async {
            let index = started
            started += 1
            if index < latches.count { await latches[index].wait() }
            finished += 1
        }
    }

    /// `send` 在等上一次清理时，`reset()` 又排了一次：等完的那次不能把新排的一并丢掉，
    /// 否则下一轮不等它就开跑，旧对话的放行列表还没清就进了新对话。
    func testSendDoesNotDropAResetQueuedWhileItWaited() async {
        let first = Latch()
        let second = Latch()
        let gate = LatchedResetGate([first, second])
        let provider = ScriptedProvider([.reply(.text("二"))])
        let session = makeSession(provider, tools: [], gate: gate)

        session.restore(messages: [])                       // 清理 #1，等 first
        let abandoned = Task { await session.send(userMessage: "一") }
        await waitUntil { session.isBusy }
        session.reset()                                     // 清理 #2：排在 #1 之后，等 second
        await first.open()
        await abandoned.value                               // 被 reset 收回所有权，没有发请求
        XCTAssertTrue(provider.requests.isEmpty)

        let next = Task { await session.submit("二") }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(provider.requests.isEmpty, "第二次清理还没做完，新一轮不该发出请求")

        await second.open()
        await next.value
        XCTAssertEqual(provider.requests.count, 1)
        let finished = await gate.finished
        XCTAssertEqual(finished, 2)
        XCTAssertEqual(session.messages, [.user("二"), .assistant(content: "二", toolCalls: [])])
    }

    // MARK: - 恢复

    func testRestoreClearsLastUsageLikeReset() async {
        let provider = ScriptedProvider([.reply(error: LLMServiceError.network("建流失败"))])
        provider.chatResponse = AgentChatResponse(message: .assistant(content: "非流式", toolCalls: []),
                                                  finishReason: .stop,
                                                  usage: LLMUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3))
        let session = makeSession(provider, tools: [])
        await session.submit("go")
        XCTAssertEqual(session.lastUsage?.totalTokens, 3)

        session.restore(messages: [.user("旧对话"), .assistant(content: "旧回复", toolCalls: [])])
        XCTAssertNil(session.lastUsage, "恢复的是另一段对话，上一段的用量不该还挂着")
    }

    // MARK: - 没选模型

    func testCanSubmitRequiresAModel() async {
        let empty = AgentRuntimeSession(
            provider: ScriptedProvider([]), model: "", tools: AgentToolRegistry<TestContext>(),
            environment: .fixed(systemPrompt: "", toolContext: TestContext(label: "")),
            approvalGate: AutoDenyApprovalGate())
        XCTAssertFalse(empty.canSubmit, "面板据此保留草稿：这条消息发不出去")
        await empty.submit("hi")
        XCTAssertTrue(empty.messages.isEmpty)

        let ready = makeSession(ScriptedProvider([.reply(.text("ok"))]), tools: [])
        XCTAssertTrue(ready.canSubmit)
    }

    // MARK: - 面板行缓存的修订号

    func testTranscriptRevisionTracksDisplayInputsOnly() async {
        let latch = Latch()
        let provider = ScriptedProvider([.reply(.text("慢慢说"), latch: latch)])
        let session = makeSession(provider, tools: [])
        let initial = session.transcriptRevision

        let turn = Task { await session.submit("hi") }
        await waitUntil { session.messages.count == 1 }
        let afterUser = session.transcriptRevision
        XCTAssertGreaterThan(afterUser, initial, "追加消息（含 append 这种原地修改）要让缓存失效")

        await latch.open()
        await turn.value
        XCTAssertGreaterThan(session.transcriptRevision, afterUser)

        let settled = session.transcriptRevision
        session.cancel()   // 只动状态 / 流式文字，没有消息可结算
        XCTAssertEqual(session.transcriptRevision, settled, "状态变化不让面板行缓存失效")

        session.restore(messages: [.user("x")], displayOverrides: [0: "/x"])
        XCTAssertGreaterThan(session.transcriptRevision, settled)
    }

    // MARK: - 聊天记录

    private func makeContext() throws -> ModelContext {
        let schema = Schema([ChatSession.self, ChatMessageRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: schema, configurations: configuration))
    }

    func testChatStoreDeleteReportsSuccess() throws {
        let store = AgentChatStore(context: try makeContext())
        store.record(.user("hi"), display: nil, scopeID: nil)
        let session = try XCTUnwrap(store.currentSession)
        XCTAssertNil(store.delete(session))
        XCTAssertTrue(store.sessions(scopeID: nil).isEmpty)
    }

    /// `lastMessage` / `preview` 一遍扫描，结果必须和排序后取最后一条一致（含同序号的并列）。
    func testLastMessageAndPreviewMatchSortedOrder() throws {
        let context = try makeContext()
        let session = ChatSession(title: "t")
        context.insert(session)
        let base = Date(timeIntervalSince1970: 1_000)
        let rows: [(String, String, Int, TimeInterval)] = [
            ("user", "早", 0, 0),
            ("assistant", "答", 1, 1),
            ("user", "并列甲", 2, 2),
            ("user", "并列乙", 2, 2),
            ("assistant", "最后", 3, 0),
            ("user", "序号小但时间晚", 1, 50),
        ]
        for (role, text, order, offset) in rows {
            let record = ChatMessageRecord(roleRaw: role, text: text, orderIndex: order,
                                           createdAt: base.addingTimeInterval(offset))
            record.session = session
            context.insert(record)
        }
        try context.save()

        XCTAssertEqual(session.lastMessage?.text, "最后")
        XCTAssertIdentical(session.lastMessage, session.orderedMessages.last)
        let lastUser = session.orderedMessages.last { $0.roleRaw == "user" }
        XCTAssertEqual(session.preview, lastUser?.text)
        XCTAssertTrue(["并列甲", "并列乙"].contains(session.preview))
    }

    func testSlashMatcherIgnoresDiacriticsInTitles() {
        let matcher = SlashCommandMatcher(commands: [
            SlashCommand(trigger: "cv", title: "Résumé"),
            SlashCommand(trigger: "other", title: "Other"),
        ])
        XCTAssertEqual(matcher.matches(for: "resume").map(\.trigger), ["cv"])
        XCTAssertEqual(matcher.matches(for: "RÉSU").map(\.trigger), ["cv"])
    }
}
