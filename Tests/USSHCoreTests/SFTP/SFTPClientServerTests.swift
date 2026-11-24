import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import USSHCore
import USSHTestServer

/// 客户端 ↔ 测试服务端，走真的本机 TCP 连接。
final class SFTPClientServerTests: XCTestCase {
    private var pair: SFTPLoopbackPair!

    override func setUp() async throws {
        pair = try await SFTPLoopbackPair.make()
    }

    override func tearDown() async throws {
        await pair?.shutdown()
        pair = nil
    }

    private var client: SFTPClient { pair.client }
    private var fs: SFTPLocalFileSystem { pair.fileSystem }

    private func putFile(_ path: String, _ contents: ByteBuffer) throws {
        FileManager.default.createFile(atPath: fs.hostPath(for: path), contents: Data(contents.readableBytesView))
    }

    private func hostContents(_ path: String) -> Data? {
        FileManager.default.contents(atPath: fs.hostPath(for: path))
    }

    // MARK: - 握手

    func testHandshakeAdvertisesExtensionsAndLimits() {
        XCTAssertEqual(client.serverVersion, 3)
        for name in [SFTPExtensionName.posixRename, SFTPExtensionName.statVFS, SFTPExtensionName.fstatVFS,
                     SFTPExtensionName.hardLink, SFTPExtensionName.fsync, SFTPExtensionName.lsetstat,
                     SFTPExtensionName.limits] {
            XCTAssertTrue(client.supportsExtension(name), name)
        }
        XCTAssertEqual(client.extensions[SFTPExtensionName.statVFS], "2")
        XCTAssertEqual(client.limits, SFTPServer.defaultLimits)
        XCTAssertEqual(client.maximumReadLength, 255 * 1024)
        XCTAssertEqual(client.maximumWriteLength, 255 * 1024)
        XCTAssertEqual(client.maximumPacketLength, 256 * 1024)
    }

    // MARK: - 文件

    func testWriteThenReadBack() async throws {
        let payload = SFTPTestData.bytes(count: 10_000)
        let file = try await client.openFile("/a.bin", flags: [.write, .create, .truncate],
                                             attributes: SFTPFileAttributes(permissions: 0o640))
        try await file.write(payload.getSlice(at: 0, length: 4000)!, at: 0)
        try await file.write(payload.getSlice(at: 4000, length: 6000)!, at: 4000)
        let value1 = try await file.stat().size
        XCTAssertEqual(value1, 10_000)
        try await file.sync()
        try await file.close()
        XCTAssertEqual(hostContents("/a.bin"), Data(payload.readableBytesView))

        let attributes = try await client.stat("/a.bin")
        XCTAssertEqual(attributes.size, 10_000)
        XCTAssertEqual(attributes.permissionBits, 0o640)
        XCTAssertTrue(attributes.isRegularFile)
        XCTAssertEqual(attributes.owner?.userID, getuid())
        XCTAssertNotNil(attributes.modificationDate)

        let reader = try await client.openFile("/a.bin", flags: .read)
        let head = try await reader.read(from: 0, length: 100)
        XCTAssertEqual(head, payload.getSlice(at: 0, length: 100))
        let tail = try await reader.read(from: 9_990, length: 100)
        XCTAssertEqual(tail?.readableBytes, 10, "short read at end of file")
        let eof = try await reader.read(from: 10_000, length: 100)
        XCTAssertNil(eof, "EOF is nil, not an error")
        let value2 = try await reader.readAll()
        XCTAssertEqual(value2, payload)
        let value3 = try await reader.readAll(from: 9_000)
        XCTAssertEqual(value3, payload.getSlice(at: 9_000, length: 1_000))
        try await reader.close()
    }

    func testCloseIsIdempotentAndHandleIsDeadAfterwards() async throws {
        try putFile("/x", ByteBuffer(string: "x"))
        let file = try await client.openFile("/x", flags: .read)
        let copy = file
        try await file.close()
        try await copy.close()
        try await file.close()
        XCTAssertTrue(copy.isClosed)
        XCTAssertEqual(pair.faults.requestCount(of: .close), 1, "only the first close goes out")
        await XCTAssertSFTPError(.handleClosed) { _ = try await copy.read(from: 0, length: 1) }
        await XCTAssertSFTPError(.handleClosed) { try await file.write(ByteBuffer(string: "y"), at: 0) }
    }

