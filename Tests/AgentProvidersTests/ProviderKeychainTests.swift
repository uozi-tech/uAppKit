import Security
import XCTest
@testable import AgentProviders

/// 共享钥匙串的查询属性：写入带访问组 / 可同步 / 数据保护钥匙串 / WhenUnlocked，
/// 读与删用 SynchronizableAny。用假后端检查，不碰真钥匙串。
final class ProviderKeychainTests: XCTestCase {
    /// 按真钥匙串的匹配规则建模 `kSecAttrSynchronizable`：写入时没带等于 false；查询给 Any 时
    /// 两种都匹配，给具体值（或不给 = false）时只匹配那一种。
    final class FakeBackend: KeychainBackend, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var added: [[String: Any]] = []
        private(set) var copied: [[String: Any]] = []
        private(set) var deleted: [[String: Any]] = []
        private(set) var updated: [[String: Any]] = []
        private var items: [String: Data] = [:]
        var copyStatus: OSStatus?
        /// 非 nil 时 `add` 一律返回它（模拟写入失败）。
        var addStatus: OSStatus?
        /// false 时 `update` 返回 `errSecUnimplemented`（模拟没实现更新的后端）。
        var supportsUpdate = true

        private func flags(_ query: [String: Any]) -> [Bool] {
            let value = query[kSecAttrSynchronizable as String]
            if let any = value as? String, any == kSecAttrSynchronizableAny as String { return [true, false] }
            return [(value as? Bool) ?? false]
        }

        private func key(_ query: [String: Any], synchronizable: Bool) -> String {
            "\(query[kSecAttrService as String] ?? "")|\(query[kSecAttrAccount as String] ?? "")|\(synchronizable)"
        }

        private func matches(_ query: [String: Any]) -> [String] {
            flags(query).map { key(query, synchronizable: $0) }.filter { items[$0] != nil }
        }

        /// 测试直接摆一条条目（不记进 `added`）。
        func seed(service: String, account: String, synchronizable: Bool, value: String) {
            lock.withLock {
                items["\(service)|\(account)|\(synchronizable)"] = Data(value.utf8)
            }
        }

        var itemCount: Int { lock.withLock { items.count } }

        func add(_ attributes: [String: Any]) -> OSStatus {
            lock.withLock {
                added.append(attributes)
                if let addStatus { return addStatus }
                let itemKey = key(attributes, synchronizable: flags(attributes)[0])
                guard items[itemKey] == nil else { return errSecDuplicateItem }
                items[itemKey] = attributes[kSecValueData as String] as? Data
                return errSecSuccess
            }
        }

