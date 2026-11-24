import Crypto
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOPosix
@testable import NIOSSH
@testable import USSHCore
import USSHTestServer
import XCTest

/// 第二轮审查的回归测试：建连（Happy Eyeballs、DNS、超时、泄漏的 promise）、跳板机卡死、取消、
/// 认证细节、主机密钥重新交换、保活。
final class SSHClientResilienceTests: XCTestCase {
    // MARK: - #1 Happy Eyeballs

    func testLocalhostWhenServerListensOnIPv4Only() async throws {
        // localhost 解析出 ::1 和 127.0.0.1；::1 上没人监听，那次尝试会被拒绝，不能把赢的那次带坏。
        let server = try await SSHTestServer.start(Harness.serverConfiguration(exec: .scripted(stdout: "v4")),
                                                   bindHost: "127.0.0.1")
        defer { Task { await server.stop() } }
        for _ in 0..<5 {
            let client = try await SSHClient.connect(host: "localhost", port: server.port,
                                                     configuration: Harness.clientConfiguration())
            let output = try await client.executeCommand("x")
            XCTAssertEqual(String(buffer: output), "v4")
            await client.close()
        }
    }

    func testLocalhostWhenServerListensOnIPv6Only() async throws {
        let server: SSHTestServer
        do {
            server = try await SSHTestServer.start(Harness.serverConfiguration(exec: .scripted(stdout: "v6")),
                                                   bindHost: "::1")
        } catch {
            throw XCTSkip("本机绑不了 ::1：\(error)")
        }
        defer { Task { await server.stop() } }
        for _ in 0..<5 {
            let client = try await SSHClient.connect(host: "localhost", port: server.port,
                                                     configuration: Harness.clientConfiguration())
            let output = try await client.executeCommand("x")
            XCTAssertEqual(String(buffer: output), "v6")
            await client.close()
        }
    }

