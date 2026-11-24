import Crypto
import NIOSSH
import USSHTestServer
import XCTest
@_spi(uTermIntegration) @testable import USSHKit

/// USSHKit 默认的算法集是 `.standard`：RSA 主机密钥的服务器默认能连上；明确传 `.builtInOnly` 时照样拒绝；
/// SHA-1 的旧算法不在默认集里（关掉自动退级时被拒，`.legacyCompatible` 能连）。保活默认关。
/// 自动退级本身见 `LegacyFallbackTests`。
final class AlgorithmPolicyTests: XCTestCase {

    private func rsaKey(_ pem: String = KeyImportFixtures.rsaPKCS1) throws -> SSHRSAPrivateKey {
        guard case .rsa(let key) = try PrivateKeyImporter.resolve(pem: pem, passphrase: nil) else {
            throw XCTSkip("夹具不是 RSA")
        }
        return key
    }

    private func rsaUserServer(serverSignatureAlgorithms: [String]?) async throws -> SSHTestServer {
        let authorized = try TestSSH.publicKey(ofPrivateKey: KeyImportFixtures.rsaPKCS1)
        return try await TestSSH.startServer(authentication: SSHTestAuthentication(
            authorizedKeys: [TestSSH.username: [authorized]])) { configuration in
            configuration.serverSignatureAlgorithms = serverSignatureAlgorithms
        }
    }

    private func rsaAttempts(_ server: SSHTestServer) -> [SSHTestAuthAttempt] {
        server.events.authAttempts.filter { $0.rsaSignatureAlgorithm != nil }
    }

    /// 服务器宣告了 `server-sig-algs`：第一次就用它列的最好的那个，只占一次认证次数。
    func testRSAUserKeyUnderBuiltInOnlyWithServerSigAlgs() async throws {
        let server = try await rsaUserServer(serverSignatureAlgorithms: ["ssh-ed25519", "rsa-sha2-256", "rsa-sha2-512"])
        defer { Task { await server.stop() } }

        let client = try await TestSSH.connect(server, credential: .privateKey(pem: KeyImportFixtures.rsaPKCS1, passphrase: nil),
                                               algorithms: .builtInOnly)
        let echoed = try await client.exec("echo hello")
        XCTAssertEqual(echoed, "hello\n")
        await client.close()
        XCTAssertEqual(rsaAttempts(server).map(\.rsaSignatureAlgorithm), [.rsaSHA2_512])
    }

    /// 没宣告（OpenSSH 7.2 之前那样）：依次 rsa-sha2-512、rsa-sha2-256，不发 SHA-1 的 ssh-rsa。
    func testRSAUserKeyFallsBackWithoutServerSigAlgs() async throws {
        var authentication = SSHTestAuthentication(
            authorizedKeys: [TestSSH.username: [try TestSSH.publicKey(ofPrivateKey: KeyImportFixtures.rsaPKCS1)]])
        authentication.acceptedRSASignatureAlgorithms = [.rsaSHA2_256]
        let server = try await TestSSH.startServer(authentication: authentication)
        defer { Task { await server.stop() } }

        let client = try await TestSSH.connect(server, credential: .privateKey(pem: KeyImportFixtures.rsaPKCS1, passphrase: nil))
        await client.close()
        XCTAssertEqual(rsaAttempts(server).map(\.rsaSignatureAlgorithm), [.rsaSHA2_512, .rsaSHA2_256])
    }

    /// 服务器的报价对不上时 USSHKit 给的文字（与 `SSHClientError.noCommonAlgorithm` 的说法是同一份）。
    private func noCommonAlgorithm(_ category: SSHAlgorithmNegotiationFailure.Category, serverOffer: [String]) -> String {
        SSHErrorText.describe(SSHClientError.noCommonAlgorithm(
            SSHAlgorithmNegotiationFailure(category: category, clientOffer: [], serverOffer: serverOffer)))
    }

