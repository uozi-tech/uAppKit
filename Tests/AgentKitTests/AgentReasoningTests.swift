import Foundation
import XCTest
@testable import AgentKit

final class AgentReasoningTests: XCTestCase {
    private func levels(_ wire: AgentWireProtocol, _ id: String) -> [AgentReasoningEffort]? {
        AgentReasoningSupport.resolve(protocol: wire, modelID: id)?.levels
    }

    func testClaudeModelParsing() {
        XCTAssertEqual(AgentReasoningSupport.ClaudeModel("claude-opus-4-7"),
                       .init(family: "opus", major: 4, minor: 7))
        XCTAssertEqual(AgentReasoningSupport.ClaudeModel("claude-sonnet-4-20250514"),
                       .init(family: "sonnet", major: 4, minor: 0))
        XCTAssertEqual(AgentReasoningSupport.ClaudeModel("claude-opus-4-5-20251101"),
                       .init(family: "opus", major: 4, minor: 5))
        XCTAssertEqual(AgentReasoningSupport.ClaudeModel("claude-3-7-sonnet-latest"),
                       .init(family: "sonnet", major: 3, minor: 7))
        XCTAssertEqual(AgentReasoningSupport.ClaudeModel("anthropic/claude-opus-5-5"),
                       .init(family: "opus", major: 5, minor: 5))
        XCTAssertEqual(AgentReasoningSupport.ClaudeModel("us.anthropic.claude-haiku-4-5"),
                       .init(family: "haiku", major: 4, minor: 5))
        XCTAssertNil(AgentReasoningSupport.ClaudeModel("gpt-4o"))
    }

    func testAnthropicLevelsByFamily() {
        XCTAssertEqual(levels(.anthropic, "claude-opus-5-5"), [.low, .medium, .high, .xhigh, .max])
        XCTAssertEqual(levels(.anthropic, "claude-fable-5-1"), [.low, .medium, .high, .xhigh, .max])
        XCTAssertEqual(levels(.anthropic, "claude-opus-4-7"), [.off, .low, .medium, .high, .xhigh, .max])
        XCTAssertEqual(levels(.anthropic, "claude-sonnet-4-6"), [.off, .low, .medium, .high, .max])
        XCTAssertEqual(levels(.anthropic, "claude-sonnet-5-5"), [.off, .low, .medium, .high, .xhigh, .max])
        XCTAssertEqual(levels(.anthropic, "claude-haiku-4-5"), [.off, .low, .medium, .high])
        XCTAssertEqual(levels(.anthropic, "claude-3-7-sonnet-20250219"), [.off, .low, .medium, .high])
        XCTAssertNil(levels(.anthropic, "claude-3-5-sonnet-latest"))
        XCTAssertNil(levels(.anthropic, "deepseek-chat"))
        // Claude 走 OpenAI 兼容中转：参数写法因中转而异，不认。
        XCTAssertNil(levels(.openAICompatible, "claude-opus-4-7"))
    }

    func testOpenAILevels() {
        XCTAssertEqual(levels(.openAICompatible, "o3-mini"), [.low, .medium, .high])
        XCTAssertEqual(levels(.openAICompatible, "openai/gpt-5"), [.off, .low, .medium, .high])
        XCTAssertNil(levels(.openAICompatible, "gpt-5-chat-latest"))
        XCTAssertNil(levels(.openAICompatible, "gpt-4o"))
        XCTAssertNil(levels(.openAICompatible, "deepseek-reasoner"))
    }

    func testDefaultAndUnsupportedEffortProduceNoRequest() {
        XCTAssertNil(AgentReasoningRequest.make(protocol: .anthropic, modelID: "claude-opus-4-7", effort: nil))
        // Opus 5.5 关不掉思考：存着的「关」不能变成会 400 的请求。
        XCTAssertNil(AgentReasoningRequest.make(protocol: .anthropic, modelID: "claude-opus-5-5", effort: .off))
        XCTAssertNil(AgentReasoningRequest.make(protocol: .openAICompatible, modelID: "gpt-4o", effort: .high))
    }

