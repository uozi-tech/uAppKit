import XCTest
@testable import AgentProviders

/// 编辑表单模型面对钥匙串失败：删不掉、读不出都要如实告诉用户，不能当成「没有 Key」。
@MainActor
final class ProviderEditorModelTests: XCTestCase {
    struct KeychainDown: Error, LocalizedError {
        var errorDescription: String? { "钥匙串已锁定" }
    }

    /// 存得进、读得出，但删除与（按开关）读取会失败的假钥匙串。
    final class FlakySecretStore: ProviderSecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UUID: String] = [:]
        var failsDelete = false
        var failsLoad = false

        func save(_ key: String, for providerID: UUID) throws {
            lock.withLock { values[providerID] = key }
        }

        func load(for providerID: UUID) throws -> String? {
            try lock.withLock {
                if failsLoad { throw KeychainDown() }
                return values[providerID]
            }
        }

        func delete(for providerID: UUID) throws {
            try lock.withLock {
                if failsDelete { throw KeychainDown() }
                values[providerID] = nil
            }
        }
    }

    func testRemoveKeyFailureKeepsSavedStateAndReportsError() {
        let secrets = FlakySecretStore()
        let id = UUID()
        try? secrets.save("sk-1", for: id)
        let model = ProviderEditorModel(providerID: id, draft: ProviderDraft(name: "A", kind: .openai), secrets: secrets)
        XCTAssertTrue(model.hasSavedKey)

        secrets.failsDelete = true
        XCTAssertFalse(model.removeKey())
        XCTAssertTrue(model.hasSavedKey, "Key 其实还在：界面不能显示已移除")
        XCTAssertEqual(model.keySaveError, "从钥匙串移除失败：钥匙串已锁定")
        XCTAssertEqual(try secrets.load(for: id), "sk-1")

        secrets.failsDelete = false
        XCTAssertTrue(model.removeKey())
        XCTAssertFalse(model.hasSavedKey)
        XCTAssertNil(model.keySaveError)
    }

    func testUnreadableKeychainIsReportedNotTreatedAsMissing() async {
        let secrets = FlakySecretStore()
        let id = UUID()
        try? secrets.save("sk-1", for: id)
        secrets.failsLoad = true
        let model = ProviderEditorModel(providerID: id, draft: ProviderDraft(name: "A", kind: .openai), secrets: secrets,
                                        fetch: { _, _ in XCTFail("读不出 Key 时不该发请求"); return [] })
        XCTAssertFalse(model.hasSavedKey)
        XCTAssertEqual(model.keyLoadError, "读取钥匙串失败：钥匙串已锁定")

        await model.testConnection()
        XCTAssertEqual(model.testResult, ProviderConnectionResult(ok: false, message: "读取钥匙串失败：钥匙串已锁定"))
        XCTAssertFalse(model.testInFlight)

        secrets.failsLoad = false
        model.reset(providerID: id, draft: ProviderDraft(name: "A", kind: .openai))
        XCTAssertTrue(model.hasSavedKey)
        XCTAssertNil(model.keyLoadError)
    }
}
