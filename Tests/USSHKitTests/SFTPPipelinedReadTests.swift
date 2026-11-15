import XCTest
import NIOCore
@testable import USSHKit

/// `SSHFileTransferSession.pipelinedRead`：同一条 SFTP 通道上保持多个读请求在路上，
/// 结果按偏移顺序写出。每个读请求在真实网络上就是一个往返 —— 以前一次只发一个，
/// 16 MB 要 ~560 个往返（150ms 线路上 90s）。
final class SFTPPipelinedReadTests: XCTestCase {

    /// 假的远端文件：记录同时在路上的读请求数，可限制每次最多返回多少字节。
    private actor FakeRemote {
        var data: [UInt8]
        let maxPerRead: Int?
        let latency: Duration
        private(set) var inFlight = 0
        private(set) var maxInFlight = 0
        private(set) var reads = 0

        init(size: Int, maxPerRead: Int? = nil, latency: Duration = .milliseconds(2)) {
            data = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) }
            self.maxPerRead = maxPerRead
            self.latency = latency
        }

        func read(_ offset: UInt64, _ length: UInt32) async throws -> ByteBuffer {
            reads += 1
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            try await Task.sleep(for: latency)
            inFlight -= 1
            let start = Int(min(offset, UInt64(data.count)))
            var end = min(data.count, start + Int(length))
            if let maxPerRead { end = min(end, start + maxPerRead) }
            return ByteBuffer(bytes: data[start..<end])
        }

        func resize(to size: Int) {
            data = Array((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })
        }
    }

    private func download(_ remote: FakeRemote, expectedSize: Int64, chunk: Int = 1024, window: Int = 8,
                          maximumBytes: Int64? = nil) async throws -> [UInt8] {
        var out: [UInt8] = []
        _ = try await SSHFileTransferSession.pipelinedRead(
            expectedSize: expectedSize, chunkSize: chunk, window: window, maximumBytes: maximumBytes,
            read: { try await remote.read($0, $1) },
            write: { out.append(contentsOf: $0.readableBytesView) }
        )
        return out
    }

    func testKeepsTheWindowInFlightAndWritesInOrder() async throws {
        let remote = FakeRemote(size: 100 * 1024 + 17)
        let out = try await download(remote, expectedSize: 100 * 1024 + 17)
        let expected = await remote.data
        XCTAssertEqual(out, expected)
        let maxInFlight = await remote.maxInFlight
        XCTAssertEqual(maxInFlight, 8, "读请求没有并行在路上：又退回了一次一个往返")
        let reads = await remote.reads
        XCTAssertEqual(reads, 101 + 1, "101 个块 + 末尾一次 EOF 确认")
    }

    func testShortReadsAreCompletedBeforeLaterChunksAreWritten() async throws {
        let remote = FakeRemote(size: 20 * 1024, maxPerRead: 300)
        let out = try await download(remote, expectedSize: 20 * 1024)
        let expected = await remote.data
        XCTAssertEqual(out, expected, "服务端短读时内容错位")
    }

    func testFileThatGrewIsStillCopiedWhole() async throws {
        let remote = FakeRemote(size: 10 * 1024 + 500)
        let out = try await download(remote, expectedSize: 4 * 1024)   // stat 时只有 4 KB
        let expected = await remote.data
        XCTAssertEqual(out, expected)
    }

    func testFileThatShrankStopsAtItsEnd() async throws {
        let remote = FakeRemote(size: 3 * 1024 + 10)
        let out = try await download(remote, expectedSize: 9 * 1024)   // stat 时更大
        let expected = await remote.data
        XCTAssertEqual(out, expected)
    }

    func testEmptyFileTakesOneRead() async throws {
        let remote = FakeRemote(size: 0)
        let out = try await download(remote, expectedSize: 0)
        XCTAssertTrue(out.isEmpty)
        let reads = await remote.reads
        XCTAssertEqual(reads, 1)
    }

    func testSizeCapStillApplies() async throws {
        let remote = FakeRemote(size: 50 * 1024)
        do {
            _ = try await download(remote, expectedSize: 50 * 1024, maximumBytes: 20 * 1024)
            XCTFail("超过上限必须报错")
        } catch SSHFileTransferError.downloadTooLarge {
        }
    }

    /// 读请求窗口要宽，SFTP 通道的流控窗口还得装得下整窗在途字节 —— 否则流控
    /// 窗口才是瓶颈（128 KiB 默认值下，并行读也只快了 2.5 倍）。
    func testProductionWindowsCoverTheReadPipeline() {
        XCTAssertGreaterThanOrEqual(SSHFileTransferSession.downloadWindow, 16)
        let inFlight = SSHFileTransferSession.downloadWindow * 32 * 1024
        XCTAssertGreaterThanOrEqual(SSHFileTransferSession.defaultChannelWindowBytes, inFlight)
        XCTAssertTrue(SSHFileTransferSession.channelWindowRange.contains(SSHFileTransferSession.defaultChannelWindowBytes),
                      "越出 NIOSSH 的 precondition 范围会直接 abort 进程")
    }
}

/// 真服务器上的整份下载（默认跳过）：`USSHKIT_SFTP_LIVE="host:port:user:password:/remote/path:/local/reference"`。
/// 用来确认 Citadel 在同一条 SFTP 通道上并行读请求时，字节与源文件逐一相同。
final class SFTPPipelinedLiveDownloadTests: XCTestCase {
    private struct AcceptAll: HostKeyStore {
        func verify(_ hostKey: SSHHostKey) async throws -> SSHHostKeyVerification { .trusted }
        func remember(_ hostKey: SSHHostKey) async throws {}
    }

    func testLiveDownloadMatchesReference() async throws {
        guard let spec = ProcessInfo.processInfo.environment["USSHKIT_SFTP_LIVE"] else {
            throw XCTSkip("设 USSHKIT_SFTP_LIVE 才跑真服务器下载")
        }
        let parts = spec.split(separator: ":", maxSplits: 5).map(String.init)
        guard parts.count == 6, let port = Int(parts[1]) else { return XCTFail("USSHKIT_SFTP_LIVE 格式不对") }
        let session = try await SSHFileTransferSession.open(
            endpoint: SSHEndpoint(host: parts[0], port: port, username: parts[2]),
            credential: .password(parts[3]),
            hostKeyStore: AcceptAll(), hostKeyPolicy: .insecureAcceptAll, approver: { _ in true })
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-live-\(UUID())")
        defer { try? FileManager.default.removeItem(at: local) }
        let t0 = Date()
        let info = try await session.download(parts[4], to: local)
        let elapsed = Date().timeIntervalSince(t0)
        await session.close()
        let got = try Data(contentsOf: local)
        let want = try Data(contentsOf: URL(fileURLWithPath: parts[5]))
        print(String(format: "[sftp-live] %d bytes in %.2fs", got.count, elapsed))
        XCTAssertEqual(Int64(got.count), info.size)
        XCTAssertTrue(got == want, "下载内容与源文件不一致")
    }
}
