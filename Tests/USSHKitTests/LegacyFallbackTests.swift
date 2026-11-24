import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import USSHTestServer
import XCTest
@_spi(uTermIntegration) @testable import USSHKit

/// 自动退到 SHA-1 旧算法（`SSHLegacyFallback`）：只在「没有共同算法、而补上旧算法就对得上」时同一跳再连一次；
/// RSA 用户私钥在同一条连接里最后试 `ssh-rsa`；进程内记住需要旧算法的主机。服务端那边数 TCP 连接
/// （`acceptedConnections`）来确认试了几次。
final class LegacyFallbackTests: XCTestCase {

    /// 收集日志事件。
    final class LogProbe: SSHLogger, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [SSHLogEvent] = []
        var warnings: [SSHLogEvent] { lock.withLock { recorded.filter { $0.level == .warning } } }
        func log(_ event: SSHLogEvent) { lock.withLock { recorded.append(event) } }
    }

    private static let rsaHostKey = try! SSHRSAPrivateKey(pemRepresentation: KeyImportFixtures.rsaPKCS1)

    private func sha1HostKeyServer() async throws -> SSHTestServer {
        try await TestSSH.startServer { $0.useRSAHostKey(Self.rsaHostKey, algorithms: [.sshRSA]) }
    }

    private func group14SHA1Server() async throws -> SSHTestServer {
        try await TestSSH.startServer { $0.keyExchangeAlgorithms = [SSHDiffieHellmanAlgorithm.group14SHA1.name] }
    }

    private func hmacSHA1Server() async throws -> SSHTestServer {
        try await TestSSH.startServer {
            $0.transportProtectionSchemes = [SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA1>.self]
        }
    }

    /// 每台服务器上一共被连了几次（等关掉的连接都记上）。
    private func attempts(_ server: SSHTestServer) -> Int { server.events.acceptedConnections }

    // MARK: - 退一次

    /// 只有 `ssh-rsa`（SHA-1）主机签名：默认连得上，第二次才成；只问了一次信任；报出用上了旧算法并记一条警告。
    func testSHA1HostKeyOnlyConnectsViaFallbackWithOneTrustPrompt() async throws {
        let server = try await sha1HostKeyServer()
        defer { Task { await server.stop() } }
        let probe = ApproverProbe(.approve)
        let log = LogProbe()
        let store = MemoryHostKeyStore()

        let client = try await TestSSH.connect(server, store: store, policy: .ask, approver: probe.approver, logger: log)
        let echoed = try await client.exec("echo hello")
        XCTAssertEqual(echoed, "hello\n")
        XCTAssertEqual(client.legacyAlgorithmsInUse, [SSHLegacyAlgorithm(role: .hostKey, name: "ssh-rsa")])
        XCTAssertEqual(client.bastionLegacyAlgorithmsInUse, [])
        await client.close()

        XCTAssertEqual(attempts(server), 2)
        XCTAssertEqual(probe.challenges.count, 1, "第一次在密钥交换里就失败了，不会问两次")
        XCTAssertEqual(store.remembered.map(\.keyType), ["ssh-rsa"])
        XCTAssertEqual(log.warnings.count, 1)
        XCTAssertEqual(log.warnings.first?.metadata["algorithms"], "hostkey=ssh-rsa")
    }

    func testGroup14SHA1OnlyConnectsViaFallback() async throws {
        let server = try await group14SHA1Server()
        defer { Task { await server.stop() } }
        let probe = ApproverProbe(.approve)
        let client = try await TestSSH.connect(server, policy: .ask, approver: probe.approver)
        XCTAssertEqual(client.legacyAlgorithmsInUse,
                       [SSHLegacyAlgorithm(role: .keyExchange, name: "diffie-hellman-group14-sha1")])
        await client.close()
        XCTAssertEqual(attempts(server), 2)
        XCTAssertEqual(probe.challenges.count, 1)
    }

    func testHMACSHA1OnlyConnectsViaFallback() async throws {
        let server = try await hmacSHA1Server()
        defer { Task { await server.stop() } }
        let probe = ApproverProbe(.approve)
        let client = try await TestSSH.connect(server, policy: .ask, approver: probe.approver)
        XCTAssertEqual(client.legacyAlgorithmsInUse, [SSHLegacyAlgorithm(role: .mac, name: "hmac-sha1")])
        XCTAssertEqual(client.target.negotiatedAlgorithms?.encryption, "aes128-ctr")
        await client.close()
        XCTAssertEqual(attempts(server), 2)
        XCTAssertEqual(probe.challenges.count, 1)
    }

    /// 现代服务器：只连一次，什么旧算法也没用上，不记警告。
    func testModernServerNeverRetries() async throws {
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }
        let log = LogProbe()
        let memory = SSHLegacyEndpointMemory()
        let client = try await TestSSH.connect(server, legacyMemory: memory, logger: log)
        XCTAssertEqual(client.legacyAlgorithmsInUse, [])
        await client.close()
        XCTAssertEqual(attempts(server), 1)
        XCTAssertTrue(log.warnings.isEmpty)
        XCTAssertFalse(memory.needsLegacy(host: server.host, port: server.port))
    }

    /// 关掉自动退级：直接报没有共同算法（类别与服务器的报价都在），只连了一次。
    func testFallbackDisabledSurfacesTheTypedError() async throws {
        let server = try await sha1HostKeyServer()
        defer { Task { await server.stop() } }
        let message = await assertConnectionError({
            _ = try await TestSSH.connect(server, legacyFallback: false)
        }) { if case .handshakeFailed(let message) = $0 { return message } else { return nil } }
        XCTAssertEqual(message, SSHErrorText.describe(SSHClientError.noCommonAlgorithm(
            SSHAlgorithmNegotiationFailure(category: .hostKey, clientOffer: [], serverOffer: ["ssh-rsa"]))))
        XCTAssertEqual(attempts(server), 1)
    }

    /// 补上旧算法也协商不出来：恰好两次，报的是第二次的错（这里第一次卡在密钥交换，第二次卡在 MAC）。
    func testNoCommonAlgorithmEvenWithLegacyFailsAfterExactlyTwoAttempts() async throws {
        let server = try await TestSSH.startServer {
            $0.keyExchangeAlgorithms = [SSHDiffieHellmanAlgorithm.group14SHA1.name]
            $0.transportProtectionSchemes = [SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA256>.self]
        }
        defer { Task { await server.stop() } }
        // 客户端只有 AES-GCM：第一次密钥交换就对不上；补上旧算法后密钥交换与加密对上了，MAC 只有 SHA-1 的。
        var aeadOnly = SSHAlgorithms.standard
        aeadOnly.transportProtectionSchemes = Constants.bundledTransportProtectionSchemes
        let message = await assertConnectionError({
            _ = try await TestSSH.connect(server, algorithms: aeadOnly)
        }) { if case .handshakeFailed(let message) = $0 { return message } else { return nil } }
        XCTAssertEqual(message, SSHErrorText.describe(SSHClientError.noCommonAlgorithm(
            SSHAlgorithmNegotiationFailure(category: .mac, clientOffer: [], serverOffer: ["hmac-sha2-256"]))))
        XCTAssertEqual(attempts(server), 2)
    }

    // 补上的旧算法对不上服务器报价时不再试：网络上的例子是 `AlgorithmPolicyTests` 里明确传 `.builtInOnly` 连
    // RSA（SHA-2）主机密钥的服务器，规则本身见 `testShouldRetryOnlyWhenLegacyMatchesTheOffer`。

    // MARK: - 不是协商失败的不再试

    func testAuthenticationFailureDoesNotRetry() async throws {
        let server = try await sha1HostKeyServer()
        defer { Task { await server.stop() } }
        let memory = SSHLegacyEndpointMemory()
        await assertConnectionError({
            _ = try await TestSSH.connect(server, credential: .password("wrong"), legacyMemory: memory)
        }) { if case .authenticationFailed(let message) = $0 { return message } else { return nil } }
        // 第一次是协商失败（退一次），第二次认证失败：不再有第三次。
        XCTAssertEqual(attempts(server), 2)

        let modern = try await TestSSH.startServer()
        defer { Task { await modern.stop() } }
        await assertConnectionError({
            _ = try await TestSSH.connect(modern, credential: .password("wrong"))
        }) { if case .authenticationFailed(let message) = $0 { return message } else { return nil } }
        XCTAssertEqual(attempts(modern), 1)
    }

    func testHostKeyRejectionDoesNotRetry() async throws {
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }
        let probe = ApproverProbe(.reject)
        await assertConnectionError({
            _ = try await TestSSH.connect(server, policy: .ask, approver: probe.approver)
        }) { if case .hostKeyRejected(let message) = $0 { return message } else { return nil } }
        XCTAssertEqual(attempts(server), 1)
        XCTAssertEqual(probe.challenges.count, 1)
    }

    func testTimeoutDoesNotRetry() async throws {
        let server = try await TestSSH.startServer(faults: SSHTestFaults(withholdServerVersion: true))
        defer { Task { await server.stop() } }
        await assertConnectionError({
            _ = try await TestSSH.connect(server, connectTimeout: .milliseconds(300))
        }) { if case .connectFailed(let message) = $0 { return message } else { return nil } }
        XCTAssertEqual(attempts(server), 1)
    }

    /// 对端一接上就关（没有任何协商结论）：不再试。
    func testCloseWithoutNegotiationVerdictDoesNotRetry() async throws {
        let accepted = NIOLockedCounter()
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                accepted.increment()
                return channel.close()
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { listener.close(promise: nil) }
        let port = listener.localAddress?.port ?? 0
        await assertConnectionError({
            _ = try await SSHClientFactory.connect(
                endpoint: SSHEndpoint(host: "127.0.0.1", port: port, username: TestSSH.username),
                credential: .password(TestSSH.password), hostKeyStore: MemoryHostKeyStore(),
                hostKeyPolicy: .insecureAcceptAll, connectTimeout: .seconds(5), approvalTimeout: .seconds(5),
                approver: { _ in true }, legacyMemory: SSHLegacyEndpointMemory())
        }) { if case .connectFailed(let message) = $0 { return message } else { return nil } }
        XCTAssertEqual(accepted.value, 1)
    }

    func testCancellationDoesNotRetry() async throws {
        let server = try await TestSSH.startServer(faults: SSHTestFaults(withholdServerVersion: true))
        defer { Task { await server.stop() } }
        let task = Task { try await TestSSH.connect(server) }
        try await server.waitForEvents { $0.acceptedConnections == 1 }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("应当被取消")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(attempts(server), 1)
    }

    // MARK: - RSA 用户私钥：同一条连接里最后试 ssh-rsa

    private func rsaUserServer(serverSignatureAlgorithms: [String]?) async throws -> SSHTestServer {
        var authentication = SSHTestAuthentication(
            authorizedKeys: [TestSSH.username: [try TestSSH.publicKey(ofPrivateKey: KeyImportFixtures.rsaPKCS1)]])
        authentication.acceptedRSASignatureAlgorithms = [.sshRSA]
        return try await TestSSH.startServer(authentication: authentication) {
            $0.serverSignatureAlgorithms = serverSignatureAlgorithms
            $0.acceptsLegacyAlgorithms = true
        }
    }

    private let rsaCredential = SSHCredential.privateKey(pem: KeyImportFixtures.rsaPKCS1, passphrase: nil)

    /// 只认 `ssh-rsa`、不宣告 `server-sig-algs`：一条连接里三次尝试（512、256、ssh-rsa），成了，报出用上了旧算法。
    func testRSAUserKeyFallsBackToSSHRSAInOneConnection() async throws {
        let server = try await rsaUserServer(serverSignatureAlgorithms: nil)
        defer { Task { await server.stop() } }
        let log = LogProbe()
        let client = try await TestSSH.connect(server, credential: rsaCredential, logger: log)
        XCTAssertEqual(client.legacyAlgorithmsInUse, [SSHLegacyAlgorithm(role: .userAuthentication, name: "ssh-rsa")])
        await client.close()
        XCTAssertEqual(server.events.authAttempts.map(\.rsaSignatureAlgorithm), [.rsaSHA2_512, .rsaSHA2_256, .sshRSA])
        XCTAssertEqual(attempts(server), 1)
        XCTAssertEqual(log.warnings.first?.metadata["algorithms"], "userauth=ssh-rsa")
    }

    /// 宣告了不含 RSA 的 `server-sig-algs`：一次 RSA 都不试。
    func testRSAUserKeyFollowsServerSigAlgsStrictly() async throws {
        let server = try await rsaUserServer(serverSignatureAlgorithms: ["ssh-ed25519"])
        defer { Task { await server.stop() } }
        await assertConnectionError({
            _ = try await TestSSH.connect(server, credential: rsaCredential)
        }) { if case .authenticationFailed(let message) = $0 { return message } else { return nil } }
        XCTAssertEqual(server.events.authAttempts.compactMap(\.rsaSignatureAlgorithm), [])
    }

    /// 关掉自动退级：不试 ssh-rsa。
    func testRSAUserKeyWithoutFallbackStopsAtSHA2() async throws {
        let server = try await rsaUserServer(serverSignatureAlgorithms: nil)
        defer { Task { await server.stop() } }
        await assertConnectionError({
            _ = try await TestSSH.connect(server, credential: rsaCredential, legacyFallback: false)
        }) { if case .authenticationFailed(let message) = $0 { return message } else { return nil } }
        XCTAssertEqual(server.events.authAttempts.map(\.rsaSignatureAlgorithm), [.rsaSHA2_512, .rsaSHA2_256])
    }

    // MARK: - 进程内记住

    /// 记过需要旧算法的主机：第二次直接用补上旧算法的那一套，只连一次。
    func testCacheHitSkipsTheFailingAttempt() async throws {
        let server = try await sha1HostKeyServer()
        defer { Task { await server.stop() } }
        let memory = SSHLegacyEndpointMemory()
        let first = try await TestSSH.connect(server, legacyMemory: memory)
        await first.close()
        XCTAssertEqual(attempts(server), 2)
        XCTAssertTrue(memory.needsLegacy(host: server.host, port: server.port))

        let second = try await TestSSH.connect(server, legacyMemory: memory)
        XCTAssertEqual(second.legacyAlgorithmsInUse, [SSHLegacyAlgorithm(role: .hostKey, name: "ssh-rsa")])
        await second.close()
        XCTAssertEqual(attempts(server), 3, "第二次只连了一次")
    }

    /// 记着需要旧算法、但服务器已经支持现代算法了：照样协商到现代算法，并把记录忘掉。
    func testCachedEndpointStillNegotiatesModernAlgorithms() async throws {
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }
        let memory = SSHLegacyEndpointMemory()
        memory.record(host: server.host, port: server.port, needsLegacy: true)
        let client = try await TestSSH.connect(server, legacyMemory: memory)
        XCTAssertEqual(client.legacyAlgorithmsInUse, [])
        XCTAssertEqual(client.target.negotiatedAlgorithms?.keyExchange, "curve25519-sha256")
        XCTAssertEqual(client.target.negotiatedAlgorithms?.hostKey, "ssh-ed25519")
        await client.close()
        XCTAssertEqual(attempts(server), 1)
        XCTAssertFalse(memory.needsLegacy(host: server.host, port: server.port))
    }

    /// `makeConfiguration` 用不了「再连一次」，但会用上进程内的记录。
    func testMakeConfigurationUsesTheMemory() throws {
        let memory = SSHLegacyEndpointMemory()
        memory.record(host: "Old.Example", port: 2222, needsLegacy: true)
        func configuration(_ host: String, legacyFallback: Bool = true) throws -> SSHClient.Configuration {
            try SSHClientFactory.makeConfiguration(
                .init(host: host, port: 2222, username: "u", credential: .password("p")),
                options: .init(hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: .strict, connectTimeout: .seconds(5),
                               approvalTimeout: .seconds(5), approver: { _ in false },
                               maximumPacketSize: SSHClient.defaultMaximumPacketSize, algorithms: .standard,
                               keepAliveInterval: nil, legacyFallback: legacyFallback, legacyMemory: memory))
        }
        XCTAssertTrue(try configuration("old.example").algorithms.allowsLegacyAlgorithms)
        XCTAssertEqual(try configuration("old.example").algorithms.hostKeyAlgorithms,
                       SSHAlgorithms.legacyCompatible.hostKeyAlgorithms)
        XCTAssertFalse(try configuration("old.example", legacyFallback: false).algorithms.allowsLegacyAlgorithms)
        XCTAssertFalse(try configuration("new.example").algorithms.allowsLegacyAlgorithms)
    }

    // MARK: - 跳板机

    /// 只有跳板机是老设备：跳板机那一跳退一次，目标一次就成；两跳各自报。
    func testJumpHostWhereOnlyTheBastionIsLegacy() async throws {
        let target = try await TestSSH.startServer()
        let bastion = try await sha1HostKeyServer()
        defer { Task { await target.stop(); await bastion.stop() } }
        let probe = ApproverProbe(.approve)
        let client = try await TestSSH.connect(
            target, policy: .ask, approver: probe.approver,
            jumpHost: SSHJumpHost(host: bastion.host, port: bastion.port, username: TestSSH.username,
                                  credential: .password(TestSSH.password)))
        let echoed = try await client.exec("echo hello")
        XCTAssertEqual(echoed, "hello\n")
        XCTAssertEqual(client.bastionLegacyAlgorithmsInUse, [SSHLegacyAlgorithm(role: .hostKey, name: "ssh-rsa")])
        XCTAssertEqual(client.legacyAlgorithmsInUse, [])
        await client.close()
        XCTAssertEqual(attempts(bastion), 2)
        XCTAssertEqual(bastion.events.directTCPIPTargets.count, 1, "目标那一跳只开了一次")
        XCTAssertEqual(probe.challenges.count, 2, "两跳各问一次")
    }

    /// 只有目标是老设备：目标那一跳经跳板机再开一次 direct-tcpip。
    func testJumpHostWhereOnlyTheTargetIsLegacy() async throws {
        let target = try await group14SHA1Server()
        let bastion = try await TestSSH.startServer()
        defer { Task { await target.stop(); await bastion.stop() } }
        let client = try await TestSSH.connect(
            target,
            jumpHost: SSHJumpHost(host: bastion.host, port: bastion.port, username: TestSSH.username,
                                  credential: .password(TestSSH.password)))
        XCTAssertEqual(client.legacyAlgorithmsInUse,
                       [SSHLegacyAlgorithm(role: .keyExchange, name: "diffie-hellman-group14-sha1")])
        XCTAssertEqual(client.bastionLegacyAlgorithmsInUse, [])
        await client.close()
        XCTAssertEqual(attempts(bastion), 1)
        XCTAssertEqual(bastion.events.directTCPIPTargets.count, 2)
    }

    // MARK: - 产品层入口把警告交给调用方的 logger

    /// `SSHLocalForwardingTunnel` 建连那一段的日志也走它的 `logger`：用上旧算法的那条警告 app 看得见。
    func testForwardingTunnelReportsLegacyAlgorithmsToItsLogger() async throws {
        let server = try await sha1HostKeyServer()
        defer { Task { await server.stop() } }
        let log = LogProbe()
        let tunnel = SSHLocalForwardingTunnel(
            request: SSHForwardingRequest(endpoint: TestSSH.endpoint(server), credential: .password(TestSSH.password),
                                          targetHost: "127.0.0.1", targetPort: 9),
            hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: .insecureAcceptAll, logger: log)
        _ = try await tunnel.open()
        await tunnel.close()
        XCTAssertEqual(log.warnings.count, 1)
        XCTAssertEqual(log.warnings.first?.metadata["algorithms"], "hostkey=ssh-rsa")
    }

    /// `SSHFileTransferSession.open(logger:)` 同上。
    func testFileTransferSessionReportsLegacyAlgorithmsToItsLogger() async throws {
        let fileSystem = try SFTPLocalFileSystem.makeTemporary(prefix: "usshkit-legacy-sftp")
        defer { try? fileSystem.removeRoot() }
        let server = try await TestSSH.startServer {
            $0.useRSAHostKey(Self.rsaHostKey, algorithms: [.sshRSA])
            $0.serveSFTP(fileSystem: fileSystem)
        }
        defer { Task { await server.stop() } }
        let log = LogProbe()
        let session = try await SSHFileTransferSession.open(
            endpoint: TestSSH.endpoint(server), credential: .password(TestSSH.password),
            hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: .insecureAcceptAll, approver: { _ in true },
            logger: log)
        await session.close()
        XCTAssertEqual(log.warnings.count, 1)
        XCTAssertEqual(log.warnings.first?.metadata["algorithms"], "hostkey=ssh-rsa")
    }

    // MARK: - 规则（不经网络）

    func testFallbackSetForStandardMatchesLegacyCompatible() throws {
        let fallback = try XCTUnwrap(SSHLegacyFallback.algorithms(addingLegacyTo: .standard))
        let legacy = SSHAlgorithms.legacyCompatible
        XCTAssertEqual(fallback.keyExchangeAlgorithms, legacy.keyExchangeAlgorithms)
        XCTAssertEqual(fallback.hostKeyAlgorithms, legacy.hostKeyAlgorithms)
        XCTAssertEqual(Set(fallback.transportProtectionSchemes.map { ObjectIdentifier($0) }),
                       Set(legacy.transportProtectionSchemes.map { ObjectIdentifier($0) }))
        XCTAssertTrue(fallback.allowsLegacyAlgorithms)
        XCTAssertNil(SSHLegacyFallback.algorithms(addingLegacyTo: .legacyCompatible), "已经允许旧算法：没有可退的")
        // 现代算法一律在前。
        XCTAssertEqual(Array(fallback.hostKeyAlgorithms.prefix(SSHAlgorithms.standard.hostKeyAlgorithms.count)),
                       SSHAlgorithms.standard.hostKeyAlgorithms)
    }

    func testShouldRetryOnlyWhenLegacyMatchesTheOffer() throws {
        let fallback = try XCTUnwrap(SSHLegacyFallback.algorithms(addingLegacyTo: .standard))
        func failure(_ category: SSHAlgorithmNegotiationFailure.Category?, _ offer: [String]) -> SSHAlgorithmNegotiationFailure {
            SSHAlgorithmNegotiationFailure(category: category, clientOffer: [], serverOffer: offer)
        }
        XCTAssertTrue(SSHLegacyFallback.shouldRetry(after: failure(.hostKey, ["ssh-rsa"]), with: fallback))
        XCTAssertTrue(SSHLegacyFallback.shouldRetry(after: failure(.keyExchange, ["diffie-hellman-group14-sha1"]), with: fallback))
        XCTAssertTrue(SSHLegacyFallback.shouldRetry(after: failure(.mac, ["hmac-md5", "hmac-sha1"]), with: fallback))
        XCTAssertFalse(SSHLegacyFallback.shouldRetry(after: failure(.hostKey, ["ssh-dss"]), with: fallback))
        XCTAssertFalse(SSHLegacyFallback.shouldRetry(after: failure(.keyExchange, ["diffie-hellman-group1-sha1"]), with: fallback))
        XCTAssertFalse(SSHLegacyFallback.shouldRetry(after: failure(.encryption, ["aes128-cbc", "3des-cbc"]), with: fallback))
        XCTAssertFalse(SSHLegacyFallback.shouldRetry(after: failure(.compression, ["zlib@openssh.com"]), with: fallback))
        XCTAssertTrue(SSHLegacyFallback.shouldRetry(after: failure(nil, []), with: fallback), "不知道卡在哪：盲试一次")
    }
}

/// 线程安全的计数器。
final class NIOLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
