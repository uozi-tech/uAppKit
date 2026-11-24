import NIOCore
import XCTest
@testable import USSHCore
import USSHTestServer

/// `readAll` 不能把不完整的数据当成功交出去；单个请求的边界（0 长度、超大长度、越界 offset）不 trap。
final class SFTPReadIntegrityTests: XCTestCase {
    private var memory: SFTPMemoryFileSystem!
    private var pair: SFTPLoopbackPair!
    private var payload: ByteBuffer!
    private var chunk: UInt64 { UInt64(pair.client.maximumReadLength) }

    override func setUp() async throws {
        memory = SFTPMemoryFileSystem()
        pair = try await SFTPLoopbackPair.make(serving: memory)
        payload = SFTPTestData.bytes(count: 4 * pair.client.maximumReadLength + 1000)
        memory.put("/f", Array(payload.readableBytesView))
    }

    override func tearDown() async throws {
        await pair?.shutdown()
    }

    private func override(_ rule: @escaping @Sendable (SFTPPath, UInt64, Int) -> SFTPMemoryFileSystem.ReadOverride?) {
        memory.readOverride.withLockedValue { $0 = rule }
    }

    private func readAll(expectedLength: Int? = nil) async throws -> ByteBuffer {
        try await pair.client.withFile("/f", flags: .read) { try await $0.readAll(expectedLength: expectedLength, window: 8) }
    }

    func testIntactFileReadsCompletely() async throws {
        let all = try await readAll()
        XCTAssertEqual(all, payload)
        let exact = try await readAll(expectedLength: payload.readableBytes)
        XCTAssertEqual(exact, payload)
        let prefix = try await readAll(expectedLength: 5000)
        XCTAssertEqual(prefix, payload.getSlice(at: 0, length: 5000), "stops at expectedLength")
        let none = try await readAll(expectedLength: 0)
        XCTAssertEqual(none.readableBytes, 0)
    }

    /// 0 字节的 DATA 不是 EOF：原来会在这里悄悄收尾，交出前面那一点数据。
    func testZeroLengthDataIsAProtocolError() async throws {
        let second = chunk
        override { _, offset, _ in offset == second ? .data(ByteBuffer()) : nil }
        do {
            _ = try await readAll()
            XCTFail("truncated read reported success")
        } catch SFTPError.invalidResponse(let detail) {
            XCTAssertTrue(detail.contains("zero-length"), detail)
        }
    }

    /// 单个 READ 也一样：要了字节、回 0 字节的 DATA 是协议错误，不是空切片（原来交出 `.some(空)`，调用方要么当 EOF
    /// 截断、要么在同一个 offset 上打转）。0 长度的读照旧不发请求、回空。
    func testSingleReadRejectsZeroLengthData() async throws {
        override { _, offset, _ in offset == 0 ? .data(ByteBuffer()) : nil }
        let file = try await pair.client.openFile("/f", flags: .read)
        do {
            _ = try await file.read(from: 0, length: 100)
            XCTFail("empty DATA for a 100-byte read was accepted")
        } catch SFTPError.invalidResponse(let detail) {
            XCTAssertTrue(detail.contains("zero-length"), detail)
        }
        let before = pair.faults.requestCount(of: .read)
        let empty = try await file.read(from: 0, length: 0)
        XCTAssertEqual(empty, ByteBuffer())
        XCTAssertEqual(pair.faults.requestCount(of: .read), before)
        // 别的 offset 照常。
        let rest = try await file.read(from: 1, length: 10)
        XCTAssertEqual(rest, payload.getSlice(at: 1, length: 10))
        try await file.close()
    }

    /// 中间一段谎报 EOF、后面的段却有数据：是个洞，不能当成「读完了」。
    func testEOFFollowedByDataIsAHole() async throws {
        let second = chunk
        override { _, offset, _ in offset == second ? .eof : nil }
        do {
            _ = try await readAll()
            XCTFail("a hole was reported as success")
        } catch SFTPError.invalidResponse(let detail) {
            XCTAssertTrue(detail.contains("after end of file"), detail)
        }
    }

