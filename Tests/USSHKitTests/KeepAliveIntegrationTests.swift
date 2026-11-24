import Foundation
import NIOCore
import NIOPosix
import USSHTestServer
import XCTest
@_spi(uTermIntegration) @testable import USSHKit

/// 隧道与 SFTP 会话的保活和「死了就收」：链路卡死（`freezeAllConnections`：TCP 还在，不读不写）时，开了
/// `keepAliveInterval` 的在约 interval × 4 内判死并收掉；没开的照旧什么都察觉不到。服务器掐断 TCP 时两种都立刻收。
final class KeepAliveIntegrationTests: XCTestCase {

    private static let interval: Duration = .milliseconds(200)

    /// 线程安全地记下回调来的断开原因。
    private final class ReasonBox: @unchecked Sendable {
        private let lock = NSLock()
        private var reasons: [SSHDisconnectReason] = []
        func append(_ reason: SSHDisconnectReason) { lock.withLock { reasons.append(reason) } }
        var all: [SSHDisconnectReason] { lock.withLock { reasons } }
    }

    private func tunnel(_ server: SSHTestServer, targetPort: Int, keepAlive: Duration?,
                        reasons: ReasonBox = ReasonBox()) -> SSHLocalForwardingTunnel {
        SSHLocalForwardingTunnel(
            request: SSHForwardingRequest(endpoint: TestSSH.endpoint(server), credential: .password(TestSSH.password),
                                          targetHost: "127.0.0.1", targetPort: targetPort),
            hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: .insecureAcceptAll,
            keepAliveInterval: keepAlive, onDisconnect: { reasons.append($0) })
    }

