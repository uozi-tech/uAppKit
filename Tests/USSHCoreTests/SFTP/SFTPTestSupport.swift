import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import USSHCore
import USSHTestServer

/// 客户端 ↔ 测试服务端：一对真的本机 TCP 连接（127.0.0.1，内核分配端口），两头都是真 pipeline。
final class SFTPLoopbackPair: Sendable {
    let fileSystem: SFTPLocalFileSystem
    let faults: SFTPFaultInjector
    let client: SFTPClient
    let listener: Channel
    private let servers: NIOLockedValueBox<[SFTPServer]>

    var server: SFTPServer? { servers.withLockedValue { $0.first } }

    private init(fileSystem: SFTPLocalFileSystem, faults: SFTPFaultInjector, client: SFTPClient,
                 listener: Channel, servers: NIOLockedValueBox<[SFTPServer]>) {
        self.fileSystem = fileSystem
        self.faults = faults
        self.client = client
        self.listener = listener
        self.servers = servers
    }

    /// - Parameters:
    ///   - fragmentInboundTo: 非 nil 时，客户端收到的每块数据先切成这么大的碎片再往上交（测任意切分）。
    ///   - lowWriteWatermark: 非 nil 时把客户端通道的写缓冲水位压得很低，逼出「不可写 → 排队」那条路。
    static func make(
        server configuration: SFTPServer.Configuration = SFTPServer.Configuration(),
        client clientConfiguration: SFTPClient.Configuration = SFTPClient.Configuration(),
        fragmentInboundTo fragmentSize: Int? = nil,
        lowWriteWatermark: Bool = false
    ) async throws -> SFTPLoopbackPair {
        let fileSystem = try SFTPLocalFileSystem.makeTemporary()
        let faults = SFTPFaultInjector()
        let servers = NIOLockedValueBox<[SFTPServer]>([])
        let group = MultiThreadedEventLoopGroup.singleton
        let listener = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let server = try SFTPServer.install(on: channel, fileSystem: fileSystem,
                                                        configuration: configuration, faults: faults)
                    servers.withLockedValue { $0.append(server) }
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        var bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let fragmentSize {
                        try channel.pipeline.syncOperations.addHandler(InboundFragmenter(size: fragmentSize))
                    }
                }
            }
        if lowWriteWatermark {
            bootstrap = bootstrap.channelOption(.writeBufferWaterMark, value: .init(low: 1024, high: 2048))
        }
        let channel = try await bootstrap.connect(to: listener.localAddress!).get()
        let client = try await SFTPClient.start(on: channel, configuration: clientConfiguration)
        return SFTPLoopbackPair(fileSystem: fileSystem, faults: faults, client: client, listener: listener, servers: servers)
    }

    /// 等服务端把这个操作的请求收满 `count` 个（请求是异步到达的）。
    func waitForRequests(_ operation: SFTPServerOperation, count: Int, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while faults.requestCount(of: operation) < count {
            guard ContinuousClock.now < deadline else {
                XCTFail("server saw \(faults.requestCount(of: operation)) of \(count) \(operation) requests")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func shutdown() async {
        await client.close()
        try? await listener.close()
        try? fileSystem.removeRoot()
    }
}

/// 把收到的每块数据切成固定大小的碎片往上交。
final class InboundFragmenter: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    let size: Int

    init(size: Int) {
        self.size = max(1, size)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        while buffer.readableBytes > 0 {
            let piece = buffer.readSlice(length: min(size, buffer.readableBytes))!
            context.fireChannelRead(wrapInboundOut(piece))
        }
    }
}

enum SFTPTestData {
    /// 确定性的伪随机字节（xorshift64*），大文件不用每次都去系统要随机数。
    static func bytes(count: Int, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: count)
        var state = seed | 1
        buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: count) { pointer in
            let words = count / 8
            let raw = pointer.baseAddress!
            for index in 0..<words {
                state ^= state >> 12
                state ^= state << 25
                state ^= state >> 27
                let value = state &* 0x2545_F491_4F6C_DD1D
                raw.storeBytes(of: value, toByteOffset: index * 8, as: UInt64.self)
            }
            for index in (words * 8)..<count {
                raw.storeBytes(of: UInt8(truncatingIfNeeded: index &* 31), toByteOffset: index, as: UInt8.self)
            }
            return count
        }
        return buffer
    }

    static func sha256(_ buffer: ByteBuffer) -> SHA256.Digest {
        buffer.withUnsafeReadableBytes { SHA256.hash(data: $0) }
    }

    static func sha256(fileAt path: String) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }
}

/// 断言抛出的是 `SFTPError.status` 且状态码为 `code`。
func XCTAssertSFTPStatus(
    _ code: SFTPStatusCode,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        XCTFail("expected SFTP status \(code), got success", file: file, line: line)
    } catch let error as SFTPError {
        XCTAssertEqual(error.statusCode, code, "got \(error)", file: file, line: line)
    } catch {
        XCTFail("expected SFTPError, got \(type(of: error)): \(error)", file: file, line: line)
    }
}

func XCTAssertSFTPError(
    _ expected: SFTPError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        XCTFail("expected \(expected), got success", file: file, line: line)
    } catch let error as SFTPError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(type(of: error)): \(error)", file: file, line: line)
    }
}
