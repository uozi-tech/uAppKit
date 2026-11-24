import NIOConcurrencyHelpers
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
        let extensions: [SFTPWireExtension]
        let reply: @Sendable (SFTPRequest) -> ByteBuffer?

        init(version: UInt32, extensions: [SFTPWireExtension], reply: @escaping @Sendable (SFTPRequest) -> ByteBuffer?) {
            self.version = version
            self.extensions = extensions
            self.reply = reply
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard let request = try? SFTPRequest.decode(frame: unwrapInboundIn(data)) else {
                context.close(promise: nil)
                return
            }
            var out = context.channel.allocator.buffer(capacity: 64)
            if case .initialize = request {
                SFTPResponse.version(version: version, extensions: extensions).encode(into: &out)
            } else if let bytes = reply(request) {
                out = bytes
            } else {
                return
            }
            if out.readableBytes == 0 {
                // 空字节 = 脚本要求断开。
                context.close(promise: nil)
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
        extensions: [SFTPWireExtension] = [],
        configuration: SFTPClient.Configuration = SFTPClient.Configuration(),
        reply: @escaping @Sendable (SFTPRequest) -> ByteBuffer?
    ) async throws -> (Channel, () async throws -> SFTPClient) {
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        ByteToMessageHandler(SFTPFrameDecoder(maximumFrameLength: 1 << 20)),
                        ScriptedPeer(version: version, extensions: extensions, reply: reply),
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
        // 通道已经关了：之后的请求不再发出，直接 connectionClosed。
        await XCTAssertSFTPError(.connectionClosed) { _ = try await client.realPath(".") }
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

    // MARK: - limits@openssh.com 答不好

    private static let advertisesLimits = [SFTPWireExtension(name: SFTPExtensionName.limits, data: "1")]

    private static func encoded(_ response: SFTPResponse) -> ByteBuffer {
        var out = ByteBuffer()
        response.encode(into: &out)
        return out
    }

    /// 宣告了 limits 却回错误状态：start 照常成功，按没有 limits 处理。
    func testLimitsQueryFailingWithAStatusFallsBack() async throws {
        let (_, start) = try await connect(extensions: Self.advertisesLimits) { request in
            guard case .extended(let id, .limits) = request else { return nil }
            return Self.encoded(.status(id: id, code: .operationUnsupported, message: "no", languageTag: ""))
        }
        let client = try await start()
        XCTAssertNil(client.limits)
        XCTAssertTrue(client.supportsExtension(SFTPExtensionName.limits))
        XCTAssertEqual(client.maximumReadLength, 32 * 1024)
        XCTAssertEqual(client.maximumWriteLength, 32 * 1024)
        XCTAssertTrue(client.isActive)
    }

    /// 回的格式不对（太短）：同样回退。
    func testMalformedLimitsReplyFallsBack() async throws {
        let (_, start) = try await connect(extensions: Self.advertisesLimits) { request in
            guard case .extended(let id, .limits) = request else { return nil }
            return Self.encoded(.extendedReply(id: id, data: ByteBuffer(bytes: [1, 2, 3])))
        }
        let client = try await start()
        XCTAssertNil(client.limits)
        XCTAssertEqual(client.maximumWriteLength, 32 * 1024)
    }

    /// 问 limits 的时候断开：start 照常失败。
    func testLosingTheConnectionDuringTheLimitsQueryFails() async throws {
        let (_, start) = try await connect(extensions: Self.advertisesLimits) { request in
            guard case .extended(_, .limits) = request else { return nil }
            return ByteBuffer()
        }
        await XCTAssertSFTPError(.connectionClosed) { _ = try await start() }
    }

    // MARK: - 句柄不拖住收帧缓冲

    /// 句柄是收帧缓冲里的切片时，留着它就留着整块缓冲；客户端拷一份小的。
    func testHandlesDoNotPinTheReceiveBuffer() async throws {
        let (_, start) = try await connect { request in
            guard case .open(let id, _, _, _) = request else { return nil }
            // 句柄后面紧跟一大段别的回答，让它们落进同一块接收缓冲。
            var out = Self.encoded(.handle(id: id, handle: ByteBuffer(string: "HNDL")))
            var filler = Self.encoded(.status(id: 999_999, code: .ok, message: String(repeating: "x", count: 200_000), languageTag: ""))
            out.writeBuffer(&filler)
            return out
        }
        let client = try await start()
        let file = try await client.openFile("/f", flags: .read)
        XCTAssertEqual(file.handle, ByteBuffer(string: "HNDL"))
        XCTAssertLessThan(file.handle.storageCapacity, 1024, "handle keeps \(file.handle.storageCapacity) bytes alive")
    }

    // MARK: - 空的 NAME 批次

    /// READDIR 一直回空的 NAME、从不回 EOF：有限次之后报协议错误，而不是无限循环。
    func testEndlessEmptyDirectoryBatchesAreRejected() async throws {
        let readdirs = NIOLockedValueBox(0)
        let (_, start) = try await connect { request in
            switch request {
            case .opendir(let id, _):
                return Self.encoded(.handle(id: id, handle: ByteBuffer(string: "D")))
            case .readdir(let id, _):
                readdirs.withLockedValue { $0 += 1 }
                return Self.encoded(.name(id: id, entries: []))
            case .close(let id, _):
                return Self.encoded(.status(id: id, code: .ok, message: "", languageTag: ""))
            default:
                return nil
            }
        }
        let client = try await start()
        do {
            _ = try await client.listDirectory("/")
            XCTFail("should give up")
        } catch SFTPError.invalidResponse {}
        XCTAssertEqual(readdirs.withLockedValue { $0 }, SFTPClient.maximumConsecutiveEmptyDirectoryBatches)
    }

    /// 偶尔一个空批次没关系：后面还有项、最后回 EOF，照常列出来。
    func testOccasionalEmptyBatchesAreTolerated() async throws {
        let calls = NIOLockedValueBox(0)
        let (_, start) = try await connect { request in
            switch request {
            case .opendir(let id, _):
                return Self.encoded(.handle(id: id, handle: ByteBuffer(string: "D")))
            case .readdir(let id, _):
                let call = calls.withLockedValue { value -> Int in
                    value += 1
                    return value
                }
                switch call {
                case 1, 3: return Self.encoded(.name(id: id, entries: []))
                case 2, 4:
                    return Self.encoded(.name(id: id, entries: [SFTPDirectoryEntry(filename: "e\(call)", longname: "", attributes: .none)]))
                default: return Self.encoded(.status(id: id, code: .eof, message: "", languageTag: ""))
                }
            case .close(let id, _):
                return Self.encoded(.status(id: id, code: .ok, message: "", languageTag: ""))
            default:
                return nil
            }
        }
        let client = try await start()
        let entries = try await client.listDirectory("/")
        XCTAssertEqual(entries.map(\.filename), ["e2", "e4"])
    }
}