    func testFirstResolvedAddressUnreachable() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration(exec: .scripted(stdout: "ok")))
        defer { Task { await server.stop() } }
        // 第一个地址是黑洞（TEST-NET-1，连接挂住或不可达），第二个才是服务端。
        let resolver = FixedResolver(
            a: [try SocketAddress(ipAddress: "192.0.2.1", port: server.port),
                try SocketAddress(ipAddress: "127.0.0.1", port: server.port)],
            aaaa: [])
        let client = try await SSHClient.connect(host: "multi.test", port: server.port,
                                                 configuration: Harness.clientConfiguration(), resolver: resolver)
        let output = try await client.executeCommand("x")
        XCTAssertEqual(String(buffer: output), "ok")
        XCTAssertTrue(client.isConnected)
        await client.close()
    }

    // MARK: - #6 没装上就没有 promise（Debug 下泄漏的 promise 会崩）

    func testDNSFailureIsTypedAndDoesNotLeak() async throws {
        await XCTAssertThrowsAsync(try await SSHClient.connect(
            host: "no-such-host.invalid", port: 22, configuration: Harness.clientConfiguration())) { error in
            guard case SSHClientError.connectFailed = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testConnectTimeoutBeforeAnyChannel() async throws {
        var configuration = Harness.clientConfiguration()
        configuration.connectTimeout = .milliseconds(300)
        let resolver = FixedResolver(a: [try SocketAddress(ipAddress: "192.0.2.1", port: 22)], aaaa: [])
        let start = ContinuousClock.now
        await XCTAssertThrowsAsync(try await SSHClient.connect(
            host: "blackhole.test", port: 22, configuration: configuration, resolver: resolver)) { error in
            switch error {
            case SSHClientError.connectTimeout, SSHClientError.connectFailed: break
            default: XCTFail("unexpected \(error)")
            }
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(3))
    }

    func testJumpOnDisconnectedOuterConnection() async throws {
        let bastion = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await bastion.stop() } }
        let outer = try await Harness.connect(bastion)
        await outer.close()
        await XCTAssertThrowsAsync(try await outer.jump(
            to: "127.0.0.1", port: bastion.port, configuration: Harness.clientConfiguration())) { error in
            guard case SSHChannelError.connectionClosed(.localClose) = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testConnectOnClosedChannelFailsCleanly() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelOption(.autoRead, value: false)
            .connect(host: server.host, port: server.port).get()
        try await channel.close()
        await XCTAssertThrowsAsync(try await SSHClient.connect(
            on: channel, host: server.host, port: server.port, configuration: Harness.clientConfiguration())) { error in
            switch error {
            case SSHClientError.connectFailed, SSHClientError.connectionClosed: break
            default: XCTFail("unexpected \(error)")
            }
        }
    }

    // MARK: - #2 跳板机外层卡死

    /// 外层 direct-tcpip 开成、内层握手进行中时外层链路卡死：内层握手时限照样生效。
    func testJumpHandshakeTimeoutWhenOuterLinkStalls() async throws {
        let bastion = try await SSHTestServer.start(Harness.serverConfiguration())
        var targetConfiguration = Harness.serverConfiguration()
        targetConfiguration.faults.withholdServerVersion = true
        let target = try await SSHTestServer.start(targetConfiguration)
        defer { Task { await bastion.stop(); await target.stop() } }
        let outer = try await Harness.connect(bastion)
        defer { Task { await outer.close(gracePeriod: .milliseconds(10)) } }

        let freezer = Task {
            try await bastion.waitForEvents { !$0.directTCPIPTargets.isEmpty }
            await bastion.freezeAllConnections()
        }
        let start = ContinuousClock.now
        await XCTAssertThrowsAsync(try await outer.jump(
            to: target.host, port: target.port,
            configuration: Harness.clientConfiguration(handshakeTimeout: .milliseconds(600)))) { error in
            guard case SSHClientError.handshakeTimeout = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(3))
        _ = try await freezer.value
    }

    func testCancellingJumpOnStalledOuterLinkReturnsPromptly() async throws {
        let bastion = try await SSHTestServer.start(Harness.serverConfiguration())
        var targetConfiguration = Harness.serverConfiguration()
        targetConfiguration.faults.withholdServerVersion = true
        let target = try await SSHTestServer.start(targetConfiguration)
        defer { Task { await bastion.stop(); await target.stop() } }
        let outer = try await Harness.connect(bastion)
        defer { Task { await outer.close(gracePeriod: .milliseconds(10)) } }

        let jump = Task {
            try await outer.jump(to: target.host, port: target.port,
                                 configuration: Harness.clientConfiguration(handshakeTimeout: .seconds(60)))
        }
        try await bastion.waitForEvents { !$0.directTCPIPTargets.isEmpty }
        await bastion.freezeAllConnections()
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        jump.cancel()
        await XCTAssertThrowsAsync(try await jump.value) { error in
            XCTAssertTrue(error is CancellationError, "unexpected \(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    // MARK: - #9 取消

    func testCancelledConnectThrowsCancellation() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Harness.connect(server)
        }
        await XCTAssertThrowsAsync(try await task.value) { error in
            XCTAssertTrue(error is CancellationError, "unexpected \(error)")
        }
        let closed = await Harness.eventually { server.connectionCount == 0 }
        XCTAssertTrue(closed)
    }

    // MARK: - #11 withTimeout 不丢结果

    func testWithTimeoutHandsLateResultToDiscard() async throws {
        let discarded = NIOLockedValueBox<[Int]>([])
        await XCTAssertThrowsAsync(try await withTimeout(
            .milliseconds(20), onTimeout: SSHChannelError.timeout(.milliseconds(20)),
            discard: { value in discarded.withLockedValue { $0.append(value) } }
        ) {
            // 不响应取消的操作：计时器先到，结果晚一点才出来。
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { continuation.resume() }
            }
            return 42
        }) { error in
            guard case SSHChannelError.timeout = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(discarded.withLockedValue { $0 }, [42])
    }

    // MARK: - #13 认证细节

    func testFailingDelegateIsReportedAsDelegateFailure() async throws {
        struct KeychainLocked: Error, Equatable {}
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        await XCTAssertThrowsAsync(try await Harness.connect(
            server, Harness.clientConfiguration([.delegate(FailingDelegate(error: KeychainLocked()))]))) { error in
            guard case SSHClientError.authenticationDelegateFailed(let underlying) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(underlying as? KeychainLocked, KeychainLocked())
        }
    }

    func testCredentialsAreDroppedAfterAuthentication() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        let weakDelegate = WeakBox<OneShotPasswordDelegate>()
        let client: SSHClient
        do {
            let delegate = OneShotPasswordDelegate(username: Harness.username, password: Harness.password)
            weakDelegate.set(delegate)
            client = try await Harness.connect(server, Harness.clientConfiguration([.delegate(delegate)]))
        }
        XCTAssertTrue(client.isConnected)
        // 连接还活着，但认证材料（这里是委托）已经不被它持有了。
        let released = await Harness.eventually { weakDelegate.isEmpty }
        XCTAssertTrue(released)
        await client.close()
    }

    func testPartialSuccessContinuesWithNextMethod() async throws {
        let key = NIOSSHPrivateKey(ed25519Key: .init())
        var configuration = Harness.serverConfiguration(keys: [key.publicKey])
        configuration.authentication.decision = { attempt in
            switch attempt.method {
            case .password: return .partialSuccess(remaining: .publicKey)
            case .publicKey(let offered): return offered == key.publicKey ? .accept : .reject
            case .none: return .reject
            }
        }
        let server = try await SSHTestServer.start(configuration)
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(
            server, Harness.clientConfiguration([.password(Harness.password), .privateKey(key)]))
        XCTAssertTrue(client.isConnected)
        XCTAssertEqual(server.events.authAttempts.map(\.method), [.password(Harness.password), .publicKey(key.publicKey)])
        await client.close()
    }

    func testServerInitiatedChannelsAreRejected() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(server)
        defer { Task { await client.close() } }
        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        for type: SSHChannelType in [
            .session,
            .directTCPIP(.init(targetHost: "127.0.0.1", targetPort: 1, originatorAddress: originator)),
            .forwardedTCPIP(.init(listeningHost: "127.0.0.1", listeningPort: 1, originatorAddress: originator)),
        ] {
            await XCTAssertThrowsAsync(try await server.openChannelToClient(type)) { error in
                XCTAssertEqual((error as? NIOSSHError)?.type, .channelSetupRejected, "unexpected \(error)")
            }
        }
        XCTAssertTrue(client.isConnected)
    }

    // MARK: - #12 重新交换密钥

    func testRekeyDoesNotCallHostKeyCallbackAgain() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration(exec: .scripted(stdout: "after")))
        defer { Task { await server.stop() } }
        let calls = Counter()
        let client = try await Harness.connect(server, Harness.clientConfiguration(hostKey: .custom { _ in
            calls.add(1)
        }))
        defer { Task { await client.close() } }
        try await server.withEachConnection { handler in try handler._rekey() }
        // 重新交换之后连接照常可用，回调只在第一次被调过。
        for _ in 0..<3 {
            let output = try await client.executeCommand("x")
            XCTAssertEqual(String(buffer: output), "after")
        }
        XCTAssertEqual(calls.value, 1)
    }

    func testHostKeyChangeOnRekeyIsRejected() throws {
        let loop = EmbeddedEventLoop()
        let clock = SSHHandshakeClock(eventLoop: loop, budget: .seconds(10))
        let delegate = SSHHostKeyDelegate(eventLoop: loop, validation: .acceptAnything, host: "h", port: 22,
                                          timeout: nil, clock: clock)
        let first = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
        let second = NIOSSHPrivateKey(ed25519Key: .init()).publicKey

        let initial = loop.makePromise(of: Void.self)
        delegate.validateHostKey(hostKey: first, validationCompletePromise: initial)
        XCTAssertNoThrow(try initial.futureResult.wait())

        let sameAgain = loop.makePromise(of: Void.self)
        delegate.validateHostKey(hostKey: first, validationCompletePromise: sameAgain)
        XCTAssertNoThrow(try sameAgain.futureResult.wait())

        let changed = loop.makePromise(of: Void.self)
        delegate.validateHostKey(hostKey: second, validationCompletePromise: changed)
        XCTAssertThrowsError(try changed.futureResult.wait()) { error in
            let changed = (error as? HostKeyRejection)?.underlying as? SSHHostKeyChangedDuringRekey
            XCTAssertEqual(changed, SSHHostKeyChangedDuringRekey(previous: first, offered: second))
        }
    }

    // MARK: - 保活

    func testPingUsesGlobalRequest() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(server)
        defer { Task { await client.close() } }
        for _ in 0..<3 { try await client.ping(timeout: .seconds(2)) }
        // 不开通道：服务端没有任何 session。
        XCTAssertTrue(server.events.execCommands.isEmpty)
        XCTAssertEqual(server.events.shellRequests, 0)
    }

    func testPingTimesOutOnFrozenLink() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(server)
        defer { Task { await client.close() } }
        await server.freezeAllConnections()
        await XCTAssertThrowsAsync(try await client.ping(timeout: .milliseconds(200))) { error in
            guard case SSHChannelError.timeout = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testKeepAliveKeepsHealthyConnectionAndDetectsDeadPeer() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        var configuration = Harness.clientConfiguration()
        configuration.keepAliveInterval = .milliseconds(100)
        configuration.keepAliveMaximumUnanswered = 2
        let client = try await Harness.connect(server, configuration)

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(client.isConnected, "healthy peer answered every probe")

        await server.freezeAllConnections()
        let start = ContinuousClock.now
        let reason = await client.waitForDisconnect()
        guard case .keepAliveTimeout(let unanswered) = reason else { return XCTFail("unexpected \(reason)") }
        XCTAssertEqual(unanswered, 2)
        // 判死大约要 interval × (max + 1) = 300 ms。
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }
}