    func testAdaptiveBody() throws {
        let request = try XCTUnwrap(AgentReasoningRequest.make(
            protocol: .anthropic, modelID: "claude-opus-4-7", effort: .high))
        let body = request.anthropicBody(baseMaxTokens: 8192)
        XCTAssertEqual(body.fields["thinking"] as? [String: String], ["type": "adaptive"])
        XCTAssertEqual(body.fields["output_config"] as? [String: String], ["effort": "high"])
        XCTAssertEqual(body.maxTokens, AgentReasoningRequest.adaptiveMinimumMaxTokens)
        XCTAssertTrue(request.forbidsSamplingParameters)
        XCTAssertTrue(request.replaysThinking)
    }

    func testAdaptiveOff() throws {
        let opus = try XCTUnwrap(AgentReasoningRequest.make(
            protocol: .anthropic, modelID: "claude-opus-4-8", effort: .off))
        XCTAssertEqual(opus.anthropicBody(baseMaxTokens: 4096).fields["thinking"] as? [String: String],
                       ["type": "disabled"])
        XCTAssertEqual(opus.anthropicBody(baseMaxTokens: 4096).maxTokens, 4096)
        XCTAssertFalse(opus.forbidsSamplingParameters)

        let sonnet = try XCTUnwrap(AgentReasoningRequest.make(
            protocol: .anthropic, modelID: "claude-sonnet-5-5", effort: .off))
        let fields = sonnet.anthropicBody(baseMaxTokens: 4096).fields
        XCTAssertEqual(fields["thinking"] as? [String: String], ["type": "between_tools"])
        XCTAssertNil(fields["output_config"])
    }

    func testBudgetBody() throws {
        let request = try XCTUnwrap(AgentReasoningRequest.make(
            protocol: .anthropic, modelID: "claude-sonnet-4-5", effort: .medium))
        let body = request.anthropicBody(baseMaxTokens: 4096)
        let thinking = try XCTUnwrap(body.fields["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "enabled")
        XCTAssertEqual(thinking["budget_tokens"] as? Int, 8192)
        XCTAssertEqual(body.maxTokens, 4096 + 8192)

        let off = try XCTUnwrap(AgentReasoningRequest.make(
            protocol: .anthropic, modelID: "claude-sonnet-4-5", effort: .off))
        XCTAssertTrue(off.anthropicBody(baseMaxTokens: 4096).fields.isEmpty)
    }

    func testOpenAIBody() throws {
        let gpt5 = try XCTUnwrap(AgentReasoningRequest.make(
            protocol: .openAICompatible, modelID: "gpt-5-mini", effort: .off))
        XCTAssertEqual(gpt5.openAIBody["reasoning_effort"] as? String, "minimal")
        let gpt51 = try XCTUnwrap(AgentReasoningRequest.make(
            protocol: .openAICompatible, modelID: "gpt-5.1", effort: .off))
        XCTAssertEqual(gpt51.openAIBody["reasoning_effort"] as? String, "none")
        let o3 = try XCTUnwrap(AgentReasoningRequest.make(
            protocol: .openAICompatible, modelID: "o3", effort: .high))
        XCTAssertEqual(o3.openAIBody["reasoning_effort"] as? String, "high")
        XCTAssertTrue(o3.anthropicBody(baseMaxTokens: 100).fields.isEmpty)
        XCTAssertFalse(o3.replaysThinking)
        XCTAssertTrue(o3.forbidsSamplingParameters)
    }

    @MainActor
    func testPreferencesPersistPerProviderAndModel() throws {
        let suite = "AgentReasoningTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = UUID()

        let prefs = AgentReasoningPreferences(defaults: defaults)
        prefs.setEffort(.high, providerID: provider, model: "claude-opus-4-7")
        prefs.setEffort(.low, providerID: provider, model: "claude-haiku-4-5")

        let reloaded = AgentReasoningPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.effort(providerID: provider, model: "claude-opus-4-7"), .high)
        XCTAssertEqual(reloaded.effort(providerID: provider, model: "claude-haiku-4-5"), .low)
        XCTAssertNil(reloaded.effort(providerID: UUID(), model: "claude-opus-4-7"))
        XCTAssertEqual(reloaded.request(providerID: provider, protocol: .anthropic,
                                        model: "claude-opus-4-7")?.effort, .high)

        reloaded.setEffort(nil, providerID: provider, model: "claude-opus-4-7")
        XCTAssertNil(AgentReasoningPreferences(defaults: defaults)
            .effort(providerID: provider, model: "claude-opus-4-7"))
    }
}
