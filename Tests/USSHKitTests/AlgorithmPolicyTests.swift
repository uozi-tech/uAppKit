import NIOSSH
import USSHTestServer
import XCTest
@_spi(uTermIntegration) @testable import USSHKit

/// USSHKit 默认的算法集 `.builtInOnly`（今天的行为）：RSA **用户**私钥照样能登录，只有 RSA 主机密钥的服务器
/// 被拒；app 明确选 `.standard` 才接受 RSA 主机密钥。保活默认关。
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

    /// 只有 RSA 主机密钥的服务器：`.builtInOnly` 不报、不接受 RSA 主机密钥，握手协商不出来；`.standard` 能连上。
    func testRSAOnlyHostKeyIsRefusedUnderBuiltInOnly() async throws {
        let hostKey = try rsaKey()
        let server = try await TestSSH.startServer { configuration in
            configuration.useRSAHostKey(hostKey)
        }
        defer { Task { await server.stop() } }

        let message = await assertConnectionError({
            _ = try await TestSSH.connect(server, algorithms: .builtInOnly)
        }) {
            switch $0 {
            case .connectFailed(let message), .handshakeFailed(let message): return message
            default: return nil
            }
        }
        // 协商不出主机密钥算法时，往往是服务端先发现、先关连接，客户端只看到对端关闭（`.connectFailed`）；
        // 本端先发现时是「没有共同支持的算法」（`.handshakeFailed`）。两种都没走到认证。
        let negotiation = String(localized: "与服务器没有共同支持的算法（服务器可能只支持旧算法）", bundle: ModuleBundle.bundle)
        let expected = [
            String(localized: "SSH 握手失败：\(negotiation)", bundle: ModuleBundle.bundle),
            String(localized: "服务器关闭了连接", bundle: ModuleBundle.bundle),
        ]
        XCTAssertTrue(expected.contains(message ?? ""), message ?? "")
        XCTAssertTrue(server.events.authAttempts.isEmpty)

        let store = MemoryHostKeyStore()
        let client = try await TestSSH.connect(server, store: store, algorithms: .standard)
        let echoed = try await client.exec("echo hello")
        XCTAssertEqual(echoed, "hello\n")
        await client.close()
        XCTAssertEqual(store.remembered.map(\.keyType), ["ssh-rsa"], "RSA 主机密钥照 OpenSSH 的写法记成 ssh-rsa")
    }

    func testDefaultsAreTodaysBehaviour() throws {
        let configuration = try USSHKitIntegration.makeConfiguration(
            host: "h", port: 22, username: "u", credential: .password("p"),
            hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: .strict, connectTimeout: .seconds(5),
            approver: { _ in false })
        XCTAssertEqual(configuration.algorithms.hostKeyAlgorithms, SSHAlgorithms.builtInOnly.hostKeyAlgorithms)
        XCTAssertEqual(configuration.algorithms.keyExchangeAlgorithms, SSHAlgorithms.builtInOnly.keyExchangeAlgorithms)
        XCTAssertFalse(configuration.algorithms.allowsLegacyAlgorithms)
        XCTAssertNil(configuration.keepAliveInterval, "保活默认关")
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