        func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
            lock.withLock {
                copied.append(query)
                if let copyStatus { return (copyStatus, nil) }
                guard let first = matches(query).first else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, items[first])
            }
        }

        func delete(_ query: [String: Any]) -> OSStatus {
            lock.withLock {
                deleted.append(query)
                let found = matches(query)
                for key in found { items[key] = nil }
                return found.isEmpty ? errSecItemNotFound : errSecSuccess
            }
        }

        func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
            lock.withLock {
                guard supportsUpdate else { return errSecUnimplemented }
                updated.append(query)
                let found = matches(query)
                guard !found.isEmpty else { return errSecItemNotFound }
                for key in found { items[key] = attributes[kSecValueData as String] as? Data }
                return errSecSuccess
            }
        }
    }

    private let group = "ABCDE12345." + ProviderKeychain.accessGroupSuffix

    func testSaveWritesSharedSynchronizableDataProtectionItem() throws {
        let backend = FakeBackend()
        let keychain = ProviderKeychain(accessGroup: group, backend: backend)
        let id = UUID()
        try keychain.save("  sk-123 ", for: id)

        XCTAssertEqual(backend.updated.count, 1, "先试着就地更新已有的可同步条目")
        XCTAssertEqual(backend.deleted.count, 1, "新值写好之后才收敛历史上以 false 写入的条目")
        let attributes = try XCTUnwrap(backend.added.first)
        XCTAssertEqual(attributes[kSecAttrService as String] as? String, "com.uozi.llm-providers")
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, id.uuidString)
        XCTAssertEqual(attributes[kSecAttrAccessGroup as String] as? String, group)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, true)
        XCTAssertEqual(attributes[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlocked as String)
        XCTAssertEqual(attributes[kSecValueData as String] as? Data, Data("sk-123".utf8), "去首尾空白")

        XCTAssertEqual(try keychain.load(for: id), "sk-123")
        let read = try XCTUnwrap(backend.copied.last)
        XCTAssertEqual(read[kSecAttrSynchronizable as String] as? String, kSecAttrSynchronizableAny as String,
                       "读取必须用 SynchronizableAny：以 true 写入的条目用 false 查不到")
        XCTAssertEqual(read[kSecAttrAccessGroup as String] as? String, group)
        let deleteQuery = try XCTUnwrap(backend.deleted.first)
        XCTAssertEqual(deleteQuery[kSecAttrSynchronizable as String] as? Bool, false,
                       "只删以 false 写入的旧条目，不碰刚写好的那条")
    }

    // MARK: - 覆盖写入：先更新、没有才新增，任何一步失败旧 Key 都还在

    func testOverwriteUpdatesInPlaceWithoutDeletingFirst() throws {
        let backend = FakeBackend()
        let keychain = ProviderKeychain(accessGroup: group, backend: backend)
        let id = UUID()
        try keychain.save("sk-old", for: id)
        try keychain.save("sk-new", for: id)

        XCTAssertEqual(backend.added.count, 1, "第二次写入走更新，不再新增")
        XCTAssertEqual(backend.updated.last?[kSecAttrSynchronizable as String] as? Bool, true)
        XCTAssertFalse(backend.deleted.contains { ($0[kSecAttrSynchronizable as String] as? Bool) == true },
                       "从不先删掉可同步条目")
        XCTAssertEqual(try keychain.load(for: id), "sk-new")
        XCTAssertEqual(backend.itemCount, 1)
    }

    func testLegacyNonSynchronizableItemConvergesToOneSynchronizableItem() throws {
        let backend = FakeBackend()
        let keychain = ProviderKeychain(accessGroup: group, backend: backend)
        let id = UUID()
        backend.seed(service: ProviderKeychain.service, account: id.uuidString, synchronizable: false, value: "sk-legacy")

        try keychain.save("sk-new", for: id)
        XCTAssertEqual(backend.itemCount, 1, "旧的 false 条目被收敛掉")
        XCTAssertEqual(try keychain.load(for: id), "sk-new")
        XCTAssertEqual(backend.added.first?[kSecAttrSynchronizable as String] as? Bool, true)
    }

    func testFailedWriteKeepsTheExistingKey() throws {
        let backend = FakeBackend()
        let keychain = ProviderKeychain(accessGroup: group, backend: backend)
        let id = UUID()
        backend.seed(service: ProviderKeychain.service, account: id.uuidString, synchronizable: false, value: "sk-legacy")
        backend.addStatus = errSecInteractionNotAllowed

        XCTAssertThrowsError(try keychain.save("sk-new", for: id)) { error in
            XCTAssertEqual(error as? ProviderKeychainError, .unexpectedStatus(errSecInteractionNotAllowed))
        }
        XCTAssertEqual(try keychain.load(for: id), "sk-legacy", "写入失败时原来的 Key 不能已经被删掉")
        XCTAssertTrue(backend.deleted.isEmpty)
    }

    func testBackendWithoutUpdateFallsBackToDeleteThenAdd() throws {
        let backend = FakeBackend()
        backend.supportsUpdate = false
        let keychain = ProviderKeychain(accessGroup: group, backend: backend)
        let id = UUID()
        try keychain.save("sk-old", for: id)
        try keychain.save("sk-new", for: id)
        XCTAssertEqual(try keychain.load(for: id), "sk-new")
        XCTAssertEqual(backend.itemCount, 1)
        XCTAssertEqual(backend.deleted.last?[kSecAttrSynchronizable as String] as? String,
                       kSecAttrSynchronizableAny as String)
    }

    func testLoadMissingIsNilAndOtherFailuresThrow() throws {
        let backend = FakeBackend()
        let keychain = ProviderKeychain(accessGroup: group, backend: backend)
        XCTAssertNil(try keychain.load(for: UUID()))
        backend.copyStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try keychain.load(for: UUID()))
    }

    func testEmptyKeyDeletesAndDeleteMissingIsNotAnError() throws {
        let backend = FakeBackend()
        let keychain = ProviderKeychain(accessGroup: group, backend: backend)
        let id = UUID()
        try keychain.save("sk", for: id)
        try keychain.save("   ", for: id)
        XCTAssertNil(try keychain.load(for: id))
        XCTAssertNoThrow(try keychain.delete(for: UUID()))
    }

    func testLegacyReaderQueriesPlainGenericPassword() {
        let backend = FakeBackend()
        _ = backend.add([kSecAttrService as String: "uGit - Third-party AI provider",
                         kSecAttrAccount as String: "p1", kSecValueData as String: Data(" k \n".utf8)])
        let reader = LegacyKeychainReader(backend: backend)
        XCTAssertEqual(reader.genericPassword(service: "uGit - Third-party AI provider", account: "p1"), "k")
        XCTAssertNil(backend.copied.last?[kSecUseDataProtectionKeychain as String],
                     "Electron 版写在文件型登录钥匙串里，缺省不走数据保护钥匙串")
        XCTAssertNil(reader.genericPassword(service: "x", account: "p1"))
    }
}