    func testWithFileClosesOnSuccessAndFailure() async throws {
        try putFile("/w", ByteBuffer(string: "hello"))
        let text = try await client.withFile("/w", flags: .read) { file in
            String(buffer: try await file.readAll())
        }
        XCTAssertEqual(text, "hello")
        struct Boom: Error {}
        do {
            _ = try await client.withFile("/w", flags: .read) { _ -> Int in throw Boom() }
            XCTFail("should throw")
        } catch is Boom {}
        try await pair.waitForRequests(.close, count: 2)
    }

    func testOpenFlagsSemantics() async throws {
        try putFile("/exists", ByteBuffer(string: "original"))
        // EXCL 撞上已存在：失败且不截断。
        await XCTAssertSFTPStatus(.failure) {
            _ = try await self.client.openFile("/exists", flags: [.write, .create, .exclusive])
        }
        XCTAssertEqual(hostContents("/exists"), Data("original".utf8))
        // 不带 TRUNC 的写只覆盖写到的那一段。
        try await client.withFile("/exists", flags: [.write]) { try await $0.write(ByteBuffer(string: "O"), at: 0) }
        XCTAssertEqual(hostContents("/exists"), Data("Original".utf8))
        // APPEND 落到文件尾。
        try await client.withFile("/exists", flags: [.write, .append]) { try await $0.write(ByteBuffer(string: "!"), at: 0) }
        XCTAssertEqual(hostContents("/exists"), Data("Original!".utf8))
        // TRUNC 清空。
        try await client.withFile("/exists", flags: [.write, .truncate]) { _ in }
        XCTAssertEqual(hostContents("/exists"), Data())
        await XCTAssertSFTPStatus(.noSuchFile) { _ = try await self.client.openFile("/missing", flags: .read) }
    }

    func testFileSetAttributesTruncatesAndChmods() async throws {
        try putFile("/t", SFTPTestData.bytes(count: 1000))
        let file = try await client.openFile("/t", flags: [.read, .write])
        try await file.setAttributes(SFTPFileAttributes(size: 10, permissions: 0o600))
        let after = try await file.stat()
        XCTAssertEqual(after.size, 10)
        XCTAssertEqual(after.permissionBits, 0o600)
        let stats = try await file.statVFS()
        XCTAssertGreaterThan(stats.blockSize, 0)
        try await file.close()
    }

    // MARK: - 目录

    func testDirectoryLifecycleAndBatchedListing() async throws {
        try await client.createDirectory("/dir", attributes: SFTPFileAttributes(permissions: 0o750))
        let value4 = try await client.stat("/dir").permissionBits
        XCTAssertEqual(value4, 0o750)
        let value5 = try await client.stat("/dir").isDirectory
        XCTAssertTrue(value5)
        // 250 项：服务端每批 100，客户端要读三批再拿到 EOF。
        for index in 0..<250 {
            try putFile("/dir/f\(index)", ByteBuffer(string: String(index)))
        }
        try await client.createDirectory("/dir/sub")
        let entries = try await client.listDirectory("/dir")
        XCTAssertEqual(entries.count, 251)
        XCTAssertFalse(entries.contains { $0.filename == "." || $0.filename == ".." })
        let f7 = try XCTUnwrap(entries.first { $0.filename == "f7" })
        XCTAssertEqual(f7.attributes.size, 1)
        XCTAssertTrue(f7.longname.hasSuffix("f7"))
        XCTAssertTrue(try XCTUnwrap(entries.first { $0.filename == "sub" }).attributes.isDirectory)
        XCTAssertGreaterThanOrEqual(pair.faults.requestCount(of: .readdir), 4)
        XCTAssertEqual(pair.faults.requestCount(of: .close), 1, "directory handle closed")

        let withDots = try await client.listDirectory("/dir", includingDotEntries: true)
        XCTAssertEqual(withDots.count, 253)

        await XCTAssertSFTPStatus(.failure) { try await self.client.removeDirectory("/dir") }
        try await client.removeDirectory("/dir/sub")
        await XCTAssertSFTPStatus(.noSuchFile) { _ = try await self.client.listDirectory("/nope") }
        await XCTAssertSFTPStatus(.noSuchFile) { _ = try await self.client.listDirectory("/dir/f1") }
    }

