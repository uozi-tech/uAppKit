import AgentKit
import SwiftData
import XCTest
@testable import AgentProviders

/// `ProviderStore` 在内存容器上的增删改查、排序、按 id 去重、删除连带 Key、导入。
@MainActor
final class ProviderStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var secrets: InMemoryProviderSecretStore!
    private var store: ProviderStore!

    override func setUp() async throws {
        container = try ProviderStoreContainer.makeInMemory()
        secrets = InMemoryProviderSecretStore()
        store = ProviderStore(context: ModelContext(container), secrets: secrets)
    }

    func testAddAppendsInSortOrderWithKindDefaults() {
        let a = store.add(name: " A ", kind: .anthropic)
        let b = store.add(preset: ProviderPreset.all[0])
        XCTAssertEqual(store.providers().map(\.id), [a.id, b.id])
        XCTAssertEqual(a.name, "A")
        XCTAssertEqual(a.baseURL, "https://api.anthropic.com")
        XCTAssertEqual(b.sortOrder, a.sortOrder + 1)
        XCTAssertEqual(store.active(preferredID: nil)?.id, a.id)
        XCTAssertEqual(store.active(preferredID: b.id)?.id, b.id)
        XCTAssertEqual(store.active(preferredID: UUID())?.id, a.id, "存的 id 已删掉就取第一个")
    }

    func testMoveRewritesSortOrder() {
        let a = store.add(name: "A", kind: .openai)
        let b = store.add(name: "B", kind: .openai)
        let c = store.add(name: "C", kind: .openai)
        store.move(store.providers(), fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(store.providers().map(\.id), [c.id, a.id, b.id])
    }

    func testDeleteRemovesEveryRowWithThatIDAndItsKey() throws {
        let a = store.add(name: "A", kind: .openai)
        try store.saveKey("sk", for: a.id)
        // CloudKit 里同 id 的第二行（另一台设备同时迁移）。
        store.context.insert(LLMProvider(id: a.id, name: "A", kind: .openai, baseURL: a.baseURL))
        store.save()

        XCTAssertNil(store.delete(a))
        XCTAssertTrue(store.providers().isEmpty)
        XCTAssertNil(try secrets.load(for: a.id))
        let remaining = try store.context.fetch(FetchDescriptor<LLMProvider>())
        XCTAssertTrue(remaining.isEmpty)
    }

    func testReadDeduplicatesByIDAndUpdateWritesEveryRow() throws {
        let id = UUID()
        store.context.insert(LLMProvider(id: id, name: "Late", kind: .openai, baseURL: "https://a.example.com/v1",
                                         createdAt: Date(timeIntervalSince1970: 200)))
        store.context.insert(LLMProvider(id: id, name: "Early", kind: .openai, baseURL: "https://a.example.com/v1",
                                         createdAt: Date(timeIntervalSince1970: 100)))
        store.save()

        let providers = store.providers()
        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers.first?.name, "Early")

        store.update(providers[0], name: "Renamed", baseURL: "https://b.example.com/v1")
        let rows = try store.context.fetch(FetchDescriptor<LLMProvider>())
        XCTAssertEqual(rows.count, 2, "不自动删重复行")
        XCTAssertEqual(Set(rows.map(\.name)), ["Renamed"], "改动写到同 id 的每一行")
        XCTAssertEqual(Set(rows.map(\.baseURL)), ["https://b.example.com/v1"])
    }

    func testUnknownKindFallsBackToOpenAI() {
        let provider = LLMProvider()
        provider.kindRaw = "future-kind"
        XCTAssertEqual(provider.kind, .openai)
    }

    func testApplyImportSkipsExistingIDsAndWritesKeyOnlyWhenMissing() throws {
        let existing = store.add(name: "Mine", kind: .anthropic)
        try store.saveKey("keep-me", for: existing.id)
        let fresh = UUID()
        let report = store.apply([
            ImportedProvider(id: existing.id, name: "Old", kind: .anthropic,
                             baseURL: "https://api.anthropic.com", apiKey: "other"),
            ImportedProvider(id: fresh, name: "New", kind: .openai, baseURL: "https://api.openai.com/v1",
                             defaultModel: "gpt-x", apiKey: "sk-new"),
        ])
        XCTAssertEqual(report.inserted, [fresh])
        XCTAssertEqual(report.skippedExisting, [existing.id])
        XCTAssertEqual(report.keysWritten, [fresh])
        XCTAssertEqual(try secrets.load(for: existing.id), "keep-me", "已有的 Key 不覆盖")
        XCTAssertEqual(store.provider(id: existing.id)?.name, "Mine", "已有的记录不覆盖")
        let imported = try XCTUnwrap(store.provider(id: fresh))
        XCTAssertEqual(imported.defaultModel, "gpt-x")
        XCTAssertGreaterThan(imported.sortOrder, existing.sortOrder)

        // 重复导入是幂等的。
        let again = store.apply([ImportedProvider(id: fresh, name: "New", kind: .openai,
                                                  baseURL: "https://api.openai.com/v1", apiKey: "sk-new")])
        XCTAssertEqual(again.inserted, [])
        XCTAssertEqual(store.providers().count, 2)
    }

    func testFileBackedContainerWithoutCloudKit() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let container = try ProviderStoreContainer.make(directory: dir, sync: .none)
        let store = ProviderStore(context: ModelContext(container), secrets: secrets)
        store.add(name: "Disk", kind: .openai)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("providers.store").path))
        XCTAssertEqual(ProviderStoreContainer.Sync.shared, .cloudKit(containerID: "iCloud.com.uozi.shared"))
    }

    func testCatalogSourceUsesNormalizedEndpointIdentity() {
        let snapshot = ProviderSnapshot(id: UUID(), name: "A", kind: .openai, baseURL: "https://API.openai.com/v1/")
        let source = ProviderModelCatalog.source(for: snapshot, secrets: secrets)
        XCTAssertEqual(source.providerID, snapshot.id)
        XCTAssertEqual(source.endpoint, "openai|https://api.openai.com/v1")
        XCTAssertEqual(snapshot.summary, "OpenAI 兼容 · API.openai.com")
    }
}
