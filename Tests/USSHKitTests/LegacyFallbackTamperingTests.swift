import Foundation
import NIOSSH
import USSHTestServer
import XCTest
@_spi(uTermIntegration) @testable import USSHKit

/// 中间人伪造明文的 KEXINIT，想把一台主机密钥已被信任的现代服务器逼到 SHA-1 旧算法上（`SSHLegacyFallback` 的安全说明）。
///
/// 第一次连接的 KEXINIT 是明文、没有认证，所以中间人**能**触发那一次再试（多连一次）；但第二次连接里双方报的算法列表
/// 算进交换哈希、由主机密钥签名：
/// - 第二次不篡改：真正的服务器照常协商到现代算法，什么也不算旧算法，进程内的「需要旧算法」记录不写；
/// - 第二次也篡改（只改一个方向，或两个方向都改成只剩 `ssh-rsa`、连服务器自己也用 SHA-1 签）：两端的交换哈希对不上，
///   主机签名验不过，连接失败——绝不会得到一个用旧算法的会话。
/// 中间人要想成功，得在握手的那几秒里算出 SHA-1 的选择前缀碰撞（两份不同的会话记录哈希相同）。
final class LegacyFallbackTamperingTests: XCTestCase {
    private static let rsaHostKey = try! SSHRSAPrivateKey(pemRepresentation: KeyImportFixtures.rsaPKCS1)
    private static let sha1HostKey = SSHRSASignatureAlgorithm.sshRSA.name
    private static let sha1KeyExchange = SSHDiffieHellmanAlgorithm.group14SHA1.name

    /// 只提供 SHA-2 的 RSA 主机签名（OpenSSH 8.8 以后的默认），或者也还提供 `ssh-rsa`（更老的 OpenSSH）。
    private func rsaServer(alsoSHA1: Bool) async throws -> SSHTestServer {
        try await TestSSH.startServer { configuration in
            configuration.useRSAHostKey(
                Self.rsaHostKey,
                algorithms: SSHRSASignatureAlgorithm.modern + (alsoSHA1 ? [.sshRSA] : []))
        }
    }

    private struct Attempt {
        let proxy: KeyExchangeInitTamperer
        let store: MemoryHostKeyStore
        let memory = SSHLegacyEndpointMemory()
    }

    /// 起中间人，并把服务器的主机密钥以中间人的地址记成已信任。
    private func attempt(_ server: SSHTestServer,
                         rewrite: @escaping @Sendable (Int, KeyExchangeInitTamperer.Direction, inout [[String]]) -> Void)
        async throws -> Attempt {
        let proxy = try await KeyExchangeInitTamperer.start(targetPort: server.port, rewrite: rewrite)
        let store = MemoryHostKeyStore(known: [TestSSH.hostKey(of: server, host: "127.0.0.1", port: proxy.port)])
        return Attempt(proxy: proxy, store: store)
    }

    private func connect(_ attempt: Attempt) async throws -> ConnectedClient {
        try await SSHClientFactory.connect(
            endpoint: SSHEndpoint(host: "127.0.0.1", port: attempt.proxy.port, username: TestSSH.username),
            credential: .password(TestSSH.password),
            hostKeyStore: attempt.store,
            hostKeyPolicy: .strict,
            connectTimeout: .seconds(20),
            approvalTimeout: .seconds(20),
            approver: { _ in XCTFail("a trusted host must not prompt"); return false },
            legacyFallback: true,
            legacyMemory: attempt.memory)
    }

    // MARK: - 只篡改第一次

