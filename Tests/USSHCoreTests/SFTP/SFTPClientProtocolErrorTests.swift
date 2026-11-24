import NIOCore
import NIOPosix
import XCTest
@testable import USSHCore

/// 服务端回违反协议的东西时，客户端要干净地失败（类型化的错误、通道关掉），不能挂死也不能 trap。
/// 对端是一个照脚本回字节的假服务端。
final class SFTPClientProtocolErrorTests: XCTestCase {

    /// 照脚本回答：INIT 回 `version`，之后每个请求交给 `reply` 决定回什么原始字节（nil = 不回）。
    private final class ScriptedPeer: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        let version: UInt32
        let reply: @Sendable (SFTPRequest) -> ByteBuffer?

        init(version: UInt32, reply: @escaping @Sendable (SFTPRequest) -> ByteBuffer?) {
            self.version = version
            self.reply = reply
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard let request = try? SFTPRequest.decode(frame: unwrapInboundIn(data)) else {
                context.close(promise: nil)
                return
            }
            var out = context.channel.allocator.buffer(capacity: 64)
            if case .initialize = request {
                SFTPResponse.version(version: version, extensions: []).encode(into: &out)
            } else if let bytes = reply(request) {
                out = bytes
            } else {
                return
            }
            context.writeAndFlush(wrapOutboundOut(out), promise: nil)
        }
    }

    private var listener: Channel?

    override func tearDown() async throws {
        try? await listener?.close()
        listener = nil
    }

    private func connect(
        version: UInt32 = 3,
        configuration: SFTPClient.Configuration = SFTPClient.Configuration(),
        reply: @escaping @Sendable (SFTPRequest) -> ByteBuffer?
    ) async throws -> (Channel, () async throws -> SFTPClient) {
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        ByteToMessageHandler(SFTPFrameDecoder(maximumFrameLength: 1 << 20)),
                        ScriptedPeer(version: version, reply: reply),
                    ])
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        self.listener = listener
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(to: listener.localAddress!).get()
        return (channel, { try await SFTPClient.start(on: channel, configuration: configuration) })
    }

    private static func frame(type: UInt8, _ body: (inout ByteBuffer) -> Void) -> ByteBuffer {
        var payload = ByteBuffer()
        payload.writeInteger(type)
        body(&payload)
        var out = ByteBuffer()
        out.writeInteger(UInt32(payload.readableBytes))
        out.writeBuffer(&payload)
        return out
    }

    func testUnsupportedVersionClosesTheChannel() async throws {
        let (channel, start) = try await connect(version: 4) { _ in nil }
        await XCTAssertSFTPError(.unsupportedVersion(4)) { _ = try await start() }
        try await channel.closeFuture.get()
    }

    func testUnknownPacketTypeFailsEverythingAndCloses() async throws {
        let (channel, start) = try await connect { request in
            guard case .stat(let id, _) = request else { return nil }
            return Self.frame(type: 150) { $0.writeInteger(id) }
        }
        let client = try await start()
        do {
            _ = try await client.stat("/")
            XCTFail("should fail")
        } catch let SFTPError.invalidResponse(detail) {
            XCTAssertTrue(detail.contains("150"), detail)
        }
        try await channel.closeFuture.get()
        await XCTAssertSFTPError(.invalidResponse("unknown SFTP packet type 150")) { _ = try await client.realPath(".") }
    }

    func testWrongResponseTypeFailsOnlyThatRequest() async throws {
        let (_, start) = try await connect { request in
            switch request {
            case .stat(let id, _):
                var out = ByteBuffer()
                SFTPResponse.handle(id: id, handle: ByteBuffer(string: "h")).encode(into: &out)
                return out
            case .realpath(let id, _):
                var out = ByteBuffer()
                SFTPResponse.name(id: id, entries: [SFTPDirectoryEntry(filename: "/home", longname: "", attributes: .none)])
                    .encode(into: &out)
                return out
            case .readlink(let id, _):
                var out = ByteBuffer()
                SFTPResponse.name(id: id, entries: []).encode(into: &out)
                return out
            default:
                return nil
            }
        }
        let client = try await start()
        await XCTAssertSFTPError(.invalidResponse("expected SSH_FXP_ATTRS, got handle")) { _ = try await client.stat("/") }
        await XCTAssertSFTPError(.invalidResponse("SSH_FXP_NAME with no entries")) { _ = try await client.readLink("/l") }
        let home = try await client.realPath(".")
        XCTAssertEqual(home, "/home")
        XCTAssertTrue(client.isActive)
    }

    func testOversizedFrameFromServerIsRejected() async throws {
        let (channel, start) = try await connect(configuration: SFTPClient.Configuration(maximumInboundPacketLength: 4096)) { request in
            guard case .read(let id, _, _, _) = request else {
                if let id = request.requestID {
                    var out = ByteBuffer()
                    SFTPResponse.handle(id: id, handle: ByteBuffer(string: "h")).encode(into: &out)
                    return out
                }
                return nil
            }
            var out = ByteBuffer()
            SFTPResponse.data(id: id, data: SFTPTestData.bytes(count: 10_000)).encode(into: &out)
            return out
        }
        let client = try await start()
        let file = try await client.openFile("/f", flags: .read)
        do {
            _ = try await file.read(from: 0, length: 100)
            XCTFail("should fail")
        } catch SFTPError.invalidResponse {}
        try await channel.closeFuture.get()
    }

    func testDataLongerThanRequestedIsRejected() async throws {
        let (_, start) = try await connect { request in
            switch request {
            case .open(let id, _, _, _):
                var out = ByteBuffer()
                SFTPResponse.handle(id: id, handle: ByteBuffer(string: "h")).encode(into: &out)
                return out
            case .read(let id, _, _, let length):
                var out = ByteBuffer()
                SFTPResponse.data(id: id, data: SFTPTestData.bytes(count: Int(length) + 1)).encode(into: &out)
                return out
            default:
                return nil
            }
        }
        let client = try await start()
        let file = try await client.openFile("/f", flags: .read)
        do {
            _ = try await file.read(from: 0, length: 10)
            XCTFail("should fail")
        } catch SFTPError.invalidResponse {}
    }

    /// 服务端在握手之前就断开：start 抛 connectionClosed，不挂死。
    func testPeerClosingBeforeVersion() async throws {
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in channel.close() }
            .bind(host: "127.0.0.1", port: 0).get()
        self.listener = listener
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(to: listener.localAddress!).get()
        await XCTAssertSFTPError(.connectionClosed) { _ = try await SFTPClient.start(on: channel) }
    }

    /// 等 VERSION 的时候任务被取消：抛 CancellationError、关掉通道。
    func testCancellingStartClosesTheChannel() async throws {
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).get()
        self.listener = listener
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(to: listener.localAddress!).get()
        let task = Task { try await SFTPClient.start(on: channel) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("should be cancelled")
        } catch is CancellationError {}
        try await channel.closeFuture.get()
    }
}
