import XCTest
import NIOCore
@testable import USSHKit

/// `SSHFileTransferSession.segmentedRead`：stat 过的那部分按段读，每段必须读满（生产里是
/// `SFTPFile.readAll(expectedLength:)`，段内的窗口化并发与短读补发由 USSHCore 负责、在它自己的测试里），
/// 之后接着读到 EOF。截短的文件绝不能被当成下载完成。
final class SFTPSegmentedReadTests: XCTestCase {

    /// 假的远端文件：`readExactly` 照 `readAll(expectedLength:)` 的规矩，不够就抛 `shortRead`。
    private final class FakeRemote: @unchecked Sendable {
        var data: [UInt8]
        private(set) var exactReads: [(UInt64, Int)] = []
        private(set) var nextReads = 0

        init(size: Int) {
            data = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) }
        }

        func readExactly(_ offset: UInt64, _ length: Int) throws -> ByteBuffer {
            exactReads.append((offset, length))
            let start = Int(min(offset, UInt64(data.count)))
            let end = min(data.count, start + length)
            guard end - start == length else { throw SFTPError.shortRead(expected: length, actual: end - start) }
            return ByteBuffer(bytes: data[start..<end])
        }

        func readNext(_ offset: UInt64) -> ByteBuffer? {
            nextReads += 1
            let start = Int(min(offset, UInt64(data.count)))
            guard start < data.count else { return nil }
            return ByteBuffer(bytes: data[start..<min(data.count, start + 1000)])
        }
    }

    private func download(_ remote: FakeRemote, expectedSize: Int64, segment: Int = 4096,
                          maximumBytes: Int64? = nil) async throws -> [UInt8] {
        var out: [UInt8] = []
        _ = try await SSHFileTransferSession.segmentedRead(
            expectedSize: expectedSize, segmentBytes: segment, maximumBytes: maximumBytes,
            readExactly: { try remote.readExactly($0, $1) },
            readNext: { remote.readNext($0) },
            write: { out.append(contentsOf: $0.readableBytesView) }
        )
        return out
    }

    /// stat 之后接着读的那一段回了空的数据（不是 nil）：协议错误，不能当成 EOF 把截断的文件交出去。
    func testEmptyTrailingReadIsAnErrorNotEOF() async throws {
        var written = 0
        do {
            _ = try await SSHFileTransferSession.segmentedRead(
                expectedSize: 0, segmentBytes: 4096, maximumBytes: nil,
                readExactly: { _, _ in XCTFail("nothing was stat'ed"); return ByteBuffer() },
                readNext: { offset in offset == 0 ? ByteBuffer(bytes: [1, 2, 3]) : ByteBuffer() },
                write: { written += $0.readableBytes })
            XCTFail("an empty read was taken as EOF")
        } catch SFTPError.invalidResponse(let detail) {
            XCTAssertTrue(detail.contains("zero-length"), detail)
        }
        XCTAssertEqual(written, 3)
    }

    func testReadsTheStatedSizeInSegmentsThenConfirmsEOF() async throws {
        let remote = FakeRemote(size: 10 * 1024 + 17)
        let out = try await download(remote, expectedSize: 10 * 1024 + 17)
        XCTAssertEqual(out, remote.data)
        XCTAssertEqual(remote.exactReads.map(\.1), [4096, 4096, 2065])
        XCTAssertEqual(remote.nextReads, 1, "末尾一次 EOF 确认")
    }

    func testFileThatGrewIsStillCopiedWhole() async throws {
        let remote = FakeRemote(size: 10 * 1024 + 500)
        let out = try await download(remote, expectedSize: 4 * 1024)   // stat 时只有 4 KB
        XCTAssertEqual(out, remote.data)
    }

    /// stat 时更大、读的时候变短了：报 `shortRead`，不能当成下载完成（迁移前会按成功返回）。
    func testFileThatShrankIsAnError() async throws {
        let remote = FakeRemote(size: 3 * 1024 + 10)
        do {
            _ = try await download(remote, expectedSize: 9 * 1024)
            XCTFail("截短的文件不能算下载成功")
        } catch SFTPError.shortRead(let expected, let actual) {
            XCTAssertEqual(expected, 4096)
            XCTAssertEqual(actual, 3 * 1024 + 10)
        }
    }

    /// 读段的实现即便交回不足的数据（不该发生），也不会被当成完整的一段写出去。
    func testShortSegmentFromReaderIsRejected() async throws {
        do {
            _ = try await SSHFileTransferSession.segmentedRead(
                expectedSize: 100, segmentBytes: 64, maximumBytes: nil,
                readExactly: { _, _ in ByteBuffer(bytes: [1, 2, 3]) },
                readNext: { _ in nil },
                write: { _ in XCTFail("不足的段不能写出") })
            XCTFail("应当失败")
        } catch SFTPError.shortRead(let expected, let actual) {
            XCTAssertEqual(expected, 64)
            XCTAssertEqual(actual, 3)
        }
    }

    func testEmptyFileTakesOneRead() async throws {
        let remote = FakeRemote(size: 0)
        let out = try await download(remote, expectedSize: 0)
        XCTAssertTrue(out.isEmpty)
        XCTAssertTrue(remote.exactReads.isEmpty)
        XCTAssertEqual(remote.nextReads, 1)
    }

    func testSizeCapStillApplies() async throws {
        let remote = FakeRemote(size: 50 * 1024)
        do {
            _ = try await download(remote, expectedSize: 50 * 1024, maximumBytes: 20 * 1024)
            XCTFail("超过上限必须报错")
        } catch SSHFileTransferError.downloadTooLarge {
        }
    }

    /// 在途的 READ 要装得进 SFTP 通道的流控窗口（否则窗口才是瓶颈）：16 × OpenSSH 允许的最大 READ（255 KiB）。
    func testProductionWindowsCoverTheReadPipeline() {
        XCTAssertGreaterThanOrEqual(SSHFileTransferSession.downloadWindow, 16)
        let inFlight = SSHFileTransferSession.downloadWindow * 255 * 1024
        XCTAssertGreaterThanOrEqual(SSHFileTransferSession.defaultChannelWindowBytes, inFlight)
        // 会话按「窗口 / 64」要包长（NIOSSH 0.15 的窗口 = 包长 × 64），要落在 USSHCore 不用夹的区间里，
        // 实际通告的窗口才是想要的那么大。
        let packet = SSHFileTransferSession.maximumPacketSize(
            forWindow: SSHFileTransferSession.defaultChannelWindowBytes)
        XCTAssertTrue(SSHClient.maximumPacketSizeRange.contains(packet))
        let configuration = SSHClient.Configuration(
            authentication: .password("", username: ""), hostKeyValidation: .acceptAnything,
            maximumPacketSize: packet)
        XCTAssertEqual(configuration.channelWindowSize, SSHFileTransferSession.defaultChannelWindowBytes)
    }
}

/// 真服务器上的整份下载（默认跳过）：`USSHKIT_SFTP_LIVE="host:port:user:password:/remote/path:/local/reference"`。
/// 用来确认同一条 SFTP 通道上并行读请求时，字节与源文件逐一相同。
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
