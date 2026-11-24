import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
@testable import USSHCore
import USSHTestServer
import XCTest

/// 第二轮审查的回归测试：通道层的取消、断开原因、远程转发登记、半关闭、内存上限、API 陷阱。
final class SSHChannelLifecycleTests: XCTestCase {
    private let originator = try! SocketAddress(ipAddress: "127.0.0.1", port: 0)

    private func start(_ exec: SSHTestExecHandler = .notFound) async throws -> (SSHTestServer, SSHClient) {
        let server = try await SSHTestServer.start(Harness.serverConfiguration(exec: exec))
        let client = try await Harness.connect(server)
        return (server, client)
    }

    // MARK: - #3 卡死的链路上，取消要能立刻返回

    func testCancellingOpenExecOnFrozenLink() async throws {
        let (server, client) = try await start()
        defer { Task { await client.close(gracePeriod: .milliseconds(10)); await server.stop() } }
        await server.freezeAllConnections()
        let task = Task { try await client.openExec("never-answered") }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        await XCTAssertThrowsAsync(try await task.value) { error in
            XCTAssertTrue(error is CancellationError, "unexpected \(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testCancellingOpenShellAfterChannelOpenedOnFrozenLink() async throws {
        // 通道开成之后、pty-req / shell 的回应到来之前卡死。
        var configuration = Harness.serverConfiguration()
        configuration.acceptedEnvironmentNames = []
        let server = try await SSHTestServer.start(configuration)
        let client = try await Harness.connect(server)
        defer { Task { await client.close(gracePeriod: .milliseconds(10)); await server.stop() } }
        // 先开一条通道确认链路正常，再冻结；shell 请求的回应永远不来。
        let first = try await client.openExec("x")
        await first.close()
        await server.freezeAllConnections()
        let task = Task { try await client.openShell() }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        await XCTAssertThrowsAsync(try await task.value) { error in
            XCTAssertTrue(error is CancellationError, "unexpected \(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testRemoteForwardCancelIsBoundedOnFrozenLink() async throws {
        let (server, client) = try await start()
        defer { Task { await client.close(gracePeriod: .milliseconds(10)); await server.stop() } }
        let forward = try await client.startRemotePortForward(host: "127.0.0.1", port: 0) { channel, _ in
            channel.eventLoop.makeSucceededVoidFuture()
        }
        await server.freezeAllConnections()
        let start = ContinuousClock.now
        await forward.cancel(timeout: .milliseconds(200))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testWithRemotePortForwardReturnsPromptlyWhenCancelledOnFrozenLink() async throws {
        let (server, client) = try await start()
        defer { Task { await client.close(gracePeriod: .milliseconds(10)); await server.stop() } }
        let opened = NIOLockedValueBox(false)
        let scope = Task {
            try await client.withRemotePortForward(host: "127.0.0.1", port: 0, onOpen: { _ in
                opened.withLockedValue { $0 = true }
            }, onAccept: { channel, _ in
                try? await channel.executeThenClose { _, _ in }
            })
        }
        let ready = await Harness.eventually { opened.withLockedValue { $0 } }
        XCTAssertTrue(ready)
        await server.freezeAllConnections()
        let start = ContinuousClock.now
        scope.cancel()
        _ = await scope.result
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    // MARK: - #4 远程转发登记按请求区分

    func testDuplicateForwardRequestDoesNotBreakTheLiveOne() async throws {
        let (server, client) = try await start()
        defer { Task { await client.close(); await server.stop() } }
        let live = try await client.startRemotePortForward(host: "127.0.0.1", port: 0) { channel, _ in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(PrefixEchoHandler(prefix: "live:"))
            }
        }
        // 同一个端口再请求一次：服务端绑不上、拒绝。
        await XCTAssertThrowsAsync(try await client.startRemotePortForward(host: "127.0.0.1", port: live.boundPort) {
            channel, _ in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(PrefixEchoHandler(prefix: "dup:"))
            }
        }) { error in
            guard case SSHChannelError.globalRequestRejected = error else { return XCTFail("unexpected \(error)") }
        }
        let reply = try await SSHForwardingChannelTests.roundTrip(port: live.boundPort, message: "hello")
        XCTAssertEqual(reply, "live:hello")
        await live.cancel()
    }

    func testConcurrentPortZeroForwardsRouteToTheirOwnInitializers() async throws {
        let (server, client) = try await start()
        defer { Task { await client.close(); await server.stop() } }
        async let first = client.startRemotePortForward(host: "127.0.0.1", port: 0) { channel, _ in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(PrefixEchoHandler(prefix: "A:"))
            }
        }
        async let second = client.startRemotePortForward(host: "127.0.0.1", port: 0) { channel, _ in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(PrefixEchoHandler(prefix: "B:"))
            }
        }
        let (a, b) = try await (first, second)
        XCTAssertNotEqual(a.boundPort, b.boundPort)
        let replyA = try await SSHForwardingChannelTests.roundTrip(port: a.boundPort, message: "x")
        let replyB = try await SSHForwardingChannelTests.roundTrip(port: b.boundPort, message: "y")
        XCTAssertEqual(replyA, "A:x")
        XCTAssertEqual(replyB, "B:y")
        // 撤销一个不影响另一个。
        await a.cancel()
        let again = try await SSHForwardingChannelTests.roundTrip(port: b.boundPort, message: "z")
        XCTAssertEqual(again, "B:z")
        await b.cancel()
    }

    // MARK: - #5 断开原因

    func testOutputReportsLocalCloseAfterClientClose() async throws {
        let (server, client) = try await start()
        defer { Task { await server.stop() } }
        let shell = try await client.openShell()
        var iterator = shell.output.makeAsyncIterator()
        try await shell.write(ByteBuffer(string: "ping"))
        _ = try await iterator.next()
        await client.close()
        do {
            while try await iterator.next() != nil {}
            XCTFail("expected the output to fail")
        } catch SSHChannelError.connectionClosed(let reason) {
            XCTAssertTrue(reason.isLocalClose, "unexpected \(reason)")
        }
        XCTAssertTrue(client.disconnectReason?.isLocalClose ?? false)
    }

    func testOutputReportsRemoteCloseAfterCleanShutdown() async throws {
        let (server, client) = try await start()
        defer { Task { await server.stop() } }
        let shell = try await client.openShell()
        var iterator = shell.output.makeAsyncIterator()
        try await shell.write(ByteBuffer(string: "ping"))
        _ = try await iterator.next()
        await server.dropAllConnections()
        do {
            while try await iterator.next() != nil {}
            XCTFail("expected the output to fail")
        } catch SSHChannelError.connectionClosed(let reason) {
            guard case .remoteClosed = reason else { return XCTFail("unexpected \(reason)") }
        }
        // 断开之后写入也报连接已断，不是通道错误。
        await XCTAssertThrowsAsync(try await shell.write(ByteBuffer(string: "late"))) { error in
            guard case SSHChannelError.connectionClosed(.remoteClosed) = error else { return XCTFail("unexpected \(error)") }
        }
    }

    // MARK: - #7 半关闭（NIOSSH 补丁 0004）

    func testLocalHalfCloseWhilePeerEOFIsStillBuffered() async throws {
        // 目标发完数据就关写端；本端先不读（数据和对端 EOF 都还在缓冲里），写完自己的再半关，
        // 两个方向的数据与 EOF 都要送到，通道干净关闭。
        let received = NIOLockedValueBox("")
        let sawEOF = NIOLockedValueBox(false)
        let target = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        SendCloseAndRecord(payload: String(repeating: "d", count: 100_000), received: received, sawEOF: sawEOF))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let (server, client) = try await start()
        defer { Task { await client.close(); await server.stop(); try? await target.close() } }

        let channel = try await client.openDirectTCPIPAsyncChannel(
            targetHost: "127.0.0.1", targetPort: target.localAddress!.port!, originatorAddress: originator)
        let downloaded = try await channel.executeThenClose { inbound, outbound in
            // 不读：让对端的数据和 EOF 都压在本端。
            try await Task.sleep(for: .milliseconds(300))
            try await outbound.write(ByteBuffer(string: "upload"))
            outbound.finish()
            let delivered = await Harness.eventually {
                received.withLockedValue { $0 } == "upload" && sawEOF.withLockedValue { $0 }
            }
            XCTAssertTrue(delivered, "target got \(received.withLockedValue { $0 }.count) bytes, EOF \(sawEOF.withLockedValue { $0 }), events \(server.events.directTCPIPTargets)")
            var count = 0
            for try await buffer in inbound { count += buffer.readableBytes }
            return count
        }
        XCTAssertEqual(downloaded, 100_000)
    }

    // MARK: - #8 慢消费者的内存上限

    func testSlowButActiveConsumerStaysWithinTwoWindows() async throws {
        let chunkSize = 64 * 1024
        let chunkCount = 160   // 10 MiB
        let written = Counter()
        var chunk = ByteBuffer()
        chunk.writeRepeatingByte(0x61, count: chunkSize)
        let payload = chunk
        let server = try await SSHTestServer.start(Harness.serverConfiguration(exec: SSHTestExecHandler { context in
            for _ in 0..<chunkCount {
                try await context.write(payload)
                written.add(payload.readableBytes)
            }
            return .status(0)
        }))
        var configuration = Harness.clientConfiguration()
        configuration.maximumPacketSize = 32 * 1024   // 窗口 2 MiB
        let client = try await Harness.connect(server, configuration)
        defer { Task { await client.close(); await server.stop() } }

        let window = configuration.channelWindowSize
        let handle = try await client.openExec("produce")
        var consumed = 0
        var worst = 0
        for try await piece in handle.output {
            consumed += piece.buffer.readableBytes
            worst = max(worst, written.value - consumed)
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(consumed, chunkSize * chunkCount)
        // 文档写的上限：约 2 个窗口（再加服务端一次写的量）。
        XCTAssertLessThanOrEqual(worst, 2 * window + 2 * chunkSize, "buffered \(worst) bytes with a \(window)-byte window")
    }

    // MARK: - #10 subsystem initializer 抛错

    func testSubsystemInitializerErrorIsThrown() async throws {
        struct SetupFailed: Error, Equatable {}
        var configuration = Harness.serverConfiguration()
        configuration.subsystems["echo"] = { $0.eventLoop.makeSucceededVoidFuture() }
        let server = try await SSHTestServer.start(configuration)
        let client = try await Harness.connect(server)
        defer { Task { await client.close(); await server.stop() } }
        await XCTAssertThrowsAsync(try await client.openSubsystemChannel("echo") { _ in throw SetupFailed() }) { error in
            XCTAssertEqual(error as? SetupFailed, SetupFailed(), "unexpected \(error)")
        }
        XCTAssertTrue(client.isConnected)
    }

    // MARK: - API 陷阱：没人读输出时 exitStatus() 不会卡死

    func testExitStatusWithoutConsumerDoesNotDeadlock() async throws {
        var chunk = ByteBuffer()
        chunk.writeRepeatingByte(0x7a, count: 64 * 1024)
        let payload = chunk
        let (server, client) = try await start(SSHTestExecHandler { context in
            for _ in 0..<512 { try await context.write(payload) }   // 32 MiB，远超一个窗口
            return .status(7)
        })
        defer { Task { await client.close(); await server.stop() } }
        let handle = try await client.openExec("noisy")
        let status = try await withTimeout(.seconds(20), onTimeout: SSHChannelError.timeout(.seconds(20))) {
            await handle.exitStatus()
        }
        XCTAssertEqual(status, .exited(7))
    }

    // MARK: - 开通道失败的原因码

    func testOpenFailureReasonCodes() async throws {
        let (server, client) = try await start()
        defer { Task { await client.close(); await server.stop() } }
        let probe = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).get()
        let port = probe.localAddress!.port!
        try await probe.close()
        await XCTAssertThrowsAsync(try await client.openDirectTCPIPAsyncChannel(
            targetHost: "127.0.0.1", targetPort: port, originatorAddress: originator)) { error in
            guard case SSHChannelError.openRejected(let failure) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(failure.reason, .connectFailed)
        }
        XCTAssertEqual(SSHChannelOpenFailure(reasonCode: 1, description: "").reason, .administrativelyProhibited)
        XCTAssertEqual(SSHChannelOpenFailure(reasonCode: 3, description: "").reason, .unknownChannelType)
        XCTAssertEqual(SSHChannelOpenFailure(reasonCode: 4, description: "").reason, .resourceShortage)
        XCTAssertEqual(SSHChannelOpenFailure(reasonCode: 77, description: "").reason, .other(77))
    }
}

/// 回显，前面加上前缀（区分请求落到了哪个 initializer）。
final class PrefixEchoHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let prefix: String

    init(prefix: String) {
        self.prefix = prefix
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var reply = ByteBuffer(string: prefix)
        var buffer = unwrapInboundIn(data)
        reply.writeBuffer(&buffer)
        context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
    }
}

/// 连上就发 `payload` 并关写端；记下收到的数据与对端 EOF，看到 EOF 后关闭。
final class SendCloseAndRecord: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let payload: String
    let received: NIOLockedValueBox<String>
    let sawEOF: NIOLockedValueBox<Bool>

    init(payload: String, received: NIOLockedValueBox<String>, sawEOF: NIOLockedValueBox<Bool>) {
        self.payload = payload
        self.received = received
        self.sawEOF = sawEOF
    }

    func channelActive(context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: payload)), promise: nil)
        context.close(mode: .output, promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        received.withLockedValue { $0 += String(buffer: buffer) }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            sawEOF.withLockedValue { $0 = true }
            context.close(promise: nil)
        }
    }

    /// 自己先关了写端，再收到对端的 FIN：NIO 直接整条关掉、不发 inputClosed，这里也算看到了 EOF。
    func channelInactive(context: ChannelHandlerContext) {
        sawEOF.withLockedValue { $0 = true }
        context.fireChannelInactive()
    }
}
