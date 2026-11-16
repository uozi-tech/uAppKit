import AgentKit
import XCTest
@testable import AgentProviders

/// Base URL 约定与端点拼接：openai 带版本前缀、anthropic 根地址；不合规的地址一律抛错，
/// 不悄悄换主机。
final class ProviderEndpointTests: XCTestCase {
    func testOpenAIEndpointsAppendToVersionPrefixedBase() throws {
        let endpoint = ProviderEndpoint(kind: .openai, baseURL: "https://api.openai.com/v1/")
        XCTAssertEqual(try endpoint.chatURL().absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(try endpoint.modelsURL().absoluteString, "https://api.openai.com/v1/models")

        let zhipu = ProviderEndpoint(kind: .openai, baseURL: "https://open.bigmodel.cn/api/paas/v4")
        XCTAssertEqual(try zhipu.chatURL().absoluteString, "https://open.bigmodel.cn/api/paas/v4/chat/completions")
    }

    func testAnthropicEndpointsAddV1ToRootBase() throws {
        let endpoint = ProviderEndpoint(kind: .anthropic, baseURL: "https://api.anthropic.com")
        XCTAssertEqual(try endpoint.chatURL().absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(try endpoint.modelsURL().absoluteString, "https://api.anthropic.com/v1/models?limit=1000")
    }

    func testInsecureOrMalformedBaseFailsClosed() {
        XCTAssertThrowsError(try ProviderEndpoint(kind: .openai, baseURL: "http://example.com/v1").chatURL())
        XCTAssertEqual(ProviderEndpoint(kind: .openai, baseURL: "http://example.com").validationError, .insecureHTTP)
        XCTAssertEqual(ProviderEndpoint(kind: .openai, baseURL: "").validationError, .invalidURL)
        XCTAssertNil(ProviderEndpoint(kind: .openai, baseURL: "http://localhost:11434/v1").validationError)
    }

    func testNormalizedBaseURLLowercasesHostAndDropsTrailingSlashes() {
        XCTAssertEqual(ProviderEndpoint.normalizedBaseURL(" HTTPS://API.OpenAI.com/v1// "), "https://api.openai.com/v1")
        XCTAssertEqual(ProviderEndpoint(kind: .openai, baseURL: "https://API.openai.com/v1/").catalogIdentity,
                       "openai|https://api.openai.com/v1")
    }

    func testPresetsAreUTablesSevenAndAllValid() {
        XCTAssertEqual(ProviderPreset.all.map(\.id),
                       ["openai", "anthropic", "deepseek", "moonshot", "zhipu", "openrouter", "ollama"])
        for preset in ProviderPreset.all {
            XCTAssertNil(ProviderEndpoint(kind: preset.kind, baseURL: preset.baseURL).validationError, preset.id)
        }
        XCTAssertEqual(ProviderKind.openai.rawValue, "openai")
        XCTAssertEqual(ProviderKind.anthropic.rawValue, "anthropic")
    }

    func testServiceErrorMapping() {
        XCTAssertEqual(LLMServiceError.map(LLMWireError.http(status: 401, body: "", retryAfter: nil)) as? LLMServiceError,
                       .unauthenticated)
        XCTAssertEqual(LLMServiceError.map(LLMWireError.http(status: 429, body: "", retryAfter: 3)) as? LLMServiceError,
                       .rateLimited(retryAfter: 3))
        XCTAssertEqual(LLMServiceError.map(AgentEndpointPolicy.ValidationError.insecureHTTP) as? LLMServiceError,
                       .invalidEndpoint(.insecureHTTP))
        XCTAssertTrue(LLMServiceError.map(CancellationError()) is CancellationError)
        XCTAssertTrue(LLMServiceError.map(URLError(.cancelled)) is CancellationError)
        XCTAssertTrue(LLMServiceError.incompleteStream.isStreamVerdict)
        XCTAssertFalse(LLMServiceError.network("x").isStreamVerdict)
    }

    func testDraftKindSwitchFollowsDefaultBaseOnly() {
        var draft = ProviderDraft(name: "A", kind: .anthropic)
        draft.setKind(.openai)
        XCTAssertEqual(draft.baseURL, "https://api.openai.com/v1")

        var custom = ProviderDraft(name: "A", kind: .openai, baseURL: "https://gw.example.com/v1")
        custom.setKind(.anthropic)
        XCTAssertEqual(custom.baseURL, "https://gw.example.com/v1")
    }

    func testDraftValidation() {
        XCTAssertEqual(ProviderDraft(name: " ", kind: .openai).nameError, "名称不能为空")
        XCTAssertEqual(ProviderDraft(name: "x", kind: .openai, baseURL: "").baseURLError, "Base URL 不能为空")
        XCTAssertNotNil(ProviderDraft(name: "x", kind: .openai, baseURL: "http://remote.example.com").baseURLError)
        XCTAssertTrue(ProviderDraft(name: "x", kind: .openai).isValid)
    }

    func testConnectionTestUsesInjectedFetchAndDescribesErrors() async {
        let ok = await ProviderConnectionTest.run(
            endpoint: ProviderEndpoint(kind: .openai, baseURL: "https://api.openai.com/v1"),
            apiKey: "sk", fetch: { _, key in key == "sk" ? ["a", "b"] : [] })
        XCTAssertEqual(ok, ProviderConnectionResult(ok: true, message: "连接成功 · 2 个可用模型", models: ["a", "b"]))

        let noKey = await ProviderConnectionTest.run(
            endpoint: ProviderEndpoint(kind: .openai, baseURL: "https://api.openai.com/v1"),
            apiKey: " ", fetch: { _, _ in XCTFail("不该发请求"); return [] })
        XCTAssertFalse(noKey.ok)

        // 本机服务不要 Key。
        let local = await ProviderConnectionTest.run(
            endpoint: ProviderEndpoint(kind: .openai, baseURL: "http://localhost:11434/v1"),
            apiKey: "", fetch: { _, _ in [] })
        XCTAssertTrue(local.ok)

        let unauthorized = await ProviderConnectionTest.run(
            endpoint: ProviderEndpoint(kind: .anthropic, baseURL: "https://api.anthropic.com"),
            apiKey: "bad", fetch: { _, _ in throw LLMWireError.http(status: 401, body: "", retryAfter: nil) })
        XCTAssertEqual(unauthorized, ProviderConnectionResult(ok: false, message: "认证失败，请检查 API Key"))
    }

    @MainActor
    func testEditorModelSavesKeyAndTestsWithSavedKey() async {
        let secrets = InMemoryProviderSecretStore()
        let id = UUID()
        let model = ProviderEditorModel(providerID: id, draft: ProviderDraft(name: "A", kind: .openai),
                                        secrets: secrets, fetch: { _, key in [key] })
        XCTAssertFalse(model.hasSavedKey)
        model.keyDraft = "  sk-1  "
        XCTAssertTrue(model.saveKey())
        XCTAssertEqual(try secrets.load(for: id), "sk-1")
        XCTAssertEqual(model.keyDraft, "")
        XCTAssertTrue(model.hasSavedKey)

        await model.testConnection()
        XCTAssertEqual(model.testResult?.models, ["sk-1"], "草稿为空时用已存的 Key")
        XCTAssertFalse(model.testInFlight)
    }
}