    func testListingClosesHandleWhenReaddirFails() async throws {
        try await client.createDirectory("/d")
        pair.faults.fail(.readdir, with: .permissionDenied)
        await XCTAssertSFTPStatus(.permissionDenied) { _ = try await self.client.listDirectory("/d") }
        try await pair.waitForRequests(.close, count: 1)
    }

    // MARK: - 路径

    func testRealPath() async throws {
        try await client.createDirectory("/a")
        let value6 = try await client.realPath(".")
        XCTAssertEqual(value6, "/")
        let value7 = try await client.realPath("/a/../a/./")
        XCTAssertEqual(value7, "/a")
        let value8 = try await client.realPath("a")
        XCTAssertEqual(value8, "/a")
        let value9 = try await client.realPath("/../../..")
        XCTAssertEqual(value9, "/", "cannot climb out of the root")
    }

    func testRemoveAndStatErrors() async throws {
        try putFile("/f", ByteBuffer(string: "1"))
        try await client.remove("/f")
        XCTAssertNil(hostContents("/f"))
        await XCTAssertSFTPStatus(.noSuchFile) { try await self.client.remove("/f") }
        await XCTAssertSFTPStatus(.noSuchFile) { _ = try await self.client.stat("/f") }
        await XCTAssertSFTPStatus(.noSuchFile) { _ = try await self.client.lstat("/f") }
    }

    func testRenameModes() async throws {
        try putFile("/a", ByteBuffer(string: "A"))
        try putFile("/b", ByteBuffer(string: "B"))
        // 标准 RENAME 不覆盖。
        await XCTAssertSFTPStatus(.failure) { try await self.client.rename("/a", to: "/b") }
        XCTAssertEqual(hostContents("/b"), Data("B".utf8))
        // posix-rename 覆盖。
        try await client.rename("/a", to: "/b", mode: .posix)
        XCTAssertEqual(hostContents("/b"), Data("A".utf8))
        XCTAssertNil(hostContents("/a"))
        XCTAssertEqual(pair.faults.requestCount(of: .extended(SFTPExtensionName.posixRename)), 1)
        try await client.rename("/b", to: "/c", mode: .posixIfSupported)
        XCTAssertEqual(pair.faults.requestCount(of: .extended(SFTPExtensionName.posixRename)), 2)
        try await client.rename("/c", to: "/d")
        XCTAssertEqual(pair.faults.requestCount(of: .rename), 2)
        XCTAssertEqual(hostContents("/d"), Data("A".utf8))
    }