    /// 连上本机端口，返回包好的通道（连不上抛错）。
    private func connectLocal(port: Int) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
        try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(2))
            .connect(host: "127.0.0.1", port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }
    }

    private func waitUntil(_ limit: Duration, _ condition: @escaping () async -> Bool) async throws -> Duration {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < limit {
            if await condition() { return ContinuousClock.now - start }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("等了 \(limit) 也没等到")
        return limit
    }

    /// 本机端口还被占着（绑不上）。
    private func portIsReserved(_ port: Int) async -> Bool {
        do {
            // SO_REUSEADDR：已经关掉的连接留下的 TIME_WAIT 不算「占着」，还在监听的才算。
            let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: port).get()
            try? await channel.close()
            return false
        } catch {
            return true
        }
    }

    /// 隧道死了之后连本地端口：要么连不上，要么连上就被关掉、读不到任何东西（不会在死连接上开通道）。
    private func assertLateConnectionGoesNowhere(_ port: Int, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let late = try await connectLocal(port: port)
            let got = try? await late.executeThenClose { inbound, _ -> ByteBuffer? in
                var iterator = inbound.makeAsyncIterator()
                return try await iterator.next()
            }
            XCTAssertNil(got ?? nil, "隧道死了，本地端口还在转发", file: file, line: line)
        } catch {}
    }

    // MARK: - 隧道

    func testTunnelKeepAliveDetectsAFrozenLinkAndTearsTheTunnelDown() async throws {
        let greeter = try await GreetingServer.start(greeting: "hello")
        defer { Task { try? await greeter.close() } }
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }
        let reasons = ReasonBox()
        let tunnel = tunnel(server, targetPort: greeter.port, keepAlive: Self.interval, reasons: reasons)
        let local = try await tunnel.open()
        defer { Task { await tunnel.close() } }
        let isUp = await tunnel.isConnected
        XCTAssertTrue(isUp)

        // 一条正在转发的连接：读到问候之后挂着。
        let inFlight = try await connectLocal(port: local.port)
        let ended = try await inFlight.executeThenClose { inbound, _ -> Bool in
            var iterator = inbound.makeAsyncIterator()
            let greeting = try await iterator.next().map { String(buffer: $0) }
            XCTAssertEqual(greeting, "hello")
            await server.freezeAllConnections()
            // 判死后通道随 SSH 连接一起结束：本地读到 EOF 或出错，而不是一直挂着。
            do { return try await iterator.next() == nil } catch { return true }
        }
        XCTAssertTrue(ended)

        // isConnected 跟着连接立刻变；回调在隧道收完（监听关掉、连接关掉）之后才来。
        let waited = try await waitUntil(.seconds(5)) { !reasons.all.isEmpty }
        XCTAssertLessThan(waited, .seconds(3), "约 interval × 4 = 0.8 秒就该判死")
        let isUpAfter = await tunnel.isConnected
        XCTAssertFalse(isUpAfter)
        guard case .keepAliveTimeout = reasons.all.first else {
            return XCTFail("应当以保活超时断开，实际：\(reasons.all)")
        }
        XCTAssertEqual(reasons.all.count, 1)
        let reason = await tunnel.disconnectReason
        guard case .keepAliveTimeout = reason else { return XCTFail("disconnectReason：\(String(describing: reason))") }
        // 不再转发，但端口留着（不还给系统，免得被别的进程绑上、收到 app 连接池发来的东西），close() 才释放。
        await assertLateConnectionGoesNowhere(local.port)
        let reserved = await portIsReserved(local.port)
        XCTAssertTrue(reserved, "SSH 断了之后本地端口不该还给系统")
        await tunnel.close()
        let released = await portIsReserved(local.port)
        XCTAssertFalse(released, "close() 之后端口要释放")
    }

    func testTunnelWithoutKeepAliveDoesNotNoticeAFrozenLink() async throws {
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }
        let reasons = ReasonBox()
        let tunnel = tunnel(server, targetPort: 9, keepAlive: nil, reasons: reasons)
        _ = try await tunnel.open()
        defer { Task { await tunnel.close() } }
        await server.freezeAllConnections()
        try await Task.sleep(for: .milliseconds(1500))
        let isUp = await tunnel.isConnected
        XCTAssertTrue(isUp, "没开保活：卡死的链路察觉不到（以前的行为）")
        XCTAssertTrue(reasons.all.isEmpty)
    }

    func testServerDropTearsTheTunnelDownAtOnce() async throws {
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }
        let reasons = ReasonBox()
        let tunnel = tunnel(server, targetPort: 9, keepAlive: nil, reasons: reasons)
        let local = try await tunnel.open()
        defer { Task { await tunnel.close() } }
        await server.dropAllConnections()
        _ = try await waitUntil(.seconds(3)) { !reasons.all.isEmpty }
        let isUp = await tunnel.isConnected
        XCTAssertFalse(isUp)
        guard case .remoteClosed = reasons.all.first else { return XCTFail("\(reasons.all)") }
        await assertLateConnectionGoesNowhere(local.port)
        let reserved = await portIsReserved(local.port)
        XCTAssertTrue(reserved)
    }

    func testLocalCloseIsNotReportedAsADisconnect() async throws {
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }
        let reasons = ReasonBox()
        let tunnel = tunnel(server, targetPort: 9, keepAlive: Self.interval, reasons: reasons)
        _ = try await tunnel.open()
        await tunnel.close()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(reasons.all.isEmpty)
        let isUp = await tunnel.isConnected
        XCTAssertFalse(isUp)
        let reason = await tunnel.disconnectReason
        XCTAssertNil(reason)
    }

    // MARK: - SFTP 会话

    private func sftpServer(_ fileSystem: SFTPLocalFileSystem) async throws -> SSHTestServer {
        try await TestSSH.startServer { $0.serveSFTP(fileSystem: fileSystem) }
    }

    private func session(_ server: SSHTestServer, keepAlive: Duration?) async throws -> SSHFileTransferSession {
        try await SSHFileTransferSession.open(
            endpoint: TestSSH.endpoint(server), credential: .password(TestSSH.password),
            hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: .insecureAcceptAll, approver: { _ in true },
            keepAliveInterval: keepAlive)
    }

    /// 计时跑 `body`，最多等 `cap`（body 不响应取消时也不等它）。
    private func timed(cap: Duration = .seconds(20), _ body: @escaping @Sendable () async -> Void) async -> Duration {
        let start = ContinuousClock.now
        let done = AsyncStream<Void>.makeStream()
        Task { await body(); done.continuation.yield() }
        Task { try? await Task.sleep(for: cap); done.continuation.yield() }
        for await _ in done.stream { break }
        return ContinuousClock.now - start
    }

    /// 链路被黑洞（没开保活，什么也察觉不到）时 `close()` 照样很快返回：以前等服务端回 CHANNEL_CLOSE，要等到保活判死
    /// （uTable 实测 120 秒），没开保活就是永远。直连与经跳板机两种；之后会话报已断、在途的请求失败。
    func testSessionCloseIsBoundedOnABlackholedLink() async throws {
        let fileSystem = try SFTPLocalFileSystem.makeTemporary(prefix: "usshkit-close")
        defer { try? fileSystem.removeRoot() }
        let target = try await sftpServer(fileSystem)
        let bastion = try await TestSSH.startServer()
        defer { Task { await target.stop(); await bastion.stop() } }
        let jump = SSHJumpHost(host: bastion.host, port: bastion.port, username: TestSSH.username,
                               credential: .password(TestSSH.password))
        for (label, jumpHost, frozen) in [("direct", nil, target), ("jump", Optional(jump), bastion)] {
            let session = try await SSHFileTransferSession.open(
                endpoint: TestSSH.endpoint(target, jumpHost: jumpHost), credential: .password(TestSSH.password),
                hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: .insecureAcceptAll, approver: { _ in true })
            _ = try await session.stat("/")
            await frozen.freezeAllConnections()
            let pending = Task { try await session.stat("/") }
            try await Task.sleep(for: .milliseconds(50))

            let elapsed = await timed { await session.close() }
            print("BOUNDED-CLOSE sftp-session-\(label) \(elapsed)")
            XCTAssertLessThan(elapsed, SSHClient.closeGracePeriod + .seconds(1), label)
            XCTAssertFalse(session.isConnected, label)
            let pendingEnded = await timed(cap: .seconds(3)) { _ = try? await pending.value }
            XCTAssertLessThan(pendingEnded, .seconds(1), "\(label): 在途请求随关闭失败")
        }
    }

    func testSessionKeepAliveDetectsAFrozenLinkAndFailsRequests() async throws {
        let fileSystem = try SFTPLocalFileSystem.makeTemporary(prefix: "usshkit-keepalive")
        defer { try? fileSystem.removeRoot() }
        try Data("x".utf8).write(to: fileSystem.rootURL.appendingPathComponent("f"))
        let server = try await sftpServer(fileSystem)
        defer { Task { await server.stop() } }
        let session = try await session(server, keepAlive: Self.interval)
        defer { Task { await session.close() } }
        _ = try await session.stat("/f")

        await server.freezeAllConnections()
        // 卡住的请求在判死时失败，而不是一直等。
        let start = ContinuousClock.now
        do {
            _ = try await session.stat("/f")
            XCTFail("链路卡死了，请求不该成功")
        } catch {}
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(3))
        // 在途请求随通道失败的那一刻，连接的状态可能还差一拍才更新。
        _ = try await waitUntil(.seconds(1)) { !session.isConnected }
        guard case .keepAliveTimeout = session.disconnectReason else {
            return XCTFail("disconnectReason：\(String(describing: session.disconnectReason))")
        }
    }

    func testSessionWithoutKeepAliveDoesNotNoticeAFrozenLink() async throws {
        let fileSystem = try SFTPLocalFileSystem.makeTemporary(prefix: "usshkit-keepalive")
        defer { try? fileSystem.removeRoot() }
        let server = try await sftpServer(fileSystem)
        defer { Task { await server.stop() } }
        let session = try await session(server, keepAlive: nil)
        defer { Task { await session.close() } }
        await server.freezeAllConnections()
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertTrue(session.isConnected)
        XCTAssertNil(session.disconnectReason)
    }

    func testSessionAfterLocalCloseHasNoDisconnectReason() async throws {
        let fileSystem = try SFTPLocalFileSystem.makeTemporary(prefix: "usshkit-keepalive")
        defer { try? fileSystem.removeRoot() }
        let server = try await sftpServer(fileSystem)
        defer { Task { await server.stop() } }
        let session = try await session(server, keepAlive: Self.interval)
        await session.close()
        XCTAssertFalse(session.isConnected)
        XCTAssertNil(session.disconnectReason)
    }
}
