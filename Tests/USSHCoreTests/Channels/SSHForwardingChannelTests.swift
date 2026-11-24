import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
@testable import USSHCore
import USSHTestServer
import XCTest

final class SSHForwardingChannelTests: XCTestCase {
    private let originator = try! SocketAddress(ipAddress: "127.0.0.1", port: 0)

    // MARK: - subsystem

    func testSubsystemChannelCarriesPlainBytes() async throws {
        var configuration = Harness.serverConfiguration()
        configuration.subsystems["echo"] = { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(ByteEchoHandler())
            }
        }
        let server = try await SSHTestServer.start(configuration)
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(server)
        defer { Task { await client.close() } }

        // 不带 initializer：返回之后自己包。
        let channel = try await client.openSubsystemChannel("echo")
        let asyncChannel = try await channel.eventLoop.submit {
            try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
        }.get()
        let reply = try await asyncChannel.executeThenClose { inbound, outbound in
            try await outbound.write(ByteBuffer(string: "ping"))
            var iterator = inbound.makeAsyncIterator()
            return try await iterator.next().map { String(buffer: $0) }
        }
        XCTAssertEqual(reply, "ping")
        XCTAssertEqual(server.events.subsystems, ["echo"])

        // 带 initializer：在 SUCCESS 的同一个 tick 里装 handler。
        let collected = NIOLockedValueBox("")
        let second = try await client.openSubsystemChannel("echo") { channel in
            try channel.pipeline.syncOperations.addHandler(StringCollector(into: collected))
        }
        try await second.writeAndFlush(ByteBuffer(string: "again"))
        let echoed = await Harness.eventually { collected.withLockedValue { $0 } == "again" }
        XCTAssertTrue(echoed)
        try await second.close()
    }

    // MARK: - direct-tcpip

    func testDirectTCPIPWithHalfClosureFromClient() async throws {
        let echo = try await EchoServer.start()
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop(); await echo.stop() } }
        let client = try await Harness.connect(server)
        defer { Task { await client.close() } }

        let channel = try await client.openDirectTCPIPAsyncChannel(
            targetHost: "127.0.0.1", targetPort: echo.port, originatorAddress: originator)
        let received = try await channel.executeThenClose { inbound, outbound in
            try await outbound.write(ByteBuffer(string: "hello "))
            try await outbound.write(ByteBuffer(string: "tunnel"))
            // 本端 EOF：回显服务收到 FIN 后回完数据再关，入站随之结束。
            outbound.finish()
            var text = ""
            for try await buffer in inbound { text += String(buffer: buffer) }
            return text
        }
        XCTAssertEqual(received, "hello tunnel")
        XCTAssertEqual(server.events.directTCPIPTargets, ["127.0.0.1:\(echo.port)"])
    }

    func testDirectTCPIPServerFirstProtocolDoesNotLoseGreeting() async throws {
        // 目标一连上就先发问候（MySQL 之类），包装必须在激活之前完成，否则首包会丢。
        let greeter = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(Greeter())
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop(); try? await greeter.close() } }
        let client = try await Harness.connect(server)
        defer { Task { await client.close() } }

        for _ in 0..<5 {
            let channel = try await client.openDirectTCPIPAsyncChannel(
                targetHost: "127.0.0.1", targetPort: greeter.localAddress!.port!, originatorAddress: originator)
            let greeting = try await channel.executeThenClose { inbound, _ in
                var iterator = inbound.makeAsyncIterator()
                return try await iterator.next().map { String(buffer: $0) }
            }
            XCTAssertEqual(greeting, "220 hello\r\n")
        }
    }

    func testDirectTCPIPHalfClosureFromServerSide() async throws {
        // 目标先关写（发完就 FIN）：本端入站结束，出站照样能写，目标收得到。
        let received = NIOLockedValueBox("")
        let target = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(SendThenHalfClose(received: received))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop(); try? await target.close() } }
        let client = try await Harness.connect(server)
        defer { Task { await client.close() } }

        let channel = try await client.openDirectTCPIPAsyncChannel(
            targetHost: "127.0.0.1", targetPort: target.localAddress!.port!, originatorAddress: originator)
        let greeting = try await channel.executeThenClose { inbound, outbound in
            var text = ""
            for try await buffer in inbound { text += String(buffer: buffer) }
            try await outbound.write(ByteBuffer(string: "after-eof"))
            let delivered = await Harness.eventually { received.withLockedValue { $0 } == "after-eof" }
            XCTAssertTrue(delivered)
            return text
        }
        XCTAssertEqual(greeting, "bye")
    }

    func testDirectTCPIPToClosedPortIsRejected() async throws {
        let probe = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).get()
        let port = probe.localAddress!.port!
        try await probe.close()
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(server)
        defer { Task { await client.close() } }
        await XCTAssertThrowsAsync(try await client.openDirectTCPIP(
            targetHost: "127.0.0.1", targetPort: port, originatorAddress: originator,
            initializer: { $0.eventLoop.makeSucceededVoidFuture() })) { error in
            guard case SSHChannelError.openRejected(let failure) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(failure.reason, .connectFailed)
            XCTAssertEqual(failure.reasonCode, 2)
        }
        XCTAssertTrue(client.isConnected)
    }

    func testDirectTCPIPInitializerRunsBeforeActivationOnChildLoop() async throws {
        let echo = try await EchoServer.start()
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop(); await echo.stop() } }
        let client = try await Harness.connect(server)
        defer { Task { await client.close() } }
        let observed = NIOLockedValueBox<(onLoop: Bool, active: Bool)?>(nil)
        let channel = try await client.openDirectTCPIP(
            targetHost: "127.0.0.1", targetPort: echo.port, originatorAddress: originator
        ) { child in
            observed.withLockedValue { $0 = (child.eventLoop.inEventLoop, child.isActive) }
            return child.eventLoop.makeSucceededVoidFuture()
        }
        let seen = try XCTUnwrap(observed.withLockedValue { $0 })
        XCTAssertTrue(seen.onLoop)
        XCTAssertFalse(seen.active)
        XCTAssertTrue(channel.isActive)
        try await channel.close()
    }

    // MARK: - 远程转发

    func testRemotePortForwardRoundTripAndCancel() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(server)
        defer { Task { await client.close() } }

        let forward = try await client.startRemotePortForward(host: "127.0.0.1", port: 0) { channel, info in
            XCTAssertEqual(info.listeningHost, "127.0.0.1")
            return channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(ByteEchoHandler())
            }
        }
        XCTAssertGreaterThan(forward.boundPort, 0)
        XCTAssertEqual(server.events.remoteForwards, ["127.0.0.1:\(forward.boundPort)"])

        let reply = try await Self.roundTrip(port: forward.boundPort, message: "through -R")
        XCTAssertEqual(reply, "through -R")

        await forward.cancel()
        XCTAssertEqual(server.events.cancelledRemoteForwards, ["127.0.0.1:\(forward.boundPort)"])
        await XCTAssertThrowsAsync(try await Self.roundTrip(port: forward.boundPort, message: "x"))
    }

    func testWithRemotePortForwardScope() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(server)
        defer { Task { await client.close() } }

        let bound = NIOLockedValueBox<Int?>(nil)
        let scope = Task {
            try await client.withRemotePortForward(host: "127.0.0.1", port: 0, onOpen: { port in
                bound.withLockedValue { $0 = port }
            }, onAccept: { channel, _ in
                try? await channel.executeThenClose { inbound, outbound in
                    for try await buffer in inbound {
                        try await outbound.write(buffer)
                    }
                }
            })
        }
        let opened = await Harness.eventually { bound.withLockedValue { $0 } != nil }
        XCTAssertTrue(opened)
        let port = try XCTUnwrap(bound.withLockedValue { $0 })
        let replies = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<4 {
                group.addTask { try await Self.roundTrip(port: port, message: "conn-\(index)") }
            }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        XCTAssertEqual(Set(replies), Set((0..<4).map { "conn-\($0)" }))
        scope.cancel()
        try await scope.value
        try await server.waitForEvents { $0.cancelledRemoteForwards == ["127.0.0.1:\(port)"] }
    }

    func testRemotePortForwardRejected() async throws {
        var configuration = Harness.serverConfiguration()
        configuration.allowsRemoteForwarding = false
        let server = try await SSHTestServer.start(configuration)
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(server)
        defer { Task { await client.close() } }
        await XCTAssertThrowsAsync(try await client.startRemotePortForward(host: "127.0.0.1", port: 0) { channel, _ in
            channel.eventLoop.makeSucceededVoidFuture()
        }) { error in
            guard case SSHChannelError.globalRequestRejected(.tcpipForward(host: "127.0.0.1", port: 0)) = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertTrue(client.isConnected)
    }

    /// 连本机端口，写一句，半关，读回全部。
    static func roundTrip(port: Int, message: String) async throws -> String {
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelOption(.allowRemoteHalfClosure, value: true)
            .connect(host: "127.0.0.1", port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                        wrappingChannelSynchronously: channel,
                        configuration: .init(isOutboundHalfClosureEnabled: true))
                }
            }
        return try await channel.executeThenClose { inbound, outbound in
            try await outbound.write(ByteBuffer(string: message))
            var text = ""
            var iterator = inbound.makeAsyncIterator()
            while text.count < message.count, let buffer = try await iterator.next() {
                text += String(buffer: buffer)
            }
            return text
        }
    }
}

/// 收到什么回什么（ByteBuffer 管道上）。
final class ByteEchoHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

/// 把收到的字节拼成字符串。
final class StringCollector: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let box: NIOLockedValueBox<String>

    init(into box: NIOLockedValueBox<String>) {
        self.box = box
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        box.withLockedValue { $0 += String(buffer: buffer) }
    }
}

/// 连上就发 "bye" 并关掉写方向，然后继续读（读到的记下来）。
final class SendThenHalfClose: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let received: NIOLockedValueBox<String>

    init(received: NIOLockedValueBox<String>) {
        self.received = received
    }

    func channelActive(context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: "bye")), promise: nil)
        context.close(mode: .output, promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        received.withLockedValue { $0 += String(buffer: buffer) }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event { context.close(promise: nil) }
    }
}

/// 一连上就发问候。
final class Greeter: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelActive(context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: "220 hello\r\n")), promise: nil)
        context.fireChannelActive()
    }
}
