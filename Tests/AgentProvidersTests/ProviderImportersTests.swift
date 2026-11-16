import XCTest
@testable import AgentProviders

/// 三个来源的旧数据导入：保留 UUID、Base URL 换算到共享约定、Key 由注入的读取器给。
final class ProviderImportersTests: XCTestCase {
    // MARK: - uTerm

    func testUTermOpenAIRootGainsV1AndModelBecomesHint() {
        let openai = UUID(), anthropic = UUID(), blank = UUID()
        let records = [
            UTermAIProviderRecord(id: anthropic, name: "Claude", kindRaw: "anthropic",
                                  baseURL: "https://api.anthropic.com/", model: "claude-x",
                                  sortOrder: 1, createdAt: Date(timeIntervalSince1970: 1)),
            UTermAIProviderRecord(id: openai, name: "DeepSeek", kindRaw: "openai",
                                  baseURL: "https://api.deepseek.com", model: "",
                                  sortOrder: 0, createdAt: Date(timeIntervalSince1970: 2)),
            UTermAIProviderRecord(id: blank, name: "", kindRaw: "openai", baseURL: " ", model: "gpt",
                                  sortOrder: 2, createdAt: Date(timeIntervalSince1970: 3)),
        ]
        let keys: [UUID: String] = [openai: " sk-deep ", anthropic: ""]
        let imported = ProviderImporters.importUTermAIProviders(records) { keys[$0] }

        XCTAssertEqual(imported.map(\.id), [openai, anthropic, blank], "按 uTerm 的 sortOrder")
        XCTAssertEqual(imported[0].baseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(imported[0].apiKey, "sk-deep")
        XCTAssertNil(imported[0].defaultModel)
        XCTAssertEqual(imported[1].baseURL, "https://api.anthropic.com")
        XCTAssertEqual(imported[1].defaultModel, "claude-x")
        XCTAssertNil(imported[1].apiKey, "空 Key 当没有")
        XCTAssertEqual(imported[2].baseURL, "https://api.openai.com/v1", "空地址用预置根 + /v1")
        XCTAssertEqual(imported[2].name, "OpenAI 兼容")
    }

    // MARK: - uTable

    func testUTableDefaultsJSONMapsKindsAndSkipsBrokenEntries() {
        let a = UUID(), b = UUID()
        let json = """
        [
          {"id":"\(a.uuidString)","name":"OpenRouter","kind":"openAICompatible",
           "baseURL":"https://openrouter.ai/api/v1/","defaultModel":"x/y"},
          {"id":"not-a-uuid","name":"Broken","kind":"anthropic","baseURL":"https://api.anthropic.com"},
          {"id":"\(b.uuidString)","name":"Claude","kind":"anthropic","baseURL":"https://api.anthropic.com",
           "defaultModel":"","models":["legacy"]}
        ]
        """
        let imported = ProviderImporters.importUTableProviders(defaultsData: Data(json.utf8)) { $0 == a ? "sk-a" : nil }
        XCTAssertEqual(imported.map(\.id), [a, b])
        XCTAssertEqual(imported[0].kind, .openai)
        XCTAssertEqual(imported[0].baseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(imported[0].defaultModel, "x/y")
        XCTAssertEqual(imported[0].apiKey, "sk-a")
        XCTAssertEqual(imported[1].kind, .anthropic)
        XCTAssertNil(imported[1].defaultModel)
        XCTAssertTrue(ProviderImporters.importUTableProviders(defaultsData: nil) { _ in nil }.isEmpty)
        XCTAssertTrue(ProviderImporters.importUTableProviders(defaultsData: Data("{}".utf8)) { _ in nil }.isEmpty)
    }

    // MARK: - Electron 版 uGit

    func testElectronProvidersStripAnthropicV1AndDeriveStableIDs() {
        let json = """
        [
          {"id":"p-1","name":"Claude","protocol":"anthropic","baseUrl":"https://api.anthropic.com/v1",
           "apiKeyAuth":true,"models":[{"id":"claude-a","name":"A"},{"id":"claude-b","name":"B"}]},
          {"id":"p-2","name":"Local","protocol":"openai","baseUrl":"http://127.0.0.1:1234/v1",
           "apiKeyAuth":false,"models":[]},
          {"id":"p-3","name":"Gateway","protocol":"anthropic","baseUrl":"https://gw.example.com/anthropic",
           "apiKeyAuth":true,"models":[]},
          {"id":"p-4","name":"Insecure","protocol":"openai","baseUrl":"http://remote.example.com/v1",
           "apiKeyAuth":true,"models":[]},
          {"id":"p-5","name":"Bad","protocol":"gemini","baseUrl":"https://x.example.com","apiKeyAuth":true,"models":[]}
        ]
        """
        var reads: [String] = []
        let imported = ProviderImporters.importElectronUGitProviders(
            localStorageJSON: json, selection: "p-1:claude-b") { id in
            reads.append(id)
            return "key-\(id)"
        }
        XCTAssertEqual(imported.map(\.name), ["Claude", "Local", "Gateway"], "地址不合规 / 协议未知的丢弃")
        XCTAssertEqual(imported[0].baseURL, "https://api.anthropic.com")
        XCTAssertEqual(imported[0].defaultModel, "claude-b", "按存下的模型选择")
        XCTAssertEqual(imported[0].apiKey, "key-p-1")
        XCTAssertNil(imported[1].apiKey, "apiKeyAuth=false 不读 Key")
        XCTAssertFalse(reads.contains("p-2"))
        XCTAssertEqual(imported[1].baseURL, "http://127.0.0.1:1234/v1")
        XCTAssertNil(imported[0].warning)
        XCTAssertNotNil(imported[2].warning, "不以 /v1 结尾的 Anthropic 地址无法无损换算")
        XCTAssertEqual(imported[2].baseURL, "https://gw.example.com/anthropic")

        let again = ProviderImporters.importElectronUGitProviders(localStorageJSON: json) { _ in nil }
        XCTAssertEqual(again.map(\.id), imported.map(\.id), "非 UUID 的旧 id 派生出确定性 UUID")
        XCTAssertEqual(again[0].defaultModel, "claude-a", "没有选择时用第一个模型")
    }

    func testElectronUUIDIDsArePreserved() {
        let id = UUID()
        let json = """
        [{"id":"\(id.uuidString)","name":"O","protocol":"openai","baseUrl":"https://api.openai.com/v1",
          "apiKeyAuth":true,"models":[]}]
        """
        XCTAssertEqual(ProviderImporters.importElectronUGitProviders(localStorageJSON: json) { _ in nil }.first?.id, id)
        XCTAssertTrue(ProviderImporters.importElectronUGitProviders(localStorageJSON: "garbage") { _ in nil }.isEmpty)
    }

    // MARK: - 合并

    func testMergeDuplicatesByKindBaseAndKeyHash() {
        let existing = ImportedProvider(id: UUID(), name: "uTerm DS", kind: .openai,
                                        baseURL: "https://api.deepseek.com/v1", apiKey: "sk")
        let sameService = ImportedProvider(id: UUID(), name: "uTable DS", kind: .openai,
                                           baseURL: "HTTPS://API.deepseek.com/v1/", apiKey: " sk ")
        let otherKey = ImportedProvider(id: UUID(), name: "DS 2", kind: .openai,
                                        baseURL: "https://api.deepseek.com/v1", apiKey: "sk-2")
        let sameID = ImportedProvider(id: existing.id, name: "dup id", kind: .openai,
                                      baseURL: "https://api.deepseek.com/v1", apiKey: "sk")
        let merged = ProviderImporters.mergeDuplicates([sameService, otherKey, sameID], existing: [existing])
        XCTAssertEqual(merged.map(\.id), [otherKey.id, existing.id],
                       "同服务同 Key 的合并掉；同 id 的留给 apply 跳过")
    }

    func testDeterministicUUIDIsStableAndVersioned() {
        let a = DeterministicUUID.make(namespace: "n", name: "x")
        XCTAssertEqual(a, DeterministicUUID.make(namespace: "n", name: "x"))
        XCTAssertNotEqual(a, DeterministicUUID.make(namespace: "m", name: "x"))
        XCTAssertEqual(a.uuidString[a.uuidString.index(a.uuidString.startIndex, offsetBy: 14)], "8")
    }
}
