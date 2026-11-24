import NIOConcurrencyHelpers
import NIOCore
import XCTest
@testable import USSHCore
import USSHTestServer

/// 测试服务端的句柄：同一个句柄上的操作串行（CLOSE 等它前面的做完），不同句柄并发；编号照 OpenSSH 复用。
final class SFTPServerHandleTests: XCTestCase {

    /// 记下每个文件同时有几个操作在跑、CLOSE 时还有几个在跑。
    final class Recorder: Sendable {
        private struct State {
            var active: [String: Int] = [:]
            var maxPerFile: [String: Int] = [:]
            var totalActive = 0
            var maxTotal = 0
            var activeAtClose: [Int] = []
        }

        private let state = NIOLockedValueBox(State())

        func begin(_ name: String) {
            state.withLockedValue { state in
                state.active[name, default: 0] += 1
                state.maxPerFile[name] = max(state.maxPerFile[name] ?? 0, state.active[name]!)
                state.totalActive += 1
                state.maxTotal = max(state.maxTotal, state.totalActive)
            }
        }

        func end(_ name: String) {
            state.withLockedValue { state in
                state.active[name, default: 0] -= 1
                state.totalActive -= 1
            }
        }

        func closing(_ name: String) {
            state.withLockedValue { $0.activeAtClose.append($0.active[name] ?? 0) }
        }

        var maxPerFile: [String: Int] { state.withLockedValue { $0.maxPerFile } }
        var maxTotal: Int { state.withLockedValue { $0.maxTotal } }
        var activeAtClose: [Int] { state.withLockedValue { $0.activeAtClose } }
    }

    /// 只能打开文件；每次读都慢一点，好让并发显出来。
    final class SlowFileSystem: SFTPServerFileSystem {
        let recorder = Recorder()

        struct SlowFile: SFTPServerFile {
            let name: String
            let recorder: Recorder

            func read(at offset: UInt64, length: Int) async throws -> ByteBuffer? {
                recorder.begin(name)
                defer { recorder.end(name) }
                try await Task.sleep(for: .milliseconds(15))
                return ByteBuffer(bytes: [UInt8](repeating: 1, count: min(length, 8)))
            }

            func write(_ data: ByteBuffer, at offset: UInt64) async throws {}
            func attributes() async throws -> SFTPFileAttributes { SFTPFileAttributes(size: 8) }
            func close() async throws { recorder.closing(name) }
        }

        func openFile(_ path: SFTPPath, flags: SFTPOpenFlags, attributes: SFTPFileAttributes) async throws -> any SFTPServerFile {
            SlowFile(name: path.string, recorder: recorder)
        }

        func realPath(_ path: SFTPPath) async throws -> SFTPPath { path }
        func attributes(at path: SFTPPath, followingSymlinks: Bool) async throws -> SFTPFileAttributes { .none }
        func openDirectory(_ path: SFTPPath) async throws -> any SFTPServerDirectory { throw SFTPServerStatusError.unsupported() }
        func removeFile(_ path: SFTPPath) async throws { throw SFTPServerStatusError.unsupported() }
        func createDirectory(_ path: SFTPPath, attributes: SFTPFileAttributes) async throws { throw SFTPServerStatusError.unsupported() }
        func removeDirectory(_ path: SFTPPath) async throws { throw SFTPServerStatusError.unsupported() }
        func rename(_ oldPath: SFTPPath, to newPath: SFTPPath, replacingExisting: Bool) async throws {
            throw SFTPServerStatusError.unsupported()
        }
    }

    func testOperationsOnOneHandleAreSerialisedAndCloseWaits() async throws {
        let slow = SlowFileSystem()
        let pair = try await SFTPLoopbackPair.make(serving: slow)
        let a = try await pair.client.openFile("/a", flags: .read)
        let b = try await pair.client.openFile("/b", flags: .read)
        let core = pair.client.core

        // 直接往线上压：每个句柄 6 个 READ，紧跟一个 CLOSE（不等 READ 回来）。
        var requests: [SFTPInFlightRequest] = []
        for file in [a, b] {
            for index in 0..<6 {
                requests.append(core.submit { .read(id: $0, handle: file.handle, offset: UInt64(index * 8), length: 8) })
            }
        }
        let closeA = core.submit { .close(id: $0, handle: a.handle) }
        let closeB = core.submit { .close(id: $0, handle: b.handle) }
        for request in requests {
            guard case .data(_, let data) = try await core.wait(request) else { return XCTFail("READ did not return data") }
            XCTAssertEqual(data.readableBytes, 8)
        }
        try SFTPResponseReader.ok(try await core.wait(closeA))
        try SFTPResponseReader.ok(try await core.wait(closeB))

        XCTAssertEqual(slow.recorder.maxPerFile["/a"], 1, "one operation at a time on a handle")
        XCTAssertEqual(slow.recorder.maxPerFile["/b"], 1)
        XCTAssertGreaterThanOrEqual(slow.recorder.maxTotal, 2, "different handles still run concurrently")
        XCTAssertEqual(slow.recorder.activeAtClose, [0, 0], "CLOSE ran after the reads before it")

        // 已经关了的句柄：之后的请求回「句柄无效」。
        let late = try await core.wait(core.submit { .read(id: $0, handle: a.handle, offset: 0, length: 8) })
        XCTAssertThrowsError(try SFTPResponseReader.readData(late, requested: 8)) { error in
            XCTAssertEqual((error as? SFTPError)?.statusCode, .failure)
        }
        await pair.shutdown()
    }

    /// 编号照 OpenSSH 复用：刚释放的先用。
    func testHandleNumbersAreReusedLikeOpenSSH() async throws {
        let pair = try await SFTPLoopbackPair.make()
        FileManager.default.createFile(atPath: pair.fileSystem.hostPath(for: "/f"), contents: Data())
        let first = try await pair.client.openFile("/f", flags: .read)
        let second = try await pair.client.openFile("/f", flags: .read)
        XCTAssertNotEqual(first.handle, second.handle)
        try await first.close()
        let third = try await pair.client.openFile("/f", flags: .read)
        XCTAssertEqual(third.handle, first.handle, "freed slot is handed out again")
        try await second.close()
        try await third.close()
        let fourth = try await pair.client.openFile("/f", flags: .read)
        XCTAssertEqual(fourth.handle, third.handle, "most recently freed first")
        try await fourth.close()
        await pair.shutdown()
    }
}
