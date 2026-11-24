import Crypto
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
@testable import USSHCore
import USSHTestServer
import XCTest

final class SSHClientConnectionTests: XCTestCase {
    // MARK: - 认证

    func testPasswordAuthentication() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(server)
        XCTAssertTrue(client.isConnected)
        XCTAssertNil(client.disconnectReason)
        XCTAssertEqual(server.events.authAttempts.map(\.accepted), [true])
        await client.close()
        XCTAssertFalse(client.isConnected)
    }

    func testWrongPasswordReportsRemainingMethods() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        await XCTAssertThrowsAsync(try await Harness.connect(server, Harness.clientConfiguration([.password("nope")]))) { error in
            guard case SSHClientError.authenticationFailed(let failure) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(failure.attemptedMethods, [.password])
            XCTAssertTrue(failure.remainingMethods.contains(.password))
            XCTAssertTrue(failure.remainingMethods.contains(.publicKey))
        }
        // 失败后连接已经关掉。
        let closed = await Harness.eventually { server.connectionCount == 0 }
        XCTAssertTrue(closed)
    }

    func testPublicKeyAuthenticationForAllBundledKeyTypes() async throws {
        let keys: [NIOSSHPrivateKey] = [
            NIOSSHPrivateKey(ed25519Key: .init()),
            NIOSSHPrivateKey(p256Key: .init()),
            NIOSSHPrivateKey(p384Key: .init()),
            NIOSSHPrivateKey(p521Key: .init()),
        ]
        let server = try await SSHTestServer.start(Harness.serverConfiguration(keys: keys.map(\.publicKey)))
        defer { Task { await server.stop() } }
        for key in keys {
            let client = try await Harness.connect(server, Harness.clientConfiguration([.privateKey(key)]))
            XCTAssertTrue(client.isConnected)
            await client.close()
        }
        XCTAssertEqual(server.events.authAttempts.count, 4)
        XCTAssertTrue(server.events.authAttempts.allSatisfy(\.accepted))
    }

    func testMethodsAreTriedInOrderAndUnavailableOnesSkipped() async throws {
        let key = NIOSSHPrivateKey(ed25519Key: .init())
        let wrongKey = NIOSSHPrivateKey(ed25519Key: .init())
        var configuration = Harness.serverConfiguration(keys: [key.publicKey])
        configuration.authentication.supportedMethods = [.publicKey]
        let server = try await SSHTestServer.start(configuration)
        defer { Task { await server.stop() } }

        // NIOSSH 第一轮不知道服务器接受什么（RFC 4252 的 "none" 探测它不发），口令会先被拒一次；
        // 之后服务器只报 publickey，列表里的口令就不会再试。先试错的钥匙，再试对的。
        let client = try await Harness.connect(
            server, Harness.clientConfiguration([
                .password(Harness.password), .password("again"), .privateKey(wrongKey), .privateKey(key),
            ]))
        XCTAssertTrue(client.isConnected)
        await client.close()
        let attempts = server.events.authAttempts
        XCTAssertEqual(attempts.map(\.accepted), [false, false, true])
        XCTAssertEqual(attempts.map(\.method), [
            .password(Harness.password), .publicKey(wrongKey.publicKey), .publicKey(key.publicKey),
        ])
    }

    func testServerAcceptingNothingWeHave() async throws {
        var configuration = Harness.serverConfiguration()
        configuration.authentication.supportedMethods = [.publicKey]
        let server = try await SSHTestServer.start(configuration)
        defer { Task { await server.stop() } }
        await XCTAssertThrowsAsync(try await Harness.connect(server)) { error in
            guard case SSHClientError.authenticationFailed(let failure) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(failure.attemptedMethods, [.password])
            XCTAssertEqual(failure.remainingMethods, .publicKey)
        }
        XCTAssertEqual(server.events.authAttempts.map(\.accepted), [false])
    }

    func testDelegatePassThroughThenNextMethod() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        let delegate = OneShotPasswordDelegate(username: Harness.username, password: "wrong")
        let client = try await Harness.connect(
            server, Harness.clientConfiguration([.delegate(delegate), .password(Harness.password)]))
        XCTAssertTrue(client.isConnected)
        XCTAssertEqual(delegate.calls, 2)
        XCTAssertEqual(server.events.authAttempts.map(\.accepted), [false, true])
        await client.close()
    }

    func testRejectedAttemptsFallThroughToNextMethod() async throws {
        var configuration = Harness.serverConfiguration()
        configuration.faults.rejectFirstAuthenticationAttempts = 2
        let server = try await SSHTestServer.start(configuration)
        defer { Task { await server.stop() } }
        let methods: [SSHAuthenticationMethod] = Array(repeating: .password(Harness.password), count: 3)
        let client = try await Harness.connect(server, Harness.clientConfiguration(methods))
        XCTAssertEqual(server.events.authAttempts.map(\.accepted), [false, false, true])
        await client.close()
    }

    // MARK: - 主机密钥

    func testTrustedHostKeys() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(
            server, Harness.clientConfiguration(hostKey: .trustedKeys([server.hostPublicKey])))
        await client.close()

        let other = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
        await XCTAssertThrowsAsync(try await Harness.connect(
            server, Harness.clientConfiguration(hostKey: .trustedKeys([other])))) { error in
            guard case SSHClientError.hostKeyRejected(let underlying) = error,
                  let untrusted = underlying as? SSHUntrustedHostKey else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(untrusted.hostKey, server.hostPublicKey)
        }
        // 主机密钥被拒绝时还没到认证。
        XCTAssertEqual(server.events.authAttempts.count, 1)
    }

    func testCustomHostKeyCallbackGetsContextAndErrorIsPreserved() async throws {
        struct Nope: Error, Equatable {}
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        let seen = NIOLockedValueBox<SSHHostKeyContext?>(nil)
        await XCTAssertThrowsAsync(try await Harness.connect(server, Harness.clientConfiguration(hostKey: .custom { context in
            seen.withLockedValue { $0 = context }
            throw Nope()
        }))) { error in
            guard case SSHClientError.hostKeyRejected(let underlying) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(underlying as? Nope, Nope())
        }
        let context = try XCTUnwrap(seen.withLockedValue { $0 })
        XCTAssertEqual(context.host, server.host)
        XCTAssertEqual(context.port, server.port)
        XCTAssertEqual(context.hostKey, server.hostPublicKey)
    }

    func testHostKeyCallbackTimeIsNotCountedTowardsHandshakeTimeout() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        let configuration = Harness.clientConfiguration(
            hostKey: .custom { _ in try await Task.sleep(for: .milliseconds(1500)) },
            handshakeTimeout: .milliseconds(700))
        let client = try await Harness.connect(server, configuration)
        XCTAssertTrue(client.isConnected)
        await client.close()
    }

    func testHostKeyValidationTimeout() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        let configuration = Harness.clientConfiguration(
            hostKey: .custom { _ in
                // 不响应取消的回调也不能拖住连接。
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            },
            handshakeTimeout: .seconds(10),
            hostKeyValidationTimeout: .milliseconds(200))
        let start = ContinuousClock.now
        await XCTAssertThrowsAsync(try await Harness.connect(server, configuration)) { error in
            guard case SSHClientError.hostKeyValidationTimeout(let timeout) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(timeout, .milliseconds(200))
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(3))
    }

    func testHandshakeTimeoutWhenServerIsSilent() async throws {
        var configuration = Harness.serverConfiguration()
        configuration.faults.withholdServerVersion = true
        let server = try await SSHTestServer.start(configuration)
        defer { Task { await server.stop() } }
        await XCTAssertThrowsAsync(try await Harness.connect(
            server, Harness.clientConfiguration(handshakeTimeout: .milliseconds(300)))) { error in
            guard case SSHClientError.handshakeTimeout(let timeout) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(timeout, .milliseconds(300))
        }
        let closed = await Harness.eventually { server.connectionCount == 0 }
        XCTAssertTrue(closed)
    }

    func testSlowAuthenticationCountsTowardsHandshakeTimeout() async throws {
        var configuration = Harness.serverConfiguration()
        configuration.faults.authenticationDelay = .seconds(3)
        let server = try await SSHTestServer.start(configuration)
        defer { Task { await server.stop() } }
        await XCTAssertThrowsAsync(try await Harness.connect(
            server, Harness.clientConfiguration(handshakeTimeout: .milliseconds(500)))) { error in
            guard case SSHClientError.handshakeTimeout = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testConnectRefused() async throws {
        // 先占一个端口再放掉，确保上面没人监听。
        let probe = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).get()
        let port = probe.localAddress!.port!
        try await probe.close()
        await XCTAssertThrowsAsync(try await SSHClient.connect(
            host: "127.0.0.1", port: port, configuration: Harness.clientConfiguration())) { error in
            guard case SSHClientError.connectFailed = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testCancellingConnectWhileWaitingForHostKeyApproval() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        let entered = NIOLockedValueBox(false)
        let configuration = Harness.clientConfiguration(hostKey: .custom { _ in
            entered.withLockedValue { $0 = true }
            try await Task.sleep(for: .seconds(60))
        })
        let task = Task { try await Harness.connect(server, configuration) }
        let waiting = await Harness.eventually { entered.withLockedValue { $0 } }
        XCTAssertTrue(waiting)
        task.cancel()
        await XCTAssertThrowsAsync(try await task.value) { error in
            XCTAssertTrue(error is CancellationError, "unexpected \(error)")
        }
        let closed = await Harness.eventually { server.connectionCount == 0 }
        XCTAssertTrue(closed)
    }

    func testConnectOnExistingChannel() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration(exec: .scripted(stdout: "ok")))
        defer { Task { await server.stop() } }
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelOption(.autoRead, value: false)
            .connect(host: server.host, port: server.port).get()
        let client = try await SSHClient.connect(
            on: channel, host: server.host, port: server.port, configuration: Harness.clientConfiguration())
        let output = try await client.executeCommand("anything")
        XCTAssertEqual(Harness.string(output), "ok")
        await client.close()
    }

    // MARK: - 生命周期

    func testMultipleDisconnectObserversAndRemoval() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(server)
        let calls = NIOLockedValueBox<[String]>([])
        client.onDisconnect { _ in calls.withLockedValue { $0.append("a") } }
        let removed = client.onDisconnect { _ in calls.withLockedValue { $0.append("removed") } }
        client.onDisconnect { reason in
            calls.withLockedValue { $0.append(reason.isLocalClose ? "local" : "remote") }
        }
        client.removeDisconnectObserver(removed)

        await server.dropAllConnections()
        let reason = await client.waitForDisconnect()
        XCTAssertFalse(reason.isLocalClose)
        XCTAssertEqual(calls.withLockedValue { $0 }, ["a", "remote"])
        XCTAssertFalse(client.isConnected)

        // 断开之后挂的观察者立刻回调。
        let late = NIOLockedValueBox(false)
        client.onDisconnect { _ in late.withLockedValue { $0 = true } }
        XCTAssertTrue(late.withLockedValue { $0 })
    }

    func testLocalCloseIsIdempotentAndReported() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(server)
        let reasons = NIOLockedValueBox<[SSHDisconnectReason]>([])
        client.onDisconnect { reason in reasons.withLockedValue { $0.append(reason) } }
        await client.close()
        await client.close()
        let recorded = reasons.withLockedValue { $0 }
        XCTAssertEqual(recorded.count, 1)
        XCTAssertTrue(recorded.first?.isLocalClose ?? false)
        await XCTAssertThrowsAsync(try await client.executeCommand("x")) { error in
            guard case SSHChannelError.connectionClosed(.localClose) = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testPing() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(server)
        try await client.ping(timeout: .seconds(2))
        await server.dropAllConnections()
        _ = await client.waitForDisconnect()
        await XCTAssertThrowsAsync(try await client.ping(timeout: .seconds(2))) { error in
            guard case SSHChannelError.connectionClosed = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testMaximumPacketSizeIsClamped() {
        var configuration = Harness.clientConfiguration()
        configuration.maximumPacketSize = 1
        XCTAssertEqual(configuration.effectiveMaximumPacketSize, 32_768)
        configuration.maximumPacketSize = .max
        XCTAssertEqual(configuration.effectiveMaximumPacketSize, 1 << 24)
        configuration.maximumPacketSize = 1 << 20
        XCTAssertEqual(configuration.channelWindowSize, 64 << 20)
    }

    // MARK: - 跳板机

    func testJumpThroughTwoServers() async throws {
        let bastion = try await SSHTestServer.start(Harness.serverConfiguration())
        let target = try await SSHTestServer.start(Harness.serverConfiguration(exec: .scripted(stdout: "inner")))
        defer { Task { await bastion.stop(); await target.stop() } }

        let outer = try await Harness.connect(bastion)
        var innerConfiguration = Harness.clientConfiguration(hostKey: .trustedKeys([target.hostPublicKey]))
        innerConfiguration.maximumPacketSize = 1 << 20
        let inner = try await outer.jump(to: target.host, port: target.port, configuration: innerConfiguration)
        XCTAssertEqual(bastion.events.directTCPIPTargets, ["\(target.host):\(target.port)"])
        XCTAssertEqual(inner.host, target.host)
        let output = try await inner.executeCommand("whoami")
        XCTAssertEqual(Harness.string(output), "inner")

        // 关外层，内层随之断开。
        await outer.close()
        let reason = await inner.waitForDisconnect()
        guard case .transportError = reason else { return XCTFail("unexpected \(reason)") }
        XCTAssertFalse(inner.isConnected)
    }

    func testClosingInnerJumpLeavesOuterUsable() async throws {
        let bastion = try await SSHTestServer.start(Harness.serverConfiguration(exec: .scripted(stdout: "outer")))
        let target = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await bastion.stop(); await target.stop() } }
        let outer = try await Harness.connect(bastion)
        let inner = try await outer.jump(to: target.host, port: target.port, configuration: Harness.clientConfiguration())
        await inner.close()
        XCTAssertTrue(inner.disconnectReason?.isLocalClose ?? false)
        let output = try await outer.executeCommand("x")
        XCTAssertEqual(Harness.string(output), "outer")
        await outer.close()
    }

    func testJumpToUnreachableTarget() async throws {
        let bastion = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await bastion.stop() } }
        let outer = try await Harness.connect(bastion)
        let probe = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).get()
        let port = probe.localAddress!.port!
        try await probe.close()
        await XCTAssertThrowsAsync(try await outer.jump(
            to: "127.0.0.1", port: port, configuration: Harness.clientConfiguration())) { error in
            guard case SSHChannelError.openRejected = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertTrue(outer.isConnected)
        await outer.close()
    }
}

/// 第一次给一个（错的）口令，之后放弃，让列表里的下一项接手。
final class OneShotPasswordDelegate: NIOSSHClientUserAuthenticationDelegate, Sendable {
    let username: String
    let password: String
    private let counter = NIOLockedValueBox(0)

    var calls: Int { counter.withLockedValue { $0 } }

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let call = counter.withLockedValue { value -> Int in
            value += 1
            return value
        }
        if call == 1 {
            nextChallengePromise.succeed(.init(username: username, serviceName: "", offer: .password(.init(password: password))))
        } else {
            nextChallengePromise.succeed(nil)
        }
    }
}
