import Security
import XCTest
@testable import AgentProviders

/// 共享钥匙串的查询属性：写入带访问组 / 可同步 / 数据保护钥匙串 / WhenUnlocked，
/// 读与删用 SynchronizableAny。用假后端检查，不碰真钥匙串。
final class ProviderKeychainTests: XCTestCase {
    final class FakeBackend: KeychainBackend, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var added: [[String: Any]] = []
        private(set) var copied: [[String: Any]] = []
        private(set) var deleted: [[String: Any]] = []
        private var items: [String: Data] = [:]
        var copyStatus: OSStatus?

        private func key(_ query: [String: Any]) -> String {
            "\(query[kSecAttrService as String] ?? "")|\(query[kSecAttrAccount as String] ?? "")"
        }

        func add(_ attributes: [String: Any]) -> OSStatus {
            lock.withLock {
                added.append(attributes)
                items[key(attributes)] = attributes[kSecValueData as String] as? Data
            }
            return errSecSuccess
        }

        func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
            lock.withLock {
                copied.append(query)
                if let copyStatus { return (copyStatus, nil) }
                guard let data = items[key(query)] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, data)
            }
        }

        func delete(_ query: [String: Any]) -> OSStatus {
            lock.withLock {
                deleted.append(query)
                return items.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess
            }
        }
    }

    private let group = "ABCDE12345." + ProviderKeychain.accessGroupSuffix

    func testSaveWritesSharedSynchronizableDataProtectionItem() throws {
        let backend = FakeBackend()
        let keychain = ProviderKeychain(accessGroup: group, backend: backend)
        let id = UUID()
        try keychain.save("  sk-123 ", for: id)

        XCTAssertEqual(backend.deleted.count, 1, "写入前先按 Any 删干净")
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
        XCTAssertEqual(deleteQuery[kSecAttrSynchronizable as String] as? String, kSecAttrSynchronizableAny as String)
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