    /// 只有 RSA（SHA-2）主机密钥的服务器：默认（`.standard`）一次就连上，主机密钥照 OpenSSH 的写法记成 `ssh-rsa`。
    func testRSAOnlyHostKeyConnectsByDefault() async throws {
        let hostKey = try rsaKey()
        let server = try await TestSSH.startServer { configuration in
            configuration.useRSAHostKey(hostKey)
        }
        defer { Task { await server.stop() } }

        let store = MemoryHostKeyStore()
        let client = try await TestSSH.connect(server, store: store)
        let echoed = try await client.exec("echo hello")
        XCTAssertEqual(echoed, "hello\n")
        XCTAssertEqual(client.target.negotiatedAlgorithms?.hostKey, "rsa-sha2-512")
        XCTAssertEqual(client.legacyAlgorithmsInUse, [])
        await client.close()
        XCTAssertEqual(store.remembered.map(\.keyType), ["ssh-rsa"], "RSA 主机密钥照 OpenSSH 的写法记成 ssh-rsa")
        XCTAssertEqual(server.events.acceptedConnections, 1)
    }

    /// 把 `.builtInOnly` 当严格策略（`legacyFallback: false`）：不报、不接受 RSA 主机密钥，每次都是「没有共同的主机
    /// 密钥算法」，没走到认证，也不再试。开着自动退级时会扩展到 `.standard` 再试一次并连上（见下一条）。
    func testRSAOnlyHostKeyIsRefusedUnderExplicitBuiltInOnly() async throws {
        let hostKey = try rsaKey()
        let server = try await TestSSH.startServer { configuration in
            configuration.useRSAHostKey(hostKey)
        }
        defer { Task { await server.stop() } }

        let attempts = 5
        for _ in 0..<attempts {
            let message = await assertConnectionError({
                _ = try await TestSSH.connect(server, algorithms: .builtInOnly, legacyFallback: false)
            }) { if case .handshakeFailed(let message) = $0 { return message } else { return nil } }
            XCTAssertEqual(message, noCommonAlgorithm(.hostKey, serverOffer: ["rsa-sha2-512", "rsa-sha2-256"]))
        }
        XCTAssertTrue(server.events.authAttempts.isEmpty)
        try await server.waitForEvents { $0.acceptedConnections == attempts }
        XCTAssertEqual(server.events.acceptedConnections, attempts, "一次也没有再试")
    }

    /// `.builtInOnly` 开着自动退级：扩展出来的 rsa-sha2-* 对得上服务器的报价，再试一次连上。
    func testBuiltInOnlyWithFallbackExtendsToStandard() async throws {
        let hostKey = try rsaKey()
        let server = try await TestSSH.startServer { $0.useRSAHostKey(hostKey) }
        defer { Task { await server.stop() } }
        let client = try await TestSSH.connect(server, algorithms: .builtInOnly)
        XCTAssertEqual(client.target.negotiatedAlgorithms?.hostKey, "rsa-sha2-512")
        XCTAssertEqual(client.legacyAlgorithmsInUse, [])
        await client.close()
        XCTAssertEqual(server.events.acceptedConnections, 2)
    }

    /// 只有 SHA-1 的 `ssh-rsa` 主机签名：关掉自动退级时被拒（类别与报价都对），`.legacyCompatible` 能连。
    func testSHA1HostKeyOnlyNeedsLegacy() async throws {
        let hostKey = try rsaKey()
        let server = try await TestSSH.startServer { configuration in
            configuration.useRSAHostKey(hostKey, algorithms: [.sshRSA])
        }
        defer { Task { await server.stop() } }

        let message = await assertConnectionError({
            _ = try await TestSSH.connect(server, legacyFallback: false)
        }) { if case .handshakeFailed(let message) = $0 { return message } else { return nil } }
        XCTAssertEqual(message, noCommonAlgorithm(.hostKey, serverOffer: ["ssh-rsa"]))

        let client = try await TestSSH.connect(server, algorithms: .legacyCompatible, legacyFallback: false)
        XCTAssertEqual(client.legacyAlgorithmsInUse, [SSHLegacyAlgorithm(role: .hostKey, name: "ssh-rsa")])
        await client.close()
    }

