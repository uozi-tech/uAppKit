import NIOCore
import NIOPosix
import NIOSSH
import USSHTestServer
import XCTest
@_spi(uTermIntegration) @testable import USSHKit

/// `USSHKitIntegration.connect` 对着进程内的 `SSHTestServer`：认证、失败归类、跳板机、`ConnectedClient` 的便捷方法。
final class ConnectIntegrationTests: XCTestCase {

    // MARK: - 认证

    func testPasswordLoginAndExec() async throws {
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }

        let client = try await TestSSH.connect(server)
        defer { Task { await client.close() } }
        XCTAssertTrue(client.isConnected)
        let echoed = try await client.exec("echo hello")
        XCTAssertEqual(echoed, "hello\n")
    }

    func testExecNonZeroExitThrowsCommandError() async throws {
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }
        let client = try await TestSSH.connect(server)
        defer { Task { await client.close() } }

        do {
            _ = try await client.exec("no-such-command")
            XCTFail("非零退出要抛错")
        } catch SSHCommandError.nonZeroExit(let status, let output) {
            XCTAssertEqual(status, .exited(127))
            XCTAssertTrue(String(buffer: output).contains("command not found"), "stderr 合并进输出")
        }
    }

    func testWrongPasswordIsAuthenticationFailure() async throws {
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }

        let message = await assertConnectionError({
            _ = try await TestSSH.connect(server, credential: .password("wrong"))
        }) { if case .authenticationFailed(let message) = $0 { return message } else { return nil } }
        XCTAssertEqual(message, String(localized: "服务器拒绝了密码", bundle: ModuleBundle.bundle))
    }

    func testUnsupportedMethodNamesWhatTheServerAccepts() async throws {
        let server = try await TestSSH.startServer(authentication: SSHTestAuthentication(
            passwords: [TestSSH.username: TestSSH.password], supportedMethods: [.publicKey]))
        defer { Task { await server.stop() } }

        let message = await assertConnectionError({
            _ = try await TestSSH.connect(server)
        }) { if case .authenticationFailed(let message) = $0 { return message } else { return nil } }
        XCTAssertEqual(message, String(localized: "服务器不接受所提供的认证方式（服务器支持：\("publickey")）",
                                       bundle: ModuleBundle.bundle))
    }

    func testBadPrivateKeyIsAuthenticationFailureBeforeConnecting() async throws {
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }

        let message = await assertConnectionError({
            _ = try await TestSSH.connect(server, credential: .privateKey(pem: KeyImportFixtures.rsaOpenSSHEnc,
                                                                          passphrase: nil))
        }) { if case .authenticationFailed(let message) = $0 { return message } else { return nil } }
        XCTAssertEqual(message, PrivateKeyImportError.encryptedKeyNeedsPassphrase.errorDescription)
        XCTAssertEqual(server.connectionCount, 0)
    }

    func testAgentCredentialIsUnsupported() async throws {
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }
        await assertConnectionError({
            _ = try await TestSSH.connect(server, credential: .agent)
        }) { if case .unsupportedAgentAuthentication = $0 { return "" } else { return nil } }
    }

    /// 每一种能导入的私钥都要能真的登录：导入 → USSHCore 的认证方式 → 服务端验签。
    func testEveryImportableKeyAuthenticates() async throws {
        let pass = KeyImportFixtures.passphrase
        let cases: [(String, String, String?)] = [
            ("rsa openssh", KeyImportFixtures.rsaOpenSSH, nil),
            ("rsa openssh encrypted", KeyImportFixtures.rsaOpenSSHEnc, pass),
            ("rsa openssh without p/q", OpenSSHTestContainers.rsaWithoutPrimes(KeyImportFixtures.rsaOpenSSH), nil),
            ("rsa pkcs1", KeyImportFixtures.rsaPKCS1, nil),
            ("rsa pkcs1 encrypted", KeyImportFixtures.rsaPKCS1Enc, pass),
            ("rsa pkcs8", KeyImportFixtures.rsaPKCS8, nil),
            ("rsa pkcs8 encrypted", KeyImportFixtures.rsaPKCS8Enc, pass),
            ("ed25519 openssh", KeyImportFixtures.ed25519OpenSSH, nil),
            ("ed25519 openssh encrypted", KeyImportFixtures.ed25519OpenSSHEnc, pass),
            ("ed25519 pkcs8", KeyImportFixtures.ed25519PKCS8, nil),
            ("ed25519 pkcs8 encrypted", KeyImportFixtures.ed25519PKCS8Enc, pass),
            ("ecdsa p256 openssh", KeyImportFixtures.ecP256OpenSSH, nil),
            ("ecdsa p384 openssh", KeyImportFixtures.ecP384OpenSSH, nil),
            ("ecdsa p521 openssh", KeyImportFixtures.ecP521OpenSSH, nil),
            ("ecdsa p256 sec1", KeyImportFixtures.ecP256SEC1, nil),
            ("ecdsa p384 sec1", KeyImportFixtures.ecP384SEC1, nil),
            ("ecdsa p521 sec1", KeyImportFixtures.ecP521SEC1, nil),
            ("ecdsa p256 sec1 encrypted", KeyImportFixtures.ecP256SEC1Enc, pass),
            ("ecdsa p256 sec1 named", KeyImportFixtures.ecP256SEC1Named, nil),
            ("ecdsa p256 pkcs8", KeyImportFixtures.ecP256PKCS8, nil),
        ]
        var authorized: [NIOSSHPublicKey] = []
        for (name, pem, passphrase) in cases {
            authorized.append(try XCTUnwrap(try? TestSSH.publicKey(ofPrivateKey: pem, passphrase: passphrase), name))
        }
        let server = try await TestSSH.startServer(authentication: SSHTestAuthentication(
            authorizedKeys: [TestSSH.username: authorized]))
        defer { Task { await server.stop() } }

        for (name, pem, passphrase) in cases {
            do {
                let client = try await TestSSH.connect(server, credential: .privateKey(pem: pem, passphrase: passphrase))
                let echoed = try await client.exec("echo hello")
                XCTAssertEqual(echoed, "hello\n", name)
                await client.close()
            } catch {
                XCTFail("\(name) 登录失败：\(error)")
            }
        }
    }

    /// 服务端不认这把公钥：报认证失败。服务器没宣告 `server-sig-algs`，自动退级开着，所以 SHA-2 两种都被拒后
    /// 同一条连接里最后试 `ssh-rsa`；关掉自动退级就只有两次。
    ///
    /// 服务端要认得 `ssh-rsa` 的签名才会把第三次记下来（`acceptsLegacyAlgorithms`，进程级登记旧算法）；以前这里
    /// 没设，靠的是同一进程里别的用例先登记过——单独跑这一条时第三次就没被记下。客户端发 `ssh-rsa` 本身不需要
    /// 登记，见 USSHCore 的 `OpenSSHSHA1UserAuthTests`（在新进程里对真实 sshd 验）。
    func testUnauthorizedRSAKeyIsRejected() async throws {
        let server = try await TestSSH.startServer(authentication: SSHTestAuthentication(
            authorizedKeys: [TestSSH.username: []])) { $0.acceptsLegacyAlgorithms = true }
        defer { Task { await server.stop() } }

        let message = await assertConnectionError({
            _ = try await TestSSH.connect(server, credential: .privateKey(pem: KeyImportFixtures.rsaPKCS1, passphrase: nil))
        }) { if case .authenticationFailed(let message) = $0 { return message } else { return nil } }
        XCTAssertEqual(message, String(localized: "服务器拒绝了私钥", bundle: ModuleBundle.bundle))
        let publicKeyAttempts = server.events.authAttempts.filter {
            if case .publicKey = $0.method { return true } else { return false }
        }
        XCTAssertEqual(publicKeyAttempts.map(\.rsaSignatureAlgorithm), [.rsaSHA2_512, .rsaSHA2_256, .sshRSA])

        await assertConnectionError({
            _ = try await TestSSH.connect(server, credential: .privateKey(pem: KeyImportFixtures.rsaPKCS1, passphrase: nil),
                                          legacyFallback: false)
        }) { if case .authenticationFailed(let message) = $0 { return message } else { return nil } }
        XCTAssertEqual(server.events.authAttempts.suffix(2).map(\.rsaSignatureAlgorithm), [.rsaSHA2_512, .rsaSHA2_256])
        XCTAssertEqual(server.events.authAttempts.count, 5)
    }

    // MARK: - 连接失败

    func testRefusedPortIsConnectFailed() async throws {
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(listener.localAddress?.port)
        try await listener.close()

        let message = await assertConnectionError({
            _ = try await USSHKitIntegration.connect(
                endpoint: SSHEndpoint(host: "127.0.0.1", port: port, username: TestSSH.username),
                credential: .password(TestSSH.password), hostKeyStore: MemoryHostKeyStore(),
                hostKeyPolicy: .insecureAcceptAll, connectTimeout: .seconds(5), approver: { _ in true })
        }) { if case .connectFailed(let message) = $0 { return message } else { return nil } }
        XCTAssertTrue(message?.contains("127.0.0.1:\(port)") == true, message ?? "")
    }

    func testSilentServerIsHandshakeTimeout() async throws {
        let server = try await TestSSH.startServer(faults: SSHTestFaults(withholdServerVersion: true))
        defer { Task { await server.stop() } }

        let message = await assertConnectionError({
            _ = try await TestSSH.connect(server, connectTimeout: .milliseconds(400))
        }) { if case .connectFailed(let message) = $0 { return message } else { return nil } }
        XCTAssertEqual(message, SSHClientError.handshakeTimeout(.milliseconds(400)).errorDescription)
    }

    func testCancellationStopsConnecting() async throws {
        let server = try await TestSSH.startServer(faults: SSHTestFaults(withholdServerVersion: true))
        defer { Task { await server.stop() } }

        let task = Task { try await TestSSH.connect(server, connectTimeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("取消后不该连上")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    // MARK: - 跳板机

    private func jumpHost(_ bastion: SSHTestServer, password: String = TestSSH.password) -> SSHJumpHost {
        SSHJumpHost(host: bastion.host, port: bastion.port, username: TestSSH.username, credential: .password(password))
    }

    func testJumpHostConnectsToTarget() async throws {
        let target = try await TestSSH.startServer()
        let bastion = try await TestSSH.startServer()
        defer { Task { await target.stop(); await bastion.stop() } }

        let client = try await TestSSH.connect(target, jumpHost: jumpHost(bastion))
        XCTAssertNotNil(client.bastion)
        let echoed = try await client.exec("echo hello")
        XCTAssertEqual(echoed, "hello\n")
        XCTAssertEqual(bastion.events.directTCPIPTargets, ["\(target.host):\(target.port)"])
        await client.close()
        XCTAssertFalse(client.isConnected)
        XCTAssertNotNil(client.bastion?.disconnectReason, "关闭时跳板机一起关")
    }

    func testBastionAuthFailureIsJumpHostFailed() async throws {
        let target = try await TestSSH.startServer()
        let bastion = try await TestSSH.startServer()
        defer { Task { await target.stop(); await bastion.stop() } }

        let message = await assertConnectionError({
            _ = try await TestSSH.connect(target, jumpHost: self.jumpHost(bastion, password: "wrong"))
        }) { if case .jumpHostFailed(let message, _) = $0 { return message } else { return nil } }
        let auth = SSHConnectionError.authenticationFailed(String(localized: "服务器拒绝了密码", bundle: ModuleBundle.bundle))
        XCTAssertEqual(message, String(
            localized: "无法连接 \(bastion.host):\(String(bastion.port)) —— \(auth.errorDescription!)",
            bundle: ModuleBundle.bundle))
        XCTAssertTrue(target.events.authAttempts.isEmpty)
    }

    func testTargetAuthFailureThroughBastionIsJumpHostFailed() async throws {
        let target = try await TestSSH.startServer()
        let bastion = try await TestSSH.startServer()
        defer { Task { await target.stop(); await bastion.stop() } }

        let message = await assertConnectionError({
            _ = try await TestSSH.connect(target, credential: .password("wrong"), jumpHost: self.jumpHost(bastion))
        }) { if case .jumpHostFailed(let message, _) = $0 { return message } else { return nil } }
        let auth = SSHConnectionError.authenticationFailed(String(localized: "服务器拒绝了密码", bundle: ModuleBundle.bundle))
        XCTAssertEqual(message, String(
            localized: "经跳板机连接 \(target.host):\(String(target.port)) 失败 —— \(auth.errorDescription!)",
            bundle: ModuleBundle.bundle))
        try await bastion.waitForEvents { $0.closedConnections >= 1 }   // 目标机失败时跳板机连接也要关掉
    }

    /// 跳板机拒绝开 direct-tcpip（这里是 RFC 4254 的原因码 2）：按转发的说法讲清楚，而不是一串 NIOSSHError。
    func testBastionRefusingForwardingIsExplained() async throws {
        let target = try await TestSSH.startServer()
        let bastion = try await TestSSH.startServer(allowsDirectTCPIP: false)
        defer { Task { await target.stop(); await bastion.stop() } }

        let message = await assertConnectionError({
            _ = try await TestSSH.connect(target, jumpHost: self.jumpHost(bastion))
        }) { if case .jumpHostFailed(let message, _) = $0 { return message } else { return nil } }
        let detail = SSHForwardingChannelFailure(kind: .connectFailed, detail: "")
            .userMessage(targetHost: target.host, targetPort: target.port)
        XCTAssertEqual(message, String(
            localized: "经跳板机连接 \(target.host):\(String(target.port)) 失败 —— \(detail)",
            bundle: ModuleBundle.bundle))
    }

    func testUnreachableBastionIsJumpHostFailed() async throws {
        let target = try await TestSSH.startServer()
        defer { Task { await target.stop() } }
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(listener.localAddress?.port)
        try await listener.close()

        await assertConnectionError({
            _ = try await TestSSH.connect(target, jumpHost: SSHJumpHost(
                host: "127.0.0.1", port: port, username: TestSSH.username, credential: .password(TestSSH.password)))
        }) { if case .jumpHostFailed(let message, _) = $0 { return message } else { return nil } }
    }

    // MARK: - direct-tcpip

    /// 服务器先说话的协议（MySQL 的握手包）：开通道后立刻到的首包不能丢。迁移前要自己在 initializer 里
    /// 包 `NIOAsyncChannel`，现在由 USSHCore 的 `openDirectTCPIPAsyncChannel` 保证。
    func testDirectTCPIPKeepsServerGreeting() async throws {
        let greeter = try await GreetingServer.start(greeting: "greeting")
        defer { Task { try? await greeter.close() } }
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }
        let client = try await TestSSH.connect(server)
        defer { Task { await client.close() } }

        let channel = try await client.openDirectTCPIP(host: "127.0.0.1", port: greeter.port)
        try await channel.executeThenClose { inbound, _ in
            var iterator = inbound.makeAsyncIterator()
            let first = try await iterator.next()
            XCTAssertEqual(first.map { String(buffer: $0) }, "greeting")
        }
    }
}

/// 经跳板机的失败带上那一跳的类别（`jumpHostFailed(_, cause:)`），app 据此分得清「重试不会好」与「网络断了」；
/// 文字不变。两跳各测一遍。
final class JumpHostFailureClassTests: XCTestCase {
    private enum Class: Equatable { case authentication, hostKey, handshake, network, other }

    private func classify(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async -> Class? {
        do {
            try await body()
            XCTFail("应当失败", file: file, line: line)
            return nil
        } catch SSHConnectionError.jumpHostFailed(_, let cause) {
            switch cause {
            case .authenticationFailed?: return .authentication
            case .hostKeyRejected?: return .hostKey
            case .handshakeFailed?: return .handshake
            case .connectFailed?: return .network
            default: return .other
            }
        } catch {
            XCTFail("应是 jumpHostFailed，实际 \(error)", file: file, line: line)
            return nil
        }
    }

    private func jump(_ bastion: SSHTestServer, password: String = TestSSH.password) -> SSHJumpHost {
        SSHJumpHost(host: bastion.host, port: bastion.port, username: TestSSH.username, credential: .password(password))
    }

    func testAuthenticationOnEachHop() async throws {
        let target = try await TestSSH.startServer()
        let bastion = try await TestSSH.startServer()
        defer { Task { await target.stop(); await bastion.stop() } }
        let onBastion = await classify { _ = try await TestSSH.connect(target, jumpHost: self.jump(bastion, password: "wrong")) }
        XCTAssertEqual(onBastion, .authentication)
        let onTarget = await classify {
            _ = try await TestSSH.connect(target, credential: .password("wrong"), jumpHost: self.jump(bastion))
        }
        XCTAssertEqual(onTarget, .authentication)
    }

    func testHostKeyOnEachHop() async throws {
        let target = try await TestSSH.startServer()
        let bastion = try await TestSSH.startServer()
        defer { Task { await target.stop(); await bastion.stop() } }
        // strict：库里没有的主机密钥一律拒绝。只记着跳板机时目标那一跳被拒，什么都没记时跳板机那一跳先被拒。
        let onBastion = await classify { _ = try await TestSSH.connect(target, policy: .strict, jumpHost: self.jump(bastion)) }
        XCTAssertEqual(onBastion, .hostKey)
        let store = MemoryHostKeyStore(known: [TestSSH.hostKey(of: bastion)])
        let onTarget = await classify {
            _ = try await TestSSH.connect(target, store: store, policy: .strict, jumpHost: self.jump(bastion))
        }
        XCTAssertEqual(onTarget, .hostKey)
    }

    func testHandshakeOnEachHop() async throws {
        let old = try await TestSSH.startServer { $0.keyExchangeAlgorithms = [SSHDiffieHellmanAlgorithm.group14SHA1.name] }
        let modern = try await TestSSH.startServer()
        defer { Task { await old.stop(); await modern.stop() } }
        let onBastion = await classify {
            _ = try await TestSSH.connect(modern, jumpHost: self.jump(old), legacyFallback: false)
        }
        XCTAssertEqual(onBastion, .handshake)
        let onTarget = await classify {
            _ = try await TestSSH.connect(old, jumpHost: self.jump(modern), legacyFallback: false)
        }
        XCTAssertEqual(onTarget, .handshake)
    }

    func testNetworkOnEachHop() async throws {
        let target = try await TestSSH.startServer()
        defer { Task { await target.stop() } }
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).get()
        let closedPort = try XCTUnwrap(listener.localAddress?.port)
        try await listener.close()

        let onBastion = await classify {
            _ = try await TestSSH.connect(target, jumpHost: SSHJumpHost(
                host: "127.0.0.1", port: closedPort, username: TestSSH.username, credential: .password(TestSSH.password)))
        }
        XCTAssertEqual(onBastion, .network)

        // 跳板机连得上，它连不上目标（目标端口没人听）：跳板机回原因码 2。
        let bastion = try await TestSSH.startServer()
        defer { Task { await bastion.stop() } }
        let onTarget = await classify {
            _ = try await SSHClientFactory.connect(
                endpoint: SSHEndpoint(host: "127.0.0.1", port: closedPort, username: TestSSH.username,
                                      jumpHost: self.jump(bastion)),
                credential: .password(TestSSH.password), hostKeyStore: MemoryHostKeyStore(),
                hostKeyPolicy: .insecureAcceptAll, connectTimeout: .seconds(10), approvalTimeout: .seconds(10),
                approver: { _ in true }, legacyMemory: SSHLegacyEndpointMemory())
        }
        XCTAssertEqual(onTarget, .network)
    }
}

/// 多步认证：钥匙通过了，服务器还要口令（或一次性验证码），凭据里没有——报的是「还要另一种认证」，不是
/// 「服务器拒绝了私钥」；归 `.authenticationFailed`（重试不会好）。
final class PartialAuthenticationTests: XCTestCase {
    func testKeyAcceptedButAnotherStepRequired() async throws {
        let generated = SSHKeyGenerator.generateEd25519(comment: "t")
        let publicKey = try TestSSH.publicKey(ofPrivateKey: generated.privateKeyText)
        var authentication = SSHTestAuthentication(authorizedKeys: [TestSSH.username: [publicKey]])
        authentication.decision = { attempt in
            if case .publicKey = attempt.method { return .partialSuccess(remaining: .password) }
            return .reject
        }
        let server = try await TestSSH.startServer(authentication: authentication)
        defer { Task { await server.stop() } }
        let message = await assertConnectionError({
            _ = try await TestSSH.connect(server, credential: .privateKey(pem: generated.privateKeyText, passphrase: nil))
        }) { if case .authenticationFailed(let message) = $0 { return message } else { return nil } }
        let expected = SSHErrorText.describe(SSHAuthenticationFailure(
            remainingMethods: .password, attemptedMethods: [.publicKey], partiallyAcceptedMethods: [.publicKey]))
        XCTAssertEqual(message, SSHClientError.authenticationFailed(SSHAuthenticationFailure(
            remainingMethods: .password, attemptedMethods: [.publicKey], partiallyAcceptedMethods: [.publicKey])).errorDescription)
        XCTAssertTrue(message?.contains(expected) == true, message ?? "")
        XCTAssertNotEqual(expected, String(localized: "服务器拒绝了私钥", bundle: ModuleBundle.bundle))
        XCTAssertEqual(server.events.authAttempts.count, 1)
    }
}
