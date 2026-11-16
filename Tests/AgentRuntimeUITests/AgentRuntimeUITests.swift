import AgentKit
import AgentRuntime
import SwiftUI
import XCTest
@testable import AgentRuntimeUI
@testable import UDesignKit
#if os(macOS)
import AppKit
#endif

/// 会话 → 面板行的映射（工具结果并进发起它的 assistant 行、状态推导、展示别名），以及
/// 面板挂进真实窗口后的两条结构闸门：只挂载渲染窗口内的行；审批卡与流式文字出现在消息流末尾。
@MainActor
final class AgentRuntimeUITests: XCTestCase {
    private let ids = (0..<8).map { _ in UUID() }

    func testItemsFoldToolResultsIntoTheirCallsAndDeriveStatus() {
        let messages: [AgentMessage] = [
            .system("sys"),
            .user("expanded"),
            .assistant(content: "", toolCalls: [
                AgentToolCall(id: "a", name: "run_git", arguments: "{}"),
                AgentToolCall(id: "b", name: "run_git", arguments: "{}"),
                AgentToolCall(id: "c", name: "run_git", arguments: "{}"),
                AgentToolCall(id: "d", name: "run_git", arguments: "{}"),
            ]),
            .toolResult(toolCallID: "a", content: "ok", isError: false),
            .toolResult(toolCallID: "b", content: "boom", isError: true),
            .toolResult(toolCallID: "zzz", content: "orphan", isError: false),
            .assistant(content: nil, toolCalls: []),
            .assistant(content: "完成", toolCalls: []),
        ]
        let items = AgentTranscriptItems.make(messages: messages, messageIDs: ids,
                                              displayOverrides: [1: "/status"], runningToolCallID: "c")
        XCTAssertEqual(items.map(\.index), [1, 2, 5, 7], "system、空 assistant、已并入的结果不单独成行")
        XCTAssertEqual(items[0].kind, .user(text: "/status"))
        XCTAssertEqual(items[0].id, ids[1])
        guard case .assistant(let text, let calls) = items[1].kind else { return XCTFail() }
        XCTAssertNil(text, "空串按没有文字处理")
        XCTAssertEqual(calls.map(\.status), [.succeeded, .failed, .running, .pending])
        XCTAssertEqual(calls.map(\.result), ["ok", "boom", nil, nil])
        XCTAssertEqual(items[2].kind, .orphanToolResult(toolCallID: "zzz", content: "orphan", isError: false))
        XCTAssertEqual(items[3].kind, .assistant(text: "完成", toolCalls: []))
    }

    func testItemsTolerateIDCountMismatch() {
        let items = AgentTranscriptItems.make(messages: [.user("a"), .user("b")], messageIDs: [UUID()])
        XCTAssertEqual(items.count, 1)
    }

    func testDefaultToolCardStatusMapping() {
        XCTAssertEqual(UDAgentDefaultToolCard.status(.pending), .pending)
        XCTAssertEqual(UDAgentDefaultToolCard.status(.running), .running)
        XCTAssertEqual(UDAgentDefaultToolCard.status(.succeeded), .done)
        XCTAssertEqual(UDAgentDefaultToolCard.status(.failed), .failed)
        XCTAssertEqual(String(UDAgentPlainMessage.attributed("**粗** `x`").characters), "粗 x")
    }

    #if os(macOS)
    private var windows: [NSWindow] = []

    private func host<V: View>(_ view: V, size: NSSize = NSSize(width: 480, height: 640)) -> NSHostingView<V> {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        windows.append(window)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    override func tearDown() async throws {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private struct Row: Identifiable { let id: Int }

    /// 渲染窗口只把最后 200 行交给 SwiftUI：1000 行的会话里，前 800 行的行视图一次都不该被构造。
    func testTranscriptOnlyBuildsRowsInsideTheWindow() async throws {
        final class Counter { var built = Set<Int>() }
        let counter = Counter()
        let rows = (0..<1000).map(Row.init)
        let view = UDAgentTranscript(rows: rows) { row in
            let _ = counter.built.insert(row.id)
            Text("row \(row.id)").frame(height: 20)
        } footer: {
            EmptyView()
        } empty: {
            EmptyView()
        }
        let hosting = host(view)
        for _ in 0..<5 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(counter.built.isEmpty, "闸门自证：确实构造了行")
        XCTAssertGreaterThanOrEqual(counter.built.min() ?? 0, 800, "窗口外的行不构造")
    }

    /// 面板挂进窗口：待审批时末尾出现审批卡，按「允许」让循环继续。
    func testPanelShowsApprovalCardAndResumesOnAllow() async throws {
        let queue = AgentApprovalQueue()
        let provider = PanelProvider()
        let session = AgentRuntimeSession(
            provider: provider, model: "m", tools: AgentToolRegistry<Int>(tools: [AskTool()]),
            environment: .fixed(systemPrompt: "", toolContext: 0),
            approvalGate: InteractiveApprovalGate(presenter: queue.presenter))
        let panel = UDAgentPanel(session: session, approvals: queue) { EmptyView() } toolbar: { EmptyView() }
        let hosting = host(panel)

        let turn = Task { await session.submit("go") }
        let deadline = ContinuousClock.now + .seconds(2)
        while queue.pending == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(queue.pending)
        hosting.layoutSubtreeIfNeeded()
        queue.decide(.granted, for: queue.pending!.id)
        await turn.value
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(session.messages.last, .assistant(content: "done", toolCalls: []))
    }
    #endif
}

private struct AskTool: AgentTool {
    var schema: AgentToolSchema { AgentToolSchema(name: "ask", description: "", parametersJSON: "{}") }
    func approvalRequirement(arguments: String) -> AgentToolApprovalRequirement { .ask(subject: "do it") }
    func run(arguments: String, context: Int) async throws -> AgentToolResult { AgentToolResult(content: "ran") }
}

private final class PanelProvider: AgentLLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func stream(_ request: AgentChatRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let n = lock.withLock { calls += 1; return calls }
        return AsyncThrowingStream { continuation in
            if n == 1 {
                continuation.yield(.toolCall(LLMToolCall(id: "c1", name: "ask", argumentsJSON: "{}")))
            } else {
                continuation.yield(.text("done"))
            }
            continuation.finish()
        }
    }
}
