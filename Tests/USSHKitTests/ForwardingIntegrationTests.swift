import NIOCore
import NIOPosix
import USSHTestServer
import XCTest
@_spi(uTermIntegration) @testable import USSHKit

/// `-L` 转发（`SSHLocalForwardingTunnel` / `LocalForwardListener`）对着进程内的服务端：本机端口 → SSH →
/// 服务端去连的 TCP 服务。
final class ForwardingIntegrationTests: XCTestCase {

    private func request(_ server: SSHTestServer, targetPort: Int) -> SSHForwardingRequest {
        SSHForwardingRequest(endpoint: TestSSH.endpoint(server), credential: .password(TestSSH.password),
                             targetHost: "127.0.0.1", targetPort: targetPort)
    }

    private final class MessageLog: SSHLogger, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var messages: [String] { lock.withLock { recorded } }
        func log(_ event: SSHLogEvent) { lock.withLock { recorded.append(event.message) } }
    }

    /// 绑 0 号端口的监听：停止时日志报实际绑上的端口（以前报请求的 0）。
    func testListenerOnPortZeroLogsTheBoundPortWhenClosed() async throws {
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }
        let connected = try await TestSSH.connect(server)
        let log = MessageLog()
        let listener = LocalForwardListener(connected: connected, listenHost: "127.0.0.1", listenPort: 0,
                                            destHost: "127.0.0.1", destPort: 9, logger: log)
        let port = try await listener.start()
        XCTAssertNotEqual(port, 0)
        await listener.close()
        await connected.close()
        let stopped = log.messages.filter { $0.hasPrefix("本地转发已停止") }
        XCTAssertEqual(stopped, ["本地转发已停止 127.0.0.1:\(port)"])
    }

    /// 本机端口收到的第一包就是远端服务先说的话（服务器先说话的协议不丢首包）。
    func testTunnelCarriesServerFirstGreeting() async throws {
        let greeter = try await GreetingServer.start(greeting: "220 ready")
        defer { Task { try? await greeter.close() } }
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }

        let tunnel = SSHLocalForwardingTunnel(
            request: request(server, targetPort: greeter.port),
            hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: .insecureAcceptAll)
        let local = try await tunnel.open()
        defer { Task { await tunnel.close() } }

        let received = try await Self.readFirstChunk(host: local.host, port: local.port)
        XCTAssertEqual(received, "220 ready")
        XCTAssertEqual(server.events.directTCPIPTargets, ["127.0.0.1:\(greeter.port)"])
    }

    func testTunnelCannotOpenTwiceOrAfterClose() async throws {
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }
        let tunnel = SSHLocalForwardingTunnel(request: request(server, targetPort: 9),
                                              hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: .insecureAcceptAll)
        _ = try await tunnel.open()
        await assertConnectionError({ _ = try await tunnel.open() }) {
            if case .alreadyOpen = $0 { return "" } else { return nil }
        }
        await tunnel.close()
        await assertConnectionError({ _ = try await tunnel.open() }) {
            if case .closed = $0 { return "" } else { return nil }
        }
    }

    /// 服务端开不了 direct-tcpip：回调里拿到已归类的失败（原因码 2 = 跳板机连不上目标）。
    func testRejectedChannelIsClassified() async throws {
        let server = try await TestSSH.startServer(allowsDirectTCPIP: false)
        defer { Task { await server.stop() } }
        let failures = FailureBox()
        let tunnel = SSHLocalForwardingTunnel(
            request: request(server, targetPort: 9), hostKeyStore: MemoryHostKeyStore(),
            hostKeyPolicy: .insecureAcceptAll, onChannelFailure: { failures.append($0) })
        let local = try await tunnel.open()
        defer { Task { await tunnel.close() } }

        _ = try? await Self.readFirstChunk(host: local.host, port: local.port)
        for _ in 0..<200 where failures.all.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(failures.all.map(\.kind), [.connectFailed])
    }

    /// 连上本机端口、读到第一块数据（或对端关闭）为止。
    static func readFirstChunk(host: String, port: Int) async throws -> String? {
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }
        return try await channel.executeThenClose { inbound, _ in
            var iterator = inbound.makeAsyncIterator()
            return try await iterator.next().map { String(buffer: $0) }
        }
    }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [SSHForwardingChannelFailure] = []
    func append(_ failure: SSHForwardingChannelFailure) { lock.withLock { failures.append(failure) } }
    var all: [SSHForwardingChannelFailure] { lock.withLock { failures } }
}