    /// 短读之后补发时谎报 EOF、后面的段有数据：同样是洞。
    func testShortReadThenEOFFollowedByDataIsAHole() async throws {
        let base = chunk
        override { _, offset, length in
            if offset == base { return .data(ByteBuffer(bytes: [UInt8](repeating: 7, count: 100))) }
            if offset == base + 100 { return .eof }
            return nil
        }
        do {
            _ = try await readAll()
            XCTFail("a hole was reported as success")
        } catch SFTPError.invalidResponse {}
    }

    /// 给了 expectedLength：服务端过早地报 EOF（文件变短、谎报）就是 shortRead。
    func testExpectedLengthTurnsAnEarlyEndIntoAnError() async throws {
        let cut = UInt64(payload.readableBytes - 1000)
        override { _, offset, length in
            if offset >= cut { return .eof }
            if offset + UInt64(length) > cut {
                return .data(ByteBuffer(bytes: [UInt8](repeating: 1, count: Int(cut - offset))))
            }
            return nil
        }
        await XCTAssertSFTPError(.shortRead(expected: payload.readableBytes, actual: payload.readableBytes - 1000)) {
            _ = try await self.readAll(expectedLength: self.payload.readableBytes)
        }
        // 不给 expectedLength 时，那就是文件尾（之后的段也都是 EOF），照常返回。
        let shorter = try await readAll()
        XCTAssertEqual(shorter.readableBytes, payload.readableBytes - 1000)
    }

    /// 长度 0 / 负数的读：不发请求，回空（OpenSSH 对它回 EOF，会被当成文件到头）。
    func testZeroLengthReadSendsNothing() async throws {
        let file = try await pair.client.openFile("/f", flags: .read)
        let before = pair.faults.requestCount(of: .read)
        let empty = try await file.read(from: 10, length: 0)
        XCTAssertEqual(empty, ByteBuffer())
        let negative = try await file.read(from: 10, length: -1)
        XCTAssertEqual(negative, ByteBuffer())
        XCTAssertEqual(pair.faults.requestCount(of: .read), before)
        try await file.close()
    }

    /// 越过 UInt64 上限的区间：本地抛 offsetOutOfRange，不 trap、不发。
    func testOffsetOverflowThrowsInsteadOfTrapping() async throws {
        let file = try await pair.client.openFile("/f", flags: [.read, .write])
        let before = pair.faults.requestCounts
        await XCTAssertSFTPError(.offsetOutOfRange) { _ = try await file.readAll(from: .max - 10) }
        await XCTAssertSFTPError(.offsetOutOfRange) { _ = try await file.readAll(from: .max - 10, expectedLength: 100) }
        await XCTAssertSFTPError(.offsetOutOfRange) { try await file.write(contentsOf: SFTPTestData.bytes(count: 100), at: .max - 10) }
        await XCTAssertSFTPError(.offsetOutOfRange) { try await file.write(SFTPTestData.bytes(count: 100), at: .max - 10) }
        XCTAssertEqual(pair.faults.requestCounts, before, "nothing was sent")
        // 正好到上限的单个读是合法请求。
        let atEnd = try await file.read(from: .max - 10, length: 10)
        XCTAssertNil(atEnd)
        try await file.close()
    }

    /// 服务端宣告的读写上限超过 uint32、本端收帧上限也开到很大：长度封顶在 `maximumTransferLength`（256 KiB），
    /// 读写照常、不 trap。
    func testHugeAdvertisedLimitsAreClampedToUInt32() async throws {
        await pair.shutdown()
        let huge = SFTPServerLimits(maximumPacketLength: .max, maximumReadLength: .max, maximumWriteLength: .max, maximumOpenHandles: 0)
        pair = try await SFTPLoopbackPair.make(
            server: SFTPServer.Configuration(limits: huge),
            client: SFTPClient.Configuration(maximumInboundPacketLength: Int.max),
            serving: memory)
        XCTAssertEqual(pair.client.maximumReadLength, SFTPClient.maximumTransferLength)
        XCTAssertEqual(pair.client.maximumWriteLength, SFTPClient.maximumTransferLength)
        let all = try await readAll()
        XCTAssertEqual(all, payload)
        let exact = try await readAll(expectedLength: 1234)
        XCTAssertEqual(exact, payload.getSlice(at: 0, length: 1234))
    }
}
