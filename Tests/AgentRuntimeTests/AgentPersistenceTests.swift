import AgentKit
import AgentProviders
import SwiftData
import XCTest
@testable import AgentRuntime

/// codec 往返、`AgentChatStore` 的惰性建会话 / 作用域 / 接续，以及 `/` 命令匹配。
@MainActor
final class AgentPersistenceTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([ChatSession.self, ChatMessageRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: schema, configurations: configuration))
    }

    private let transcript: [AgentMessage] = [
        .user("expanded prompt"),
        .assistant(content: nil, toolCalls: [AgentToolCall(id: "c1", name: "run_git", arguments: #"{"args":["status"]}"#)]),
        .toolResult(toolCallID: "c1", content: "clean", isError: false),
        .toolResult(toolCallID: "c2", content: "boom", isError: true),
        .assistant(content: "完成", toolCalls: []),
    ]

    func testToolRowsCodecRoundTrip() {
        let codec = ToolRowsTranscriptCodec()
        var rows: [AgentTranscriptRow] = []
        for (index, message) in ([AgentMessage.system("sys")] + transcript).enumerated() {
            switch codec.encode(message, display: index == 1 ? "/status" : nil, lastRow: rows.last) {
            case .skip: XCTAssertEqual(index, 0, "只有 system 不落库")
            case .append(let row): rows.append(row)
            case .replaceLast: XCTFail("缺省 codec 只追加")
            }
        }
        XCTAssertEqual(rows.map(\.roleRaw), ["user", "assistant", "tool", "tool", "assistant"])
        let decoded = codec.decode(rows)
        XCTAssertEqual(decoded.messages, transcript)
        XCTAssertEqual(decoded.displayOverrides, [0: "/status"])
    }

    func testDecodesUTableShapedRowsAndSkipsUnknownRoles() {
        let rows = [
            AgentTranscriptRow(roleRaw: "user", text: "q"),
            AgentTranscriptRow(roleRaw: "assistant", text: "",
                               toolCallsJSON: #"[{"id":"x","name":"run_select","arguments":"{}"}]"#),
            AgentTranscriptRow(roleRaw: "system", text: "ignored"),
            AgentTranscriptRow(roleRaw: "tool", text: "rows", toolCallID: "x"),
        ]
        XCTAssertEqual(ToolRowsTranscriptCodec().decode(rows).messages, [
            .user("q"),
            .assistant(content: nil, toolCalls: [AgentToolCall(id: "x", name: "run_select", arguments: "{}")]),
            .toolResult(toolCallID: "x", content: "rows", isError: false),
        ])
    }

    func testChatStoreCreatesSessionLazilyAndRestoresByScope() throws {
        let context = try makeContext()
        let store = AgentChatStore(context: context)
        let repo = AgentChatStore.scopeID(for: "/Users/me/repo")
        XCTAssertEqual(repo, AgentChatStore.scopeID(for: "/Users/me/repo"))

        store.record(.assistant(content: "orphan", toolCalls: []), display: nil, scopeID: repo)
        XCTAssertNil(store.currentSession, "首条 user 消息之前不建会话")

        for (index, message) in transcript.enumerated() {
            store.record(message, display: index == 0 ? "/status" : nil, scopeID: repo)
        }
        let session = try XCTUnwrap(store.currentSession)
        XCTAssertEqual(session.title, "/status")
        XCTAssertEqual(session.scopeID, repo)
        XCTAssertEqual(session.orderedMessages.map(\.orderIndex), [0, 1, 2, 3, 4])

        store.startNewChat()
        store.record(.user("other repo"), display: nil, scopeID: AgentChatStore.scopeID(for: "/other"))
        store.startNewChat()

        let reopened = try XCTUnwrap(store.reopenCurrent(scopeID: repo))
        XCTAssertEqual(reopened.messages, transcript)
        XCTAssertEqual(reopened.displayOverrides, [0: "/status"])
        XCTAssertEqual(store.sessions(scopeID: repo).count, 1)
        XCTAssertNil(store.reopenCurrent(scopeID: UUID()))

        store.delete(session)
        XCTAssertTrue(store.sessions(scopeID: repo).isEmpty)
        XCTAssertNil(store.currentSession)
    }

    func testSessionRecorderWritesThroughToStore() async throws {
        let context = try makeContext()
        let store = AgentChatStore(context: context)
        let provider = ScriptedProvider([.reply(call("c1", "echo")), .reply(.text("ok"))])
        let session = makeSession(provider, tools: [EchoTool(log: RunLog())])
        session.recorder = { [weak store] message, display in store?.record(message, display: display, scopeID: nil) }
        await session.submit("hi", displayAs: "/hi")
        let restored = try XCTUnwrap(store.reopenCurrent(scopeID: nil))
        XCTAssertEqual(restored.messages, session.messages)
        XCTAssertEqual(restored.displayOverrides, session.userDisplayOverrides)
    }

    /// 工具结果内嵌在 assistant 行里的形状（uTerm 那种）也能经 `.replaceLast` 落库。
    func testCustomCodecCanAmendLastRow() throws {
        struct InlineCodec: AgentTranscriptCodec {
            func encode(_ message: AgentMessage, display: String?, lastRow: AgentTranscriptRow?) -> AgentTranscriptWrite {
                switch message {
                case .toolResult(_, let content, _):
                    guard var last = lastRow else { return .skip }
                    last.text += "\n→ " + content
                    return .replaceLast(last)
                case .user(let text): return .append(AgentTranscriptRow(roleRaw: "user", text: text))
                case .assistant(let content, _): return .append(AgentTranscriptRow(roleRaw: "assistant", text: content ?? ""))
                case .system: return .skip
                }
            }

            func decode(_ rows: [AgentTranscriptRow]) -> AgentRestoredTranscript {
                AgentRestoredTranscript(messages: rows.map { $0.roleRaw == "user" ? .user($0.text)
                    : .assistant(content: $0.text, toolCalls: []) })
            }
        }
        let store = AgentChatStore(context: try makeContext(), codec: InlineCodec())
        store.record(.user("q"), display: nil, scopeID: nil)
        store.record(.assistant(content: "run", toolCalls: []), display: nil, scopeID: nil)
        store.record(.toolResult(toolCallID: "x", content: "out", isError: false), display: nil, scopeID: nil)
        XCTAssertEqual(store.currentSession?.orderedMessages.map(\.text), ["q", "run\n→ out"])
    }

    // MARK: - `/` 命令

    func testSlashMatcher() {
        let matcher = SlashCommandMatcher(commands: [
            SlashCommand(trigger: "Explain", title: "解释提交", subtitle: "改了什么"),
            SlashCommand(trigger: "review", title: "代码审查", subtitle: "找问题", requiresArgument: true),
            SlashCommand(trigger: "clear", title: "清空对话"),
        ])
        XCTAssertEqual(matcher.matches(for: "").count, 3)
        XCTAssertEqual(matcher.matches(for: "ex").map(\.trigger), ["explain"])
        XCTAssertEqual(matcher.matches(for: "审查").map(\.trigger), ["review"])
        XCTAssertEqual(matcher.menuQuery(forDraft: "/re"), "re")
        XCTAssertNil(matcher.menuQuery(forDraft: "/review x"))
        XCTAssertNil(matcher.menuQuery(forDraft: "hello"))
        XCTAssertEqual(matcher.tokenizeDraft("/review ")?.trigger, "review")
        XCTAssertNil(matcher.tokenizeDraft("/review x "))
        XCTAssertNil(matcher.tokenizeDraft("/nope "))
        let parsed = matcher.parse("  /REVIEW  HEAD~3..HEAD ")
        XCTAssertEqual(parsed?.command.trigger, "review")
        XCTAssertEqual(parsed?.argument, "HEAD~3..HEAD")
        XCTAssertNil(matcher.parse("/unknown"))
    }

    // MARK: - 生产 provider

    func testProductionProvidersSurfaceInvalidEndpointOnFirstRequest() async {
        let provider = AgentLLMProviders.make(endpoint: ProviderEndpoint(kind: .openai, baseURL: "http://remote.example.com"),
                                              apiKey: "sk")
        XCTAssertTrue(provider is OpenAICompatibleProvider)
        XCTAssertTrue(AgentLLMProviders.make(endpoint: ProviderEndpoint(kind: .anthropic, baseURL: "https://api.anthropic.com"),
                                             apiKey: "sk") is AnthropicProvider)
        do {
            _ = try await AgentReplyCollector.collect(provider, AgentChatRequest(model: "m", messages: [.user("x")]))
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual(error as? LLMServiceError, .invalidEndpoint(.insecureHTTP))
        }
    }

    func testChatRequestWireShapeCarriesThinkingOnFirstToolCallOnly() {
        let block = LLMThinkingBlock(thinking: "t", signature: "s")
        let request = AgentChatRequest(
            model: "m",
            messages: [.assistant(content: "x", toolCalls: [AgentToolCall(id: "a", name: "n", arguments: "{}")])],
            tools: [AgentToolSchema(name: "n", description: "d", parametersJSON: "{}")],
            thinkingReplay: ["a": [block]])
        let wire = request.wireRequest
        XCTAssertEqual(wire.messages, [.assistant(text: "x", toolCalls: [LLMToolCall(id: "a", name: "n", argumentsJSON: "{}")],
                                                  thinking: [block])])
        XCTAssertEqual(wire.tools.map(\.name), ["n"])
        XCTAssertEqual(wire.toolChoice, .auto)
    }
}