/// 固定答案的解析器。
final class FixedResolver: Resolver, Sendable {
    let a: [SocketAddress]
    let aaaa: [SocketAddress]

    init(a: [SocketAddress], aaaa: [SocketAddress]) {
        self.a = a
        self.aaaa = aaaa
    }

    func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        MultiThreadedEventLoopGroup.singleton.next().makeSucceededFuture(a)
    }

    func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        MultiThreadedEventLoopGroup.singleton.next().makeSucceededFuture(aaaa)
    }

    func cancelQueries() {}
}

/// 以错误完成 promise 的认证委托（比如读钥匙串失败）。
final class FailingDelegate: NIOSSHClientUserAuthenticationDelegate, Sendable {
    let error: any Error

    init(error: any Error) {
        self.error = error
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        nextChallengePromise.fail(error)
    }
}

/// 线程安全的弱引用盒子。
final class WeakBox<T: AnyObject & Sendable>: Sendable {
    private struct Weak: @unchecked Sendable {
        // 只经下面的锁读写；T 本身是 Sendable，弱引用本身只是可能变 nil，所以 @unchecked 是安全的。
        weak var value: T?
    }

    private let storage = NIOLockedValueBox(Weak())

    func set(_ value: T) {
        storage.withLockedValue { $0.value = value }
    }

    var isEmpty: Bool { storage.withLockedValue { $0.value == nil } }
}
