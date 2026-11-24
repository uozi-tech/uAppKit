import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOPosix
import XCTest
@testable import USSHCore
import USSHTestServer

/// 直接对着 `SFTPClientChannelHandler` 测（`EmbeddedChannel`：EventLoop 上的任务何时执行由测试决定），
/// 把取消、请求号绕回、写失败这些夹缝里的时序精确地摆出来。
final class SFTPClientHandlerTests: XCTestCase {
    private struct Rig {
        let channel: EmbeddedChannel
        let core: SFTPClientCore
        let requestIDs: NIOLockedValueBox<UInt32>

        var loop: EmbeddedEventLoop { channel.embeddedEventLoop }

        /// 把线上已经写出去的字节解成请求。
        func sentRequests() throws -> [SFTPRequest] {
            loop.run()
            var stream = ByteBuffer()
            while var piece = try channel.readOutbound(as: ByteBuffer.self) {
                stream.writeBuffer(&piece)
            }
            var decoder = SFTPFrameDecoder(maximumFrameLength: 1 << 20)
            var requests: [SFTPRequest] = []
            while let frame = try decoder.decode(buffer: &stream) {
                requests.append(try SFTPRequest.decode(frame: frame))
            }
            return requests
        }

        /// 服务端回一个报文（不带长度字段的报文体，正是解帧器交给 handler 的东西）。
        func respond(_ response: SFTPResponse) throws {
            var buffer = ByteBuffer()
            response.encode(into: &buffer)
            buffer.moveReaderIndex(forwardBy: 4)
            try channel.writeInbound(buffer)
            loop.run()
        }
    }