    /// 第一次连接里服务器的报价被换成只剩 SHA-1 的主机签名（或只剩 group14-sha1）：再试一次是会发生的，但第二次真正的
    /// 服务器照常协商到现代算法，没有旧算法，记录不写；服务器自己还提供 `ssh-rsa` 时也一样（我们优先现代算法）。
    func testForgedLegacyOnlyOfferOnTheFirstConnectionDoesNotDowngrade() async throws {
        for alsoSHA1 in [false, true] {
            for (category, forged) in [(KeyExchangeInitTamperer.hostKey, Self.sha1HostKey),
                                       (KeyExchangeInitTamperer.keyExchange, Self.sha1KeyExchange)] {
                let label = "server also SHA-1: \(alsoSHA1), forged list \(category) = \(forged)"
                let server = try await rsaServer(alsoSHA1: alsoSHA1)
                let attempt = try await attempt(server) { connection, direction, lists in
                    guard connection == 0, direction == .serverToClient else { return }
                    // 留着 strict KEX 的伪算法（kex-strict-s-v00@openssh.com）：去掉它别的检查会先失败。
                    let markers = lists[category].filter { $0.contains("@openssh.com") && $0.hasPrefix("kex-strict") }
                    lists[category] = [forged] + markers
                }
                let client = try await connect(attempt)
                XCTAssertEqual(attempt.proxy.connections, 2, "\(label): the forged offer did trigger the retry")
                XCTAssertEqual(client.legacyAlgorithmsInUse, [], label)
                XCTAssertEqual(client.targetNeededLegacyTransport, false,
                               "\(label): 给 App 记录用的三态说「这次不需要」，App 据此清掉被诱导的同意")
                XCTAssertNotEqual(client.target.negotiatedAlgorithms?.hostKey, Self.sha1HostKey, label)
                XCTAssertNotEqual(client.target.negotiatedAlgorithms?.keyExchange, Self.sha1KeyExchange, label)
                XCTAssertFalse(attempt.memory.needsLegacy(host: "127.0.0.1", port: attempt.proxy.port), label)
                XCTAssertTrue(attempt.store.remembered.isEmpty, label)
                await client.close()
                await attempt.proxy.stop()
                await server.stop()
            }
        }
    }

    // MARK: - 两次都篡改

    /// 第二次也篡改：哪个方向、服务器自己支不支持 SHA-1，结果都是主机签名验不过、连接失败；不会有第三次，记录不写。
    func testTamperingTheRetryToo_FailsTheHostSignatureNeverALegacySession() async throws {
        let cases: [(alsoSHA1: Bool, directions: Set<KeyExchangeInitTamperer.Direction>, label: String)] = [
            (false, [.serverToClient], "modern server, server offer forged"),
            (true, [.serverToClient], "SHA-1-capable server, server offer forged"),
            (true, [.clientToServer], "SHA-1-capable server, client offer forged"),
            (true, [.serverToClient, .clientToServer], "SHA-1-capable server, both offers forged (both sides pick ssh-rsa)"),
        ]
        for testCase in cases {
            let server = try await rsaServer(alsoSHA1: testCase.alsoSHA1)
            let directions = testCase.directions
            let attempt = try await attempt(server) { connection, direction, lists in
                let hostKey = KeyExchangeInitTamperer.hostKey
                if connection == 0, direction == .serverToClient {
                    lists[hostKey] = [Self.sha1HostKey]                 // 触发再试
                } else if connection == 1, directions.contains(direction) {
                    lists[hostKey] = [Self.sha1HostKey]                 // 想让这一次用 SHA-1 的主机签名
                }
            }
            var connected: ConnectedClient?
            do {
                connected = try await connect(attempt)
                XCTFail("\(testCase.label): connected, legacy in use: \(connected!.legacyAlgorithmsInUse)")
            } catch let SSHConnectionError.handshakeFailed(message) {
                // 两边都改成只剩 ssh-rsa 时双方真的都用 SHA-1：交换哈希不同，签名验不过。只改一边时双方挑的签名算法
                // 先对不上。
                let expected = directions.count == 2 ? "invalidExchangeHashSignature" : "invalidHostKeyForKeyExchange"
                XCTAssertTrue(message.contains(expected), "\(testCase.label): \(message)")
            } catch {
                XCTFail("\(testCase.label): \(error)")
            }
            await connected?.close()
            XCTAssertEqual(attempt.proxy.connections, 2, "\(testCase.label): no third attempt")
            XCTAssertFalse(attempt.memory.needsLegacy(host: "127.0.0.1", port: attempt.proxy.port), testCase.label)
            await attempt.proxy.stop()
            await server.stop()
        }
    }
}