    func testLinks() async throws {
        try putFile("/target", ByteBuffer(string: "T"))
        try await client.createSymlink(at: "/link", pointingTo: "/target")
        let value10 = try await client.readLink("/link")
        XCTAssertEqual(value10, "/target")
        let value11 = try await client.lstat("/link").isSymbolicLink
        XCTAssertTrue(value11)
        let value12 = try await client.stat("/link").isRegularFile
        XCTAssertTrue(value12)
        // 相对目标原样保存。
        try await client.createSymlink(at: "/rel", pointingTo: "target")
        let value13 = try await client.readLink("/rel")
        XCTAssertEqual(value13, "target")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fs.hostPath(for: "/rel")), "target")

        try await client.createHardLink(at: "/hard", pointingTo: "/target")
        let original = try FileManager.default.attributesOfItem(atPath: fs.hostPath(for: "/target"))
        let hard = try FileManager.default.attributesOfItem(atPath: fs.hostPath(for: "/hard"))
        XCTAssertEqual(original[.systemFileNumber] as? Int, hard[.systemFileNumber] as? Int)

        // lsetstat 改的是链接本身。
        let old = SFTPFileTimes(accessSeconds: 1_000_000_000, modificationSeconds: 1_000_000_000)
        try await client.setAttributes(SFTPFileAttributes(times: old), at: "/link", followingSymlinks: false)
        let value14 = try await client.lstat("/link").times?.modificationSeconds
        XCTAssertEqual(value14, old.modificationSeconds)
        let value15 = try await client.stat("/link").times?.modificationSeconds
        XCTAssertNotEqual(value15, old.modificationSeconds)
        try await client.setAttributes(SFTPFileAttributes(times: old), at: "/link")
        let value16 = try await client.stat("/target").times?.modificationSeconds
        XCTAssertEqual(value16, old.modificationSeconds)
    }

    func testStatVFS() async throws {
        let stats = try await client.statVFS("/")
        XCTAssertGreaterThan(stats.blockSize, 0)
        XCTAssertGreaterThan(stats.totalBlocks, 0)
        XCTAssertGreaterThan(stats.totalBytes, 0)
        await XCTAssertSFTPStatus(.noSuchFile) { _ = try await self.client.statVFS("/missing") }
    }

    func testPathConfinement() async throws {
        // 字面的 `..` 到根为止。
        await XCTAssertSFTPStatus(.noSuchFile) { _ = try await self.client.stat("/../../../../etc/hosts") }
        // 根目录里一个指向外面的链接：跟随它的操作一律拒绝。
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-outside-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outside.path, contents: Data("secret".utf8))
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(atPath: fs.hostPath(for: "/escape"), withDestinationPath: outside.path)
        await XCTAssertSFTPStatus(.permissionDenied) { _ = try await self.client.stat("/escape") }
        await XCTAssertSFTPStatus(.permissionDenied) { _ = try await self.client.openFile("/escape", flags: .read) }
        await XCTAssertSFTPStatus(.permissionDenied) { _ = try await self.client.realPath("/escape") }
        // 不跟随的操作看得到链接本身。
        let value17 = try await client.lstat("/escape").isSymbolicLink
        XCTAssertTrue(value17)
    }

    // MARK: - 错误映射

    /// 每个状态码、每类操作，都以 `SFTPError.status` 抛出。
    func testEveryStatusCodeSurfacesAsStatusError() async throws {
        try putFile("/f", ByteBuffer(string: "data"))
        let file = try await client.openFile("/f", flags: [.read, .write])
        let codes: [SFTPStatusCode] = [.eof, .noSuchFile, .permissionDenied, .failure, .badMessage, .noConnection,
                                       .connectionLost, .operationUnsupported, .fileAlreadyExists, SFTPStatusCode(4242)]
        let operations: [(SFTPServerOperation, () async throws -> Void)] = [
            (.stat, { _ = try await self.client.stat("/f") }),
            (.lstat, { _ = try await self.client.lstat("/f") }),
            (.open, { _ = try await self.client.openFile("/f", flags: .read) }),
            (.opendir, { _ = try await self.client.listDirectory("/") }),
            (.remove, { try await self.client.remove("/nothing") }),
            (.mkdir, { try await self.client.createDirectory("/nothing") }),
            (.rmdir, { try await self.client.removeDirectory("/nothing") }),
            (.rename, { try await self.client.rename("/nothing", to: "/else") }),
            (.setstat, { try await self.client.setAttributes(SFTPFileAttributes(permissions: 0o644), at: "/f") }),
            (.realpath, { _ = try await self.client.realPath("/") }),
            (.readlink, { _ = try await self.client.readLink("/f") }),
            (.symlink, { try await self.client.createSymlink(at: "/s", pointingTo: "/f") }),
            (.write, { try await file.write(ByteBuffer(string: "x"), at: 0) }),
            (.fstat, { _ = try await file.stat() }),
            (.fsetstat, { try await file.setAttributes(SFTPFileAttributes(size: 4)) }),
            (.extended(SFTPExtensionName.statVFS), { _ = try await self.client.statVFS("/") }),
            (.extended(SFTPExtensionName.fsync), { try await file.sync() }),
        ]
        for code in codes {
            for (operation, body) in operations {
                pair.faults.fail(operation, with: code, message: "injected \(code.rawValue)")
                do {
                    try await body()
                    XCTFail("\(operation) succeeded despite injected \(code)")
                } catch let error as SFTPError {
                    XCTAssertEqual(error, .status(code: code, message: "injected \(code.rawValue)", languageTag: "en"),
                                   "\(operation)")
                } catch {
                    XCTFail("\(operation) threw \(type(of: error)): \(error)")
                }
            }
        }
        // READ 的 EOF 不是错误，其余状态码是。
        pair.faults.fail(.read, with: .permissionDenied)
        await XCTAssertSFTPStatus(.permissionDenied) { _ = try await file.read(from: 0, length: 1) }
        pair.faults.fail(.read, with: .eof)
        let eof = try await file.read(from: 0, length: 1)
        XCTAssertNil(eof)
        pair.faults.fail(.close, with: .failure)
        await XCTAssertSFTPStatus(.failure) { try await file.close() }
    }

    func testFailNthOperation() async throws {
        try putFile("/f", ByteBuffer(string: "data"))
        pair.faults.fail(.stat, occurrence: 3, with: .permissionDenied)
        _ = try await client.stat("/f")
        _ = try await client.stat("/f")
        await XCTAssertSFTPStatus(.permissionDenied) { _ = try await self.client.stat("/f") }
        _ = try await client.stat("/f")
    }

    // MARK: - 并发与乱序

    /// 128 个 READ 同时在途，服务端每 64 个一批倒序回答：每个调用拿到的必须是自己那一段。
    func testConcurrentReadsAnsweredOutOfOrder() async throws {
        let chunk = 4096
        let count = 128
        let payload = SFTPTestData.bytes(count: chunk * count)
        try putFile("/big", payload)
        let file = try await client.openFile("/big", flags: .read)
        pair.faults.reverseResponseOrder(batchSize: 64)
        let order = OrderRecorder()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    let data = try await file.read(from: UInt64(index * chunk), length: chunk)
                    XCTAssertEqual(data, payload.getSlice(at: index * chunk, length: chunk), "chunk \(index)")
                    order.record(index)
                }
            }
            try await group.waitForAll()
        }
        pair.faults.reverseResponseOrder(batchSize: nil)
        XCTAssertEqual(pair.faults.requestCount(of: .read), count)
        XCTAssertNotEqual(order.values, order.values.sorted(), "responses really arrived out of order")
        try await file.close()
    }

    /// 同一条通道上混着几百个不同类型的请求并发。
    func testManyMixedConcurrentRequests() async throws {
        for index in 0..<50 { try putFile("/m\(index)", ByteBuffer(string: String(repeating: "x", count: index))) }
        let client = self.client
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    let size = try await client.stat("/m\(index)").size
                    XCTAssertEqual(size, UInt64(index))
                }
                group.addTask {
                    let path = try await client.realPath("m\(index)")
                    XCTAssertEqual(path, "/m\(index)")
                }
                group.addTask {
                    let data = try await client.withFile("/m\(index)", flags: .read) { try await $0.readAll() }
                    XCTAssertEqual(data.readableBytes, index)
                }
                group.addTask { _ = try await client.listDirectory("/") }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - 大文件

    func testLargeFileIntegrity() async throws {
        let size = 64 * 1024 * 1024 + 12_345
        let payload = SFTPTestData.bytes(count: size)
        let expected = SFTPTestData.sha256(payload)
        try await client.withFile("/large", flags: [.write, .create, .truncate]) { file in
            try await file.write(contentsOf: payload, window: 32)
        }
        XCTAssertEqual(try SFTPTestData.sha256(fileAt: fs.hostPath(for: "/large")), expected)
        let value18 = try await client.stat("/large").size
        XCTAssertEqual(value18, UInt64(size))
        let back = try await client.withFile("/large", flags: .read) { try await $0.readAll(window: 32) }
        XCTAssertEqual(back.readableBytes, size)
        XCTAssertEqual(SFTPTestData.sha256(back), expected)
    }

    func testReadAllRespectsMaximumBytes() async throws {
        try putFile("/f", SFTPTestData.bytes(count: 100_000))
        let file = try await client.openFile("/f", flags: .read)
        await XCTAssertSFTPError(.limitExceeded(maximumBytes: 50_000)) { _ = try await file.readAll(maximumBytes: 50_000) }
        let value19 = try await file.readAll(maximumBytes: 100_000).readableBytes
        XCTAssertEqual(value19, 100_000)
        try await file.close()
    }

    func testOversizedWriteIsRejectedLocally() async throws {
        let file = try await client.openFile("/w", flags: [.write, .create])
        await XCTAssertSFTPError(.requestTooLarge(length: client.maximumWriteLength + 1, limit: client.maximumWriteLength)) {
            try await file.write(SFTPTestData.bytes(count: self.client.maximumWriteLength + 1), at: 0)
        }
        XCTAssertEqual(pair.faults.requestCount(of: .write), 0)
        try await file.close()
    }

    // MARK: - 短读

    func testShortReadsAreFilledIn() async throws {
        let payload = SFTPTestData.bytes(count: 300_000)
        try putFile("/s", payload)
        pair.faults.limitReadLength(to: 1000)
        let file = try await client.openFile("/s", flags: .read)
        let one = try await file.read(from: 0, length: 64 * 1024)
        XCTAssertEqual(one?.readableBytes, 1000)
        let all = try await file.readAll(window: 8)
        XCTAssertEqual(all, payload)
        try await file.close()
    }

    // MARK: - 关闭、断线、取消

    func testClosingFailsEveryPendingRequest() async throws {
        try putFile("/f", ByteBuffer(string: "x"))
        pair.faults.withholdResponses(of: .stat)
        let results = ResultCollector()
        let client = self.client
        let tasks = (0..<20).map { _ in
            Task {
                do {
                    _ = try await client.stat("/f")
                    results.add("success")
                } catch {
                    results.add(error)
                }
            }
        }
        try await pair.waitForRequests(.stat, count: 20)
        await client.close()
        for task in tasks { await task.value }
        XCTAssertEqual(results.errors.count, 20)
        for error in results.errors {
            XCTAssertEqual(error as? SFTPError, .connectionClosed)
        }
        await XCTAssertSFTPError(.connectionClosed) { _ = try await self.client.stat("/f") }
        XCTAssertFalse(client.isActive)
    }

    /// 测试服务端也照 OpenSSH 复用句柄编号：关闭和另一份拷贝上并发的读写交错时，旧句柄上的请求不能落进新文件，
    /// 关闭开始之后线上也不再出现这个句柄的请求。
    func testCloseWaitsForInFlightAndBlocksLaterRequests() async throws {
        // 每个 WRITE 的回答慢 20 ms：16 MiB / 255 KiB ≈ 65 片、窗口 8，写一遍要好几轮，关闭一定落在中途。
        let payload = SFTPTestData.bytes(count: 16 * 1024 * 1024)
        pair.faults.delayResponses(of: .write, by: .milliseconds(20))
        for trial in 0..<4 {
            let a = try await client.openFile("/a\(trial)", flags: [.write, .create, .truncate])
            let before = pair.faults.requestCount(of: .write)
            let writer = Task { try await a.write(contentsOf: payload, window: 8) }
            try await pair.waitForRequests(.write, count: before + 1)
            try await a.close()
            let writesAtClose = pair.faults.requestCount(of: .write)
            let b = try await client.openFile("/b\(trial)", flags: [.write, .create, .truncate])
            XCTAssertEqual(b.handle, a.handle, "the test server reuses the slot like OpenSSH")
            do {
                try await writer.value
            } catch let error as SFTPError {
                XCTAssertEqual(error, .handleClosed)
            }
            XCTAssertEqual(pair.faults.requestCount(of: .write), writesAtClose, "no WRITE after the CLOSE")
            try await b.close()
            XCTAssertEqual(hostContents("/b\(trial)"), Data(), "stale WRITE landed in the reused handle")
            XCTAssertLessThan(hostContents("/a\(trial)")?.count ?? 0, payload.readableBytes, "close happened mid-transfer")
        }
        pair.faults.delayResponses(of: .write, by: nil)
    }

    func testCancellingCloseStillClosesLater() async throws {
        try putFile("/f", SFTPTestData.bytes(count: 10))
        let file = try await client.openFile("/f", flags: .read)
        pair.faults.delayResponses(of: .read, by: .milliseconds(300))
        let reader = Task { try await file.read(from: 0, length: 10) }
        try await pair.waitForRequests(.read, count: 1)
        let closer = Task { try await file.close() }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(pair.faults.requestCount(of: .close), 0, "CLOSE waits for the READ in flight")
        closer.cancel()
        do {
            try await closer.value
            XCTFail("close should report cancellation")
        } catch is CancellationError {}
        _ = try await reader.value
        try await pair.waitForRequests(.close, count: 1)
        pair.faults.delayResponses(of: .read, by: nil)
    }

    func testServerDroppingMidRequestFailsPending() async throws {
        try putFile("/f", SFTPTestData.bytes(count: 1000))
        let file = try await client.openFile("/f", flags: .read)
        pair.faults.dropConnection(on: .read)
        await XCTAssertSFTPError(.connectionClosed) { _ = try await file.read(from: 0, length: 10) }
        await XCTAssertSFTPError(.connectionClosed) { _ = try await self.client.stat("/f") }
    }

    func testCancellationReturnsPromptlyAndDropsTheLateResponse() async throws {
        let payload = SFTPTestData.bytes(count: 1000)
        try putFile("/f", payload)
        let file = try await client.openFile("/f", flags: .read)
        pair.faults.delayResponses(of: .read, by: .milliseconds(400))
        let started = ContinuousClock.now
        let task = Task { try await file.read(from: 0, length: 10) }
        try await pair.waitForRequests(.read, count: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled read returned")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(350), "did not wait for the server")
        // 让迟到的回答到达，再发一个新请求：它不能被旧回答顶替。
        try await Task.sleep(for: .milliseconds(450))
        pair.faults.delayResponses(of: .read, by: nil)
        let next = try await file.read(from: 500, length: 10)
        XCTAssertEqual(next, payload.getSlice(at: 500, length: 10))
        try await file.close()
    }

    func testCancelledTaskBeforeSendingThrowsImmediately() async throws {
        let client = self.client
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.stat("/")
        }
        do {
            _ = try await task.value
            XCTFail("should be cancelled")
        } catch is CancellationError {}
        XCTAssertEqual(pair.faults.requestCount(of: .stat), 0)
    }

    /// 取消一个正在等句柄的 open：服务端迟到地开出了句柄，客户端替调用方把它关掉。
    func testCancelledOpenClosesTheLateHandle() async throws {
        try putFile("/f", ByteBuffer(string: "x"))
        pair.faults.delayResponses(of: .open, by: .milliseconds(200))
        let client = self.client
        let task = Task { try await client.openFile("/f", flags: .read) }
        try await pair.waitForRequests(.open, count: 1)
        task.cancel()
        _ = try? await task.value
        try await pair.waitForRequests(.close, count: 1)
        pair.faults.delayResponses(of: .open, by: nil)
        let value20 = try await client.stat("/f").size
        XCTAssertEqual(value20, 1, "channel still healthy")
    }

    // MARK: - 背压与切分

    func testWritesWithTinyWriteBufferGoThroughBacklog() async throws {
        await pair.shutdown()
        pair = try await SFTPLoopbackPair.make(lowWriteWatermark: true)
        let payload = SFTPTestData.bytes(count: 8 * 1024 * 1024)
        try await client.withFile("/bp", flags: [.write, .create, .truncate]) { file in
            try await file.write(contentsOf: payload, window: 64)
        }
        XCTAssertEqual(try SFTPTestData.sha256(fileAt: fs.hostPath(for: "/bp")), SFTPTestData.sha256(payload))
        // 不可写期间被取消的请求不能把状态搞乱。
        let client = self.client
        let tasks = (0..<200).map { index in Task { try await client.stat(index.isMultiple(of: 2) ? "/bp" : "/") } }
        for task in tasks.prefix(100) { task.cancel() }
        for task in tasks { _ = try? await task.value }
        let value21 = try await client.stat("/bp").size
        XCTAssertEqual(value21, UInt64(payload.readableBytes))
    }

    func testOneByteFragmentsFromTransport() async throws {
        await pair.shutdown()
        pair = try await SFTPLoopbackPair.make(fragmentInboundTo: 1)
        let payload = SFTPTestData.bytes(count: 300_000)
        try await client.withFile("/frag", flags: [.write, .create]) { try await $0.write(contentsOf: payload) }
        let back = try await client.withFile("/frag", flags: .read) { try await $0.readAll() }
        XCTAssertEqual(back, payload)
        let value22 = try await client.listDirectory("/").map(\.filename)
        XCTAssertEqual(value22, ["frag"])
    }

    // MARK: - 缺扩展时的退路

    func testMissingExtensionsFallBack() async throws {
        await pair.shutdown()
        pair = try await SFTPLoopbackPair.make(server: SFTPServer.Configuration(extensions: [:]))
        XCTAssertNil(client.limits)
        XCTAssertTrue(client.extensions.isEmpty)
        XCTAssertEqual(client.maximumReadLength, 32 * 1024)
        XCTAssertEqual(client.maximumWriteLength, 32 * 1024)
        XCTAssertEqual(client.maximumPacketLength, 34_000)

        try putFile("/a", ByteBuffer(string: "A"))
        try putFile("/b", ByteBuffer(string: "B"))
        // posixIfSupported 退回标准 RENAME（不覆盖）。
        await XCTAssertSFTPStatus(.failure) { try await self.client.rename("/a", to: "/b", mode: .posixIfSupported) }
        XCTAssertEqual(pair.faults.requestCount(of: .rename), 1)
        try await client.rename("/a", to: "/c", mode: .posixIfSupported)
        // 要求扩展的操作不发请求，直接报不支持。
        await XCTAssertSFTPError(.extensionUnsupported(SFTPExtensionName.posixRename)) {
            try await self.client.rename("/c", to: "/b", mode: .posix)
        }
        await XCTAssertSFTPError(.extensionUnsupported(SFTPExtensionName.statVFS)) { _ = try await self.client.statVFS("/") }
        await XCTAssertSFTPError(.extensionUnsupported(SFTPExtensionName.hardLink)) {
            try await self.client.createHardLink(at: "/h", pointingTo: "/c")
        }
        await XCTAssertSFTPError(.extensionUnsupported(SFTPExtensionName.lsetstat)) {
            try await self.client.setAttributes(.none, at: "/c", followingSymlinks: false)
        }
        let file = try await client.openFile("/c", flags: [.read, .write])
        await XCTAssertSFTPError(.extensionUnsupported(SFTPExtensionName.fsync)) { try await file.sync() }
        await XCTAssertSFTPError(.extensionUnsupported(SFTPExtensionName.fstatVFS)) { _ = try await file.statVFS() }
        XCTAssertTrue(pair.faults.requestCounts.keys.allSatisfy {
            if case .extended = $0 { return false }
            return true
        }, "no extended request was sent")

        // 没有 limits 时按 32 KiB 切片；超过的单个 WRITE 本地就拒。
        await XCTAssertSFTPError(.requestTooLarge(length: 40_000, limit: 32 * 1024)) {
            try await file.write(SFTPTestData.bytes(count: 40_000), at: 0)
        }
        let payload = SFTPTestData.bytes(count: 100_000)
        try await file.write(contentsOf: payload)
        XCTAssertEqual(pair.faults.requestCount(of: .write), 4)
        let value23 = try await file.readAll()
        XCTAssertEqual(value23, payload)
        try await file.close()
    }

    func testClientCanSkipTheLimitsQuery() async throws {
        await pair.shutdown()
        pair = try await SFTPLoopbackPair.make(client: SFTPClient.Configuration(queriesLimits: false))
        XCTAssertNil(client.limits)
        XCTAssertTrue(client.supportsExtension(SFTPExtensionName.limits))
        XCTAssertEqual(client.maximumWriteLength, 32 * 1024)
    }

    func testServerLimitsBoundReadAndWriteLengths() async throws {
        await pair.shutdown()
        let limits = SFTPServerLimits(maximumPacketLength: 70_000, maximumReadLength: 50_000,
                                      maximumWriteLength: 60_000, maximumOpenHandles: 10)
        pair = try await SFTPLoopbackPair.make(server: SFTPServer.Configuration(limits: limits))
        XCTAssertEqual(client.limits, limits)
        XCTAssertEqual(client.maximumReadLength, 50_000)
        XCTAssertEqual(client.maximumWriteLength, 60_000)
        // 本端收帧上限比服务端的读上限小时，按本端的来。
        await pair.shutdown()
        pair = try await SFTPLoopbackPair.make(client: SFTPClient.Configuration(maximumInboundPacketLength: 20_000))
        XCTAssertEqual(client.maximumReadLength, 20_000 - 1024)
        let payload = SFTPTestData.bytes(count: 100_000)
        try putFile("/r", payload)
        let value24 = try await client.withFile("/r", flags: .read) { try await $0.readAll() }
        XCTAssertEqual(value24, payload)
    }
}

/// 记下完成顺序（测试里并发写）。
final class OrderRecorder: @unchecked Sendable {
    // @unchecked：所有访问都在 `lock` 里。
    private let lock = NSLock()
    private var storage: [Int] = []

    func record(_ value: Int) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class ResultCollector: @unchecked Sendable {
    // @unchecked：所有访问都在 `lock` 里。
    private let lock = NSLock()
    private var storedErrors: [any Error] = []
    private var successes = 0

    func add(_ error: any Error) {
        lock.lock()
        storedErrors.append(error)
        lock.unlock()
    }

    func add(_ success: String) {
        lock.lock()
        successes += 1
        lock.unlock()
    }

    var errors: [any Error] {
        lock.lock()
        defer { lock.unlock() }
        return storedErrors
    }
}