    /// 可以随时切成「每次写都失败、但不关通道」的出站 handler。
    private final class FailingWrites: ChannelOutboundHandler {
        typealias OutboundIn = ByteBuffer
        struct Boom: Error {}
        var failing = false

        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            if failing {
                promise?.fail(Boom())
            } else {
                context.write(data, promise: promise)
            }
        }
    }

    private func makeRig(failingWrites: FailingWrites? = nil) throws -> Rig {
        let requestIDs = NIOLockedValueBox<UInt32>(1)
        let handler = SFTPClientChannelHandler(requestIDs: requestIDs)
        let channel = EmbeddedChannel()
        if let failingWrites { try channel.pipeline.syncOperations.addHandler(failingWrites) }
        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
        let handshake = channel.eventLoop.makePromise(of: SFTPClientChannelHandler.Handshake.self)
        handler.beginHandshake(promise: handshake)
        let rig = Rig(channel: channel,
                      core: SFTPClientCore(channel: channel, handler: NIOLoopBound(handler, eventLoop: channel.eventLoop),
                                           requestIDs: requestIDs),
                      requestIDs: requestIDs)
        XCTAssertEqual(try rig.sentRequests(), [.initialize(version: 3, extensions: [])])
        try rig.respond(.version(version: 3, extensions: []))
        XCTAssertEqual(try handshake.futureResult.wait().version, 3)
        return rig
    }

    private func result(_ request: SFTPInFlightRequest) -> Result<SFTPResponse, Error>? {
        var outcome: Result<SFTPResponse, Error>?
        request.promise?.futureResult.assumeIsolated().whenComplete { outcome = $0 }
        return outcome
    }

    // MARK: - 取消的 OPEN 不漏句柄

    /// 取消在 EventLoop 上发生、HANDLE 也在同一轮到达：要么调用方拿到句柄，要么客户端替它关掉，二者必居其一。
    /// （原来的写法先同步地让 promise 失败、另排一个任务撤记录；HANDLE 夹在中间到达时成功被忽略、记录也没了，
    /// 句柄就永远开在服务端。）
    func testOnLoopCancelRacingTheHandleNeverLeaksIt() throws {
        let rig = try makeRig()
        let open = rig.core.submit { .open(id: $0, path: "/f", flags: [.write, .create, .truncate], attributes: .none) }
        XCTAssertEqual(try rig.sentRequests().count, 1)
        rig.core.abandon(open)                       // 排进 EventLoop，还没执行
        try rig.respond(.handle(id: open.id, handle: ByteBuffer(string: "H1")))
        let sent = try rig.sentRequests()
        switch result(open) {
        case .success(.handle(_, let handle))?:
            XCTAssertEqual(handle, ByteBuffer(string: "H1"), "the caller owns the handle")
            XCTAssertTrue(sent.isEmpty)
        default:
            guard case .close(_, let handle)? = sent.first else { return XCTFail("handle leaked: \(sent)") }
            XCTAssertEqual(handle, ByteBuffer(string: "H1"))
        }
    }

    /// 先撤、后到的 HANDLE：客户端替调用方把它关掉。
    func testAbandonedOpenClosesTheLateHandle() throws {
        let rig = try makeRig()
        let open = rig.core.submit { .opendir(id: $0, path: "/d") }
        _ = try rig.sentRequests()
        rig.core.abandon(open)
        rig.loop.run()
        guard case .failure(let error)? = result(open) else { return XCTFail("still pending") }
        XCTAssertTrue(error is CancellationError)
        try rig.respond(.handle(id: open.id, handle: ByteBuffer(string: "D1")))
        guard case .close(_, let handle)? = try rig.sentRequests().first else { return XCTFail("no CLOSE") }
        XCTAssertEqual(handle, ByteBuffer(string: "D1"))
    }

    /// 还排在 backlog 里（通道不可写）就被撤掉的 OPEN：根本不发出去。
    func testOpenAbandonedInTheBacklogIsNeverSent() throws {
        let rig = try makeRig()
        rig.channel.isWritable = false
        let open = rig.core.submit { .open(id: $0, path: "/f", flags: [.write, .create, .exclusive], attributes: .none) }
        let stat = rig.core.submit { .stat(id: $0, path: "/") }
        XCTAssertTrue(try rig.sentRequests().isEmpty)
        rig.core.abandon(open)
        rig.loop.run()
        rig.channel.isWritable = true
        rig.channel.pipeline.fireChannelWritabilityChanged()
        let sent = try rig.sentRequests()
        XCTAssertEqual(sent, [.stat(id: stat.id, path: "/")], "the abandoned OPEN must not reach the server")
        guard case .failure(let error)? = result(open) else { return XCTFail("still pending") }
        XCTAssertTrue(error is CancellationError)
    }

    // MARK: - 请求号绕回

    /// 调用方取到的号还被一个没回答的请求占着：换一个号发，两个请求各拿各的回答。
    func testWrappedRequestIDDoesNotOverwriteAPendingRequest() throws {
        let rig = try makeRig()
        let first = rig.core.submit { .stat(id: $0, path: "/first") }
        rig.requestIDs.withLockedValue { $0 = first.id }          // 模拟绕回一圈
        let second = rig.core.submit { .stat(id: $0, path: "/second") }
        XCTAssertEqual(second.id, first.id)
        let sent = try rig.sentRequests()
        XCTAssertEqual(sent.count, 2)
        let wireIDs = sent.compactMap(\.requestID)
        XCTAssertEqual(Set(wireIDs).count, 2, "two distinct ids on the wire")
        guard case .stat(let secondWireID, "/second")? = sent.last else { return XCTFail("\(sent)") }

        try rig.respond(.attributes(id: secondWireID, attributes: SFTPFileAttributes(size: 2)))
        try rig.respond(.attributes(id: first.id, attributes: SFTPFileAttributes(size: 1)))
        guard case .success(.attributes(_, let a))? = result(first),
              case .success(.attributes(_, let b))? = result(second) else { return XCTFail("not both answered") }
        XCTAssertEqual(a.size, 1)
        XCTAssertEqual(b.size, 2)
    }

    /// 撤掉换过号的那个请求，撤的是它、不是占着原号的那个。
    func testAbandoningARemappedRequestLeavesTheOtherAlone() throws {
        let rig = try makeRig()
        let first = rig.core.submit { .stat(id: $0, path: "/first") }
        rig.requestIDs.withLockedValue { $0 = first.id }
        let second = rig.core.submit { .stat(id: $0, path: "/second") }
        let sent = try rig.sentRequests()
        guard case .stat(let secondWireID, _)? = sent.last else { return XCTFail() }
        rig.core.abandon(second)
        rig.loop.run()
        try rig.respond(.attributes(id: first.id, attributes: SFTPFileAttributes(size: 1)))
        try rig.respond(.attributes(id: secondWireID, attributes: SFTPFileAttributes(size: 2)))
        guard case .success(.attributes(_, let a))? = result(first) else { return XCTFail("first lost its answer") }
        XCTAssertEqual(a.size, 1)
        guard case .failure(let error)? = result(second) else { return XCTFail() }
        XCTAssertTrue(error is CancellationError)
    }

    /// 撞上被撤掉、还等着迟到句柄的 OPEN 的号也要跳过：否则迟到的 HANDLE 会被当成新请求的回答。
    func testWrappedIDSkipsAbandonedOpens() throws {
        let rig = try makeRig()
        let open = rig.core.submit { .open(id: $0, path: "/f", flags: .read, attributes: .none) }
        _ = try rig.sentRequests()
        rig.core.abandon(open)
        rig.loop.run()
        rig.requestIDs.withLockedValue { $0 = open.id }
        let stat = rig.core.submit { .stat(id: $0, path: "/") }
        guard case .stat(let wireID, _)? = try rig.sentRequests().first else { return XCTFail() }
        XCTAssertNotEqual(wireID, open.id)
        try rig.respond(.handle(id: open.id, handle: ByteBuffer(string: "H")))
        XCTAssertNil(result(stat), "the late HANDLE did not complete the STAT")
        guard case .close? = try rig.sentRequests().first else { return XCTFail("late handle not closed") }
    }

    // MARK: - 写失败、通道没了

    /// 写失败但通道没有变成 inactive：请求不能永远挂着。
    func testWriteFailureFailsTheRequests() throws {
        let failing = FailingWrites()
        let rig = try makeRig(failingWrites: failing)
        failing.failing = true
        let stat = rig.core.submit { .stat(id: $0, path: "/") }
        rig.loop.run()
        guard case .failure(let error)? = result(stat) else { return XCTFail("request still pending after a failed write") }
        XCTAssertEqual(error as? SFTPError, .connectionClosed)
        XCTAssertFalse(rig.channel.isActive, "a failed write closes the channel")
        let next = rig.core.submit { .stat(id: $0, path: "/") }
        rig.loop.run()
        XCTAssertNil(next.promise, "requests on a dead channel are not even queued")
    }

    /// EventLoop 已经关停（通道随之关闭）：请求马上以 connectionClosed 失败，不挂死。
    func testRequestsAfterTheEventLoopShutDownFailFast() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let fileSystem = try SFTPLocalFileSystem.makeTemporary()
        defer { try? fileSystem.removeRoot() }
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    _ = try SFTPServer.install(on: channel, fileSystem: fileSystem)
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let channel = try await ClientBootstrap(group: group).connect(to: listener.localAddress!).get()
        let client = try await SFTPClient.start(on: channel)
        _ = try await client.stat("/")
        try await group.shutdownGracefully()
        await XCTAssertSFTPError(.connectionClosed) { _ = try await client.stat("/") }
        await XCTAssertSFTPError(.connectionClosed) { _ = try await client.openFile("/f", flags: .read) }
        await client.close()
        try await listener.close()
    }
}
