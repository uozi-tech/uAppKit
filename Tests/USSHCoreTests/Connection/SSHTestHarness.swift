import Crypto
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
import USSHCore
import USSHTestServer
import XCTest

/// 测试共用的小工具：起进程内服务端、拼客户端配置。
enum Harness {
    static let username = "tester"
    static let password = "s3cret"

    /// 默认的服务端：`tester` / `s3cret` 能登录，另外放行 `keys` 里的公钥。
    static func serverConfiguration(
        keys: [NIOSSHPublicKey] = [],
        exec: SSHTestExecHandler = .notFound
    ) -> SSHTestServer.Configuration {
        SSHTestServer.Configuration(
            authentication: SSHTestAuthentication(passwords: [username: password], authorizedKeys: [username: keys]),
            exec: exec)
    }

    static func clientConfiguration(
        _ methods: [SSHAuthenticationMethod] = [.password(password)],
        username: String = username,
        hostKey: SSHHostKeyValidation = .acceptAnything,
        handshakeTimeout: Duration = .seconds(10),
        hostKeyValidationTimeout: Duration? = nil
    ) -> SSHClient.Configuration {
        SSHClient.Configuration(
            authentication: SSHAuthentication(username: username, methods: methods),
            hostKeyValidation: hostKey,
            connectTimeout: .seconds(5),
            handshakeTimeout: handshakeTimeout,
            hostKeyValidationTimeout: hostKeyValidationTimeout)
    }

    static func connect(_ server: SSHTestServer,
                        _ configuration: SSHClient.Configuration = clientConfiguration()) async throws -> SSHClient {
        try await SSHClient.connect(host: server.host, port: server.port, configuration: configuration)
    }

    static func string(_ buffer: ByteBuffer) -> String {
        String(buffer: buffer)
    }

    /// 在 `timeout` 内等 `condition` 成立。
    static func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

/// 期待抛错并取出错误。
func XCTAssertThrowsAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath, line: UInt = #line,
    _ check: (any Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        check(error)
    }
}

/// 一个线程安全的计数器。
final class Counter: Sendable {
    private let storage = NIOLockedValueBox(0)

    var value: Int { storage.withLockedValue { $0 } }

    func add(_ amount: Int) {
        storage.withLockedValue { $0 += amount }
    }
}

/// 本机回显服务（TCP），给 direct-tcpip / 远程转发的测试当目标。收到 EOF 后把自己这边也关掉。
final class EchoServer: Sendable {
    let channel: any Channel
    var port: Int { channel.localAddress!.port! }

    private init(channel: any Channel) {
        self.channel = channel
    }

    static func start() async throws -> EchoServer {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(EchoHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        return EchoServer(channel: channel)
    }

    func stop() async {
        try? await channel.close()
    }

    private final class EchoHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            context.write(data, promise: nil)
        }

        func channelReadComplete(context: ChannelHandlerContext) {
            context.flush()
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if case ChannelEvent.inputClosed = event {
                context.close(promise: nil)
            }
        }
    }
}
