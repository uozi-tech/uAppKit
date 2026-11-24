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
    ///   - custom: 非 nil 时服务端用它，而不是那个临时目录。
    ///   - configureFaults: 在连接建立（握手）之前装故障规则。
    ///   - fragmentInboundTo: 非 nil 时，客户端收到的每块数据先切成这么大的碎片再往上交（测任意切分）。
    ///   - lowWriteWatermark: 非 nil 时把客户端通道的写缓冲水位压得很低，逼出「不可写 → 排队」那条路。
    static func make(
        server configuration: SFTPServer.Configuration = SFTPServer.Configuration(),
        client clientConfiguration: SFTPClient.Configuration = SFTPClient.Configuration(),
        fragmentInboundTo fragmentSize: Int? = nil,
        lowWriteWatermark: Bool = false,
        serving custom: (any SFTPServerFileSystem)? = nil,
        configureFaults: (SFTPFaultInjector) -> Void = { _ in }
    ) async throws -> SFTPLoopbackPair {
        let fileSystem = try SFTPLocalFileSystem.makeTemporary()
        let served: any SFTPServerFileSystem = custom ?? fileSystem
        let faults = SFTPFaultInjector()
        configureFaults(faults)
        let servers = NIOLockedValueBox<[SFTPServer]>([])
        let group = MultiThreadedEventLoopGroup.singleton
        let listener = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let server = try SFTPServer.install(on: channel, fileSystem: served,
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

/// 系统自带的 OpenSSH sftp-server（`/usr/libexec/sftp-server`）：子进程的 stdin / stdout 接到
/// `NIOPipeBootstrap` 的通道上，中间没有 SSH。以 `-d <临时目录>` 启动；没有这个程序时抛 `XCTSkip`。
final class OpenSSHServer: Sendable {
    static let executable = "/usr/libexec/sftp-server"

    let process: Process
    let exit: ProcessExitSignal
    let client: SFTPClient
    /// 临时目录的真实路径。
    let root: String

    private init(process: Process, exit: ProcessExitSignal, client: SFTPClient, root: String) {
        self.process = process
        self.exit = exit
        self.client = client
        self.root = root
    }

    static func start(configuration: SFTPClient.Configuration = SFTPClient.Configuration()) async throws -> OpenSSHServer {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw XCTSkip("\(executable) not available")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usshcore-openssh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = try XCTUnwrap(directory.path.withCString { pointer -> String? in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        })

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-d", root, "-e", "-l", "ERROR"]
        let toServer = Pipe()
        let fromServer = Pipe()
        process.standardInput = toServer
        process.standardOutput = fromServer
        process.standardError = FileHandle.nullDevice
        // 不用 `waitUntilExit()`：它在测试的异步 tearDown 里转主线程的 run loop，实测会偶发地永远等不到结束。
        let exit = ProcessExitSignal()
        process.terminationHandler = { _ in exit.signal() }
        try process.run()

        // NIO 接管的是复制出来的描述符；Pipe 自己那份关掉，子进程才能在通道关闭时读到 EOF。
        let input = dup(fromServer.fileHandleForReading.fileDescriptor)
        let output = dup(toServer.fileHandleForWriting.fileDescriptor)
        try fromServer.fileHandleForReading.close()
        try toServer.fileHandleForWriting.close()
        let channel = try await NIOPipeBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .takingOwnershipOfDescriptors(input: input, output: output).get()
        let client = try await SFTPClient.start(on: channel, configuration: configuration)
        return OpenSSHServer(process: process, exit: exit, client: client, root: root)
    }

    /// 关通道 = 关掉子进程的 stdin，sftp-server 读到 EOF 自己退出；等不到再发 SIGTERM。
    func stop() async {
        await client.close()
        if await !exit.wait(timeout: .seconds(5)) {
            process.terminate()
            _ = await exit.wait(timeout: .seconds(5))
        }
        try? FileManager.default.removeItem(atPath: root)
    }
}

/// 子进程结束的信号（`terminationHandler` 里触发），可以带时限地等。
final class ProcessExitSignal: Sendable {
    private let state = NIOLockedValueBox<(exited: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func signal() {
        resumeWaiters(markingExited: true)
    }

    private func resumeWaiters(markingExited: Bool) {
        let waiters = state.withLockedValue { state -> [CheckedContinuation<Void, Never>] in
            if markingExited { state.exited = true }
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    private func wait() async {
        await withCheckedContinuation { continuation in
            let exited = state.withLockedValue { state -> Bool in
                if !state.exited { state.waiters.append(continuation) }
                return state.exited
            }
            if exited { continuation.resume() }
        }
    }

    /// 在时限内结束了返回 true。
    func wait(timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.wait(); return true }
            group.addTask { try? await Task.sleep(for: timeout); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            // 超时：放走还挂着的等待者（不当作已结束），任务组才能收尾。
            if !first { self.resumeWaiters(markingExited: false) }
            return first
        }
    }
}