    /// 只有 `diffie-hellman-group14-sha1`：关掉自动退级时被拒，`.legacyCompatible` 能连。
    func testGroup14SHA1OnlyNeedsLegacy() async throws {
        let server = try await TestSSH.startServer { configuration in
            configuration.keyExchangeAlgorithms = [SSHDiffieHellmanAlgorithm.group14SHA1.name]
        }
        defer { Task { await server.stop() } }

        let message = await assertConnectionError({
            _ = try await TestSSH.connect(server, legacyFallback: false)
        }) { if case .handshakeFailed(let message) = $0 { return message } else { return nil } }
        XCTAssertEqual(message, noCommonAlgorithm(.keyExchange, serverOffer: ["diffie-hellman-group14-sha1"]))

        let client = try await TestSSH.connect(server, algorithms: .legacyCompatible, legacyFallback: false)
        XCTAssertEqual(client.legacyAlgorithmsInUse,
                       [SSHLegacyAlgorithm(role: .keyExchange, name: "diffie-hellman-group14-sha1")])
        await client.close()
    }

    /// 服务器同时有 ed25519 与 RSA 主机密钥：协商到的仍是 ed25519，记下的主机密钥类型不变（已有的 known-hosts 照常生效）。
    func testEd25519AndRSAHostKeysKeepEd25519() async throws {
        let hostKey = try rsaKey()
        let server = try await TestSSH.startServer { configuration in
            configuration.hostKeys = [NIOSSHPrivateKey(ed25519Key: .init())]
                + SSHRSASignatureAlgorithm.modern.map { NIOSSHPrivateKey(rsaPrivateKey: hostKey, algorithm: $0) }
        }
        defer { Task { await server.stop() } }

        let store = MemoryHostKeyStore()
        let client = try await TestSSH.connect(server, store: store)
        XCTAssertEqual(client.target.negotiatedAlgorithms?.hostKey, "ssh-ed25519")
        await client.close()
        XCTAssertEqual(store.remembered.map(\.keyType), ["ssh-ed25519"])
    }

    func testDefaultsAreStandardWithLegacyFallback() throws {
        let configuration = try USSHKitIntegration.makeConfiguration(
            host: "h", port: 22, username: "u", credential: .password("p"),
            hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: .strict, connectTimeout: .seconds(5),
            approver: { _ in false })
        XCTAssertEqual(configuration.algorithms.hostKeyAlgorithms, SSHAlgorithms.standard.hostKeyAlgorithms)
        XCTAssertEqual(configuration.algorithms.keyExchangeAlgorithms, SSHAlgorithms.standard.keyExchangeAlgorithms)
        XCTAssertFalse(configuration.algorithms.allowsLegacyAlgorithms)
        XCTAssertTrue(configuration.allowsSHA1RSAUserAuthenticationFallback, "自动退级默认开：含同一条连接里的 ssh-rsa 用户认证")
        XCTAssertNil(configuration.keepAliveInterval, "保活默认关")

        let strict = try USSHKitIntegration.makeConfiguration(
            host: "h", port: 22, username: "u", credential: .password("p"),
            hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: .strict, connectTimeout: .seconds(5),
            approver: { _ in false }, legacyFallback: false)
        XCTAssertFalse(strict.allowsSHA1RSAUserAuthenticationFallback)
    }

    /// 打开保活后，链路卡死（服务端不读不写、TCP 还在）会被判死，断开原因是 `.keepAliveTimeout`。
    func testKeepAliveDetectsFrozenLink() async throws {
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }
        let client = try await TestSSH.connect(server, keepAliveInterval: .milliseconds(150))
        let echoed = try await client.exec("echo hello")
        XCTAssertEqual(echoed, "hello\n")

        await server.freezeAllConnections()
        let reason = await client.target.waitForDisconnect()
        guard case .keepAliveTimeout(let unanswered) = reason else {
            return XCTFail("应因保活超时断开，实际 \(reason)")
        }
        XCTAssertEqual(unanswered, 3)
        XCTAssertEqual(SSHErrorText.describe(reason),
                       String(localized: "服务器连续 \(3) 次没有回应保活请求，连接已断开", bundle: ModuleBundle.bundle))
    }
}
