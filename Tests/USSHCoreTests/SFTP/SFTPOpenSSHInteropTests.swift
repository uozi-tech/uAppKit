import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import USSHCore

/// 对着系统自带的 OpenSSH sftp-server（`/usr/libexec/sftp-server`）跑：子进程的 stdin / stdout 接到
/// `NIOPipeBootstrap` 的通道上，中间没有 SSH，只有 SFTP 字节流。这是证明协议实现正确的那一组。
///
/// 服务端以 `-d <临时目录>` 启动，所有路径都是该目录下的真实绝对路径。
final class SFTPOpenSSHInteropTests: XCTestCase {
    private var server: OpenSSHServer?
    private var client: SFTPClient!
    private var root: String!
    private var process: Process? { server?.process }
    private var exit: ProcessExitSignal { server!.exit }

    override func setUp() async throws {
        let server = try await OpenSSHServer.start()
        self.server = server
        client = server.client
        root = server.root
    }

    override func tearDown() async throws {
        await server?.stop()
        server = nil
        client = nil
    }

    private func path(_ name: String) -> String { root + "/" + name }

    private func put(_ name: String, _ data: Data) {
        FileManager.default.createFile(atPath: path(name), contents: data)
    }

    // MARK: - 握手与限制

    func testHandshakeExtensionsAndLimits() throws {
        XCTAssertEqual(client.serverVersion, 3)
        for name in [SFTPExtensionName.posixRename, SFTPExtensionName.statVFS, SFTPExtensionName.fstatVFS,
                     SFTPExtensionName.hardLink, SFTPExtensionName.fsync, SFTPExtensionName.lsetstat,
                     SFTPExtensionName.limits] {
            XCTAssertTrue(client.supportsExtension(name), "OpenSSH advertises \(name)")
        }
        let limits = try XCTUnwrap(client.limits)
        XCTAssertGreaterThanOrEqual(limits.maximumPacketLength, 34_000)
        XCTAssertGreaterThan(limits.maximumReadLength, 0)
        XCTAssertGreaterThan(limits.maximumWriteLength, 0)
        XCTAssertEqual(client.maximumReadLength, Int(limits.maximumReadLength))
        XCTAssertEqual(client.maximumWriteLength, Int(limits.maximumWriteLength))
    }

    /// 正好 `maximumWriteLength` 的单个 WRITE、正好 `maximumReadLength` 的单个 READ，服务端都收。
    func testRequestsAtTheAdvertisedLimits() async throws {
        let size = client.maximumWriteLength
        let payload = SFTPTestData.bytes(count: size)
        let file = try await client.openFile(path("limit"), flags: [.read, .write, .create, .truncate])
        try await file.write(payload, at: 0)
        let back = try await file.read(from: 0, length: client.maximumReadLength)
        XCTAssertEqual(back, payload.getSlice(at: 0, length: min(size, client.maximumReadLength)))
        try await file.close()
    }

    func testUnknownExtensionIsOperationUnsupported() async throws {
        let response = try await client.core.perform {
            .extended(id: $0, request: .other(name: "nonexistent@example.com", data: ByteBuffer()))
        }
        XCTAssertThrowsError(try SFTPResponseReader.ok(response)) { error in
            XCTAssertEqual((error as? SFTPError)?.statusCode, .operationUnsupported)
        }
    }

    // MARK: - 文件与属性

    func testFileRoundTripAndAttributes() async throws {
        let payload = SFTPTestData.bytes(count: 123_457)
        let file = try await client.openFile(path("a"), flags: [.write, .create, .truncate],
                                             attributes: SFTPFileAttributes(permissions: 0o640))
        try await file.write(contentsOf: payload)
        let fstat = try await file.stat()
        XCTAssertEqual(fstat.size, 123_457)
        try await file.sync()
        try await file.close()
        XCTAssertEqual(FileManager.default.contents(atPath: path("a")), Data(payload.readableBytesView))

        let times = SFTPFileTimes(accessSeconds: 1_600_000_000, modificationSeconds: 1_650_000_000)
        try await client.setAttributes(SFTPFileAttributes(permissions: 0o604, times: times), at: path("a"))
        let attributes = try await client.stat(path("a"))
        XCTAssertEqual(attributes.size, 123_457)
        XCTAssertEqual(attributes.permissionBits, 0o604)
        XCTAssertTrue(attributes.isRegularFile)
        XCTAssertEqual(attributes.owner?.userID, getuid())
        XCTAssertEqual(attributes.times, times)
        let local = try FileManager.default.attributesOfItem(atPath: path("a"))
        XCTAssertEqual((local[.modificationDate] as? Date)?.timeIntervalSince1970, 1_650_000_000)
        XCTAssertEqual(local[.posixPermissions] as? Int, 0o604)

        let reader = try await client.openFile(path("a"), flags: .read)
        let value1 = try await reader.readAll()
        XCTAssertEqual(value1, payload)
        let tail = try await reader.read(from: 123_450, length: 100)
        XCTAssertEqual(tail?.readableBytes, 7, "short read at the end")
        let eof = try await reader.read(from: 123_457, length: 100)
        XCTAssertNil(eof)
        let far = try await reader.read(from: 1 << 40, length: 100)
        XCTAssertNil(far)
        try await reader.close()

        // ftruncate 经 fsetstat。
        try await client.withFile(path("a"), flags: [.write]) { try await $0.setAttributes(SFTPFileAttributes(size: 10)) }
        let truncated = try await client.stat(path("a")).size
        XCTAssertEqual(truncated, 10)
    }

    func testOpenFlags() async throws {
        put("e", Data("original".utf8))
        await XCTAssertSFTPStatus(.failure) {
            _ = try await self.client.openFile(self.path("e"), flags: [.write, .create, .exclusive])
        }
        try await client.withFile(path("e"), flags: [.write, .append]) { try await $0.write(ByteBuffer(string: "+"), at: 0) }
        XCTAssertEqual(FileManager.default.contents(atPath: path("e")), Data("original+".utf8))
        try await client.withFile(path("e"), flags: [.write]) { try await $0.write(ByteBuffer(string: "O"), at: 0) }
        XCTAssertEqual(FileManager.default.contents(atPath: path("e")), Data("Original+".utf8))
        try await client.withFile(path("new"), flags: [.write, .create, .exclusive]) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("new")))
    }

    // MARK: - 目录与路径

    func testDirectoryListingMatchesDisk() async throws {
        try FileManager.default.createDirectory(atPath: path("d"), withIntermediateDirectories: false)
        var expected: Set<String> = []
        for index in 0..<300 {
            let name = "file-\(index)-文件"
            FileManager.default.createFile(atPath: path("d/\(name)"), contents: Data(count: index))
            expected.insert(name)
        }
        let entries = try await client.listDirectory(path("d"))
        XCTAssertEqual(Set(entries.map(\.filename)), expected)
        for entry in entries {
            let index = Int(entry.filename.split(separator: "-")[1])!
            XCTAssertEqual(entry.attributes.size, UInt64(index))
            XCTAssertTrue(entry.attributes.isRegularFile)
            XCTAssertTrue(entry.longname.contains(entry.filename), entry.longname)
        }
        let withDots = try await client.listDirectory(path("d"), includingDotEntries: true)
        XCTAssertEqual(withDots.count, 302)

        try await client.createDirectory(path("d/sub"), attributes: SFTPFileAttributes(permissions: 0o700))
        let sub = try await client.stat(path("d/sub"))
        XCTAssertTrue(sub.isDirectory)
        XCTAssertEqual(sub.permissionBits, 0o700)
        await XCTAssertSFTPStatus(.failure) { try await self.client.createDirectory(self.path("d/sub")) }
        await XCTAssertSFTPStatus(.failure) { try await self.client.removeDirectory(self.path("d")) }
        try await client.removeDirectory(path("d/sub"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("d/sub")))
        await XCTAssertSFTPStatus(.noSuchFile) { _ = try await self.client.listDirectory(self.path("nope")) }
    }

    func testRealPath() async throws {
        try FileManager.default.createDirectory(atPath: path("x"), withIntermediateDirectories: false)
        let home = try await client.realPath(".")
        XCTAssertEqual(home, root)
        let normalized = try await client.realPath(path("x/../x/./"))
        XCTAssertEqual(normalized, path("x"))
        let relative = try await client.realPath("x")
        XCTAssertEqual(relative, path("x"))
    }

    func testRenameSemantics() async throws {
        put("a", Data("A".utf8))
        put("b", Data("B".utf8))
        // OpenSSH 的 SSH_FXP_RENAME 不覆盖已存在的目标。
        await XCTAssertSFTPStatus(.failure) { try await self.client.rename(self.path("a"), to: self.path("b")) }
        XCTAssertEqual(FileManager.default.contents(atPath: path("b")), Data("B".utf8))
        // posix-rename 覆盖。
        try await client.rename(path("a"), to: path("b"), mode: .posixIfSupported)
        XCTAssertEqual(FileManager.default.contents(atPath: path("b")), Data("A".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("a")))
        try await client.rename(path("b"), to: path("c"))
        XCTAssertEqual(FileManager.default.contents(atPath: path("c")), Data("A".utf8))
        await XCTAssertSFTPStatus(.noSuchFile) { try await self.client.rename(self.path("zz"), to: self.path("yy"), mode: .posix) }
    }

    func testRemove() async throws {
        put("r", Data("1".utf8))
        try await client.remove(path("r"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("r")))
        await XCTAssertSFTPStatus(.noSuchFile) { try await self.client.remove(self.path("r")) }
        try FileManager.default.createDirectory(atPath: path("dir"), withIntermediateDirectories: false)
        do {
            try await client.remove(path("dir"))
            XCTFail("removing a directory with REMOVE must fail")
        } catch let error as SFTPError {
            XCTAssertNotNil(error.statusCode)
            XCTAssertNotEqual(error.statusCode, .ok)
        }
    }

    func testLinks() async throws {
        put("target", Data("T".utf8))
        // OpenSSH 的参数顺序反了；这里核对链接真的建在 link 上、指向 target。
        try await client.createSymlink(at: path("link"), pointingTo: path("target"))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: path("link")), path("target"))
        let target = try await client.readLink(path("link"))
        XCTAssertEqual(target, path("target"))
        let linkAttributes = try await client.lstat(path("link"))
        XCTAssertTrue(linkAttributes.isSymbolicLink)
        let followed = try await client.stat(path("link"))
        XCTAssertTrue(followed.isRegularFile)
        await XCTAssertSFTPStatus(.noSuchFile) { _ = try await self.client.readLink(self.path("absent")) }

        try await client.createHardLink(at: path("hard"), pointingTo: path("target"))
        let original = try FileManager.default.attributesOfItem(atPath: path("target"))
        let hard = try FileManager.default.attributesOfItem(atPath: path("hard"))
        XCTAssertEqual(original[.systemFileNumber] as? Int, hard[.systemFileNumber] as? Int)
        XCTAssertEqual(original[.referenceCount] as? Int, 2)

        // lsetstat 改链接本身的时间，不碰目标。
        let times = SFTPFileTimes(accessSeconds: 1_000_000_000, modificationSeconds: 1_100_000_000)
        try await client.setAttributes(SFTPFileAttributes(times: times), at: path("link"), followingSymlinks: false)
        let afterLink = try await client.lstat(path("link"))
        XCTAssertEqual(afterLink.times?.modificationSeconds, times.modificationSeconds)
        let afterTarget = try await client.stat(path("target"))
        XCTAssertNotEqual(afterTarget.times?.modificationSeconds, times.modificationSeconds)
    }

    func testStatVFS() async throws {
        let stats = try await client.statVFS(root)
        XCTAssertGreaterThan(stats.blockSize, 0)
        XCTAssertGreaterThan(stats.totalBlocks, 0)
        XCTAssertGreaterThan(stats.maximumNameLength, 0)
        let local = try FileManager.default.attributesOfFileSystem(forPath: root)
        if let total = local[.systemSize] as? UInt64 {
            // 两种算法（f_frsize × f_blocks 与 FileManager）应该在同一个数量级上。
            XCTAssertEqual(Double(stats.totalBytes) / Double(total), 1, accuracy: 0.1)
        }
        put("f", Data("1".utf8))
        let fileStats = try await client.withFile(path("f"), flags: .read) { try await $0.statVFS() }
        XCTAssertEqual(fileStats.blockSize, stats.blockSize)
        await XCTAssertSFTPStatus(.noSuchFile) { _ = try await self.client.statVFS(self.path("missing")) }
    }

    // MARK: - 错误码

    func testErrorCodesFromTheRealServer() async throws {
        await XCTAssertSFTPStatus(.noSuchFile) { _ = try await self.client.stat(self.path("missing")) }
        await XCTAssertSFTPStatus(.noSuchFile) { _ = try await self.client.lstat(self.path("missing/deeper")) }
        await XCTAssertSFTPStatus(.noSuchFile) { _ = try await self.client.openFile(self.path("missing"), flags: .read) }
        do {
            _ = try await client.stat(path("missing"))
        } catch let SFTPError.status(_, message, _) {
            XCTAssertFalse(message.isEmpty, "OpenSSH sends a message")
        }

        guard getuid() != 0 else { throw XCTSkip("root ignores permission bits") }
        put("locked", Data("secret".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path("locked"))
        await XCTAssertSFTPStatus(.permissionDenied) { _ = try await self.client.openFile(self.path("locked"), flags: .read) }
        try FileManager.default.createDirectory(atPath: path("closed"), withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path("closed"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path("closed")) }
        await XCTAssertSFTPStatus(.permissionDenied) { _ = try await self.client.listDirectory(self.path("closed")) }
        await XCTAssertSFTPStatus(.permissionDenied) {
            _ = try await self.client.openFile(self.path("closed/new"), flags: [.write, .create])
        }
    }

    // MARK: - 大文件与并发

    func testLargeFileIntegrity() async throws {
        let size = 64 * 1024 * 1024 + 4321
        let payload = SFTPTestData.bytes(count: size, seed: 42)
        let expected = SFTPTestData.sha256(payload)
        try await client.withFile(path("large"), flags: [.write, .create, .truncate]) { file in
            try await file.write(contentsOf: payload, window: 32)
        }
        XCTAssertEqual(try SFTPTestData.sha256(fileAt: path("large")), expected)
        let back = try await client.withFile(path("large"), flags: .read) { try await $0.readAll(window: 32) }
        XCTAssertEqual(back.readableBytes, size)
        XCTAssertEqual(SFTPTestData.sha256(back), expected)
    }

    /// 上层自己的窗口化传输就是这样用的：一个句柄上同时压很多个单请求的 READ。
    func testManyConcurrentSingleReadsOnOneHandle() async throws {
        let chunk = 32_000
        let count = 160
        let payload = SFTPTestData.bytes(count: chunk * count)
        put("c", Data(payload.readableBytesView))
        let file = try await client.openFile(path("c"), flags: .read)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    let data = try await file.read(from: UInt64(index * chunk), length: chunk)
                    XCTAssertEqual(data, payload.getSlice(at: index * chunk, length: chunk), "chunk \(index)")
                }
            }
            try await group.waitForAll()
        }
        try await file.close()
    }

    /// OpenSSH 把释放的句柄编号马上分给下一个 OPEN。CLOSE 之后还发到旧句柄上的 WRITE 会写进新文件、并且回成功。
    /// 客户端必须等在途的请求结束才发 CLOSE，之后再也不往这个句柄上发请求。
    func testStaleRequestsNeverReachAReusedHandle() async throws {
        let payload = SFTPTestData.bytes(count: 4 * 1024 * 1024)
        var sawReuse = false
        for trial in 0..<12 {
            let a = try await client.openFile(path("a\(trial)"), flags: [.write, .create, .truncate])
            let writer = Task { try await a.write(contentsOf: payload, window: 16) }
            let readers = (0..<4).map { _ in
                Task { () -> Int in
                    var count = 0
                    while true {
                        do { _ = try await a.stat() } catch SFTPError.handleClosed { return count }
                        count += 1
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(trial % 4))
            try await a.close()
            let b = try await client.openFile(path("b\(trial)"), flags: [.write, .create, .truncate])
            if b.handle == a.handle { sawReuse = true }
            do {
                try await writer.value
            } catch let error as SFTPError {
                XCTAssertEqual(error, .handleClosed)
            }
            for reader in readers { _ = try await reader.value }
            await XCTAssertSFTPError(.handleClosed) { _ = try await a.read(from: 0, length: 10) }
            try await b.close()
            let size = try FileManager.default.attributesOfItem(atPath: path("b\(trial)"))[.size] as? Int
            XCTAssertEqual(size, 0, "a request on the closed handle landed in the file that reused it (trial \(trial))")
        }
        XCTAssertTrue(sawReuse, "sftp-server reuses handle slots, which is what makes this dangerous")
    }

    /// 长度为 0（或负数）的读：OpenSSH 对 0 字节的 READ 回 EOF，那会被当成文件到头。客户端直接回空、不发请求。
    func testZeroLengthReadIsNotEOF() async throws {
        put("z", Data("abc".utf8))
        let file = try await client.openFile(path("z"), flags: .read)
        let empty = try await file.read(from: 0, length: 0)
        XCTAssertEqual(empty, ByteBuffer())
        let negative = try await file.read(from: 1, length: -5)
        XCTAssertEqual(negative, ByteBuffer())
        let data = try await file.read(from: 0, length: 10)
        XCTAssertEqual(data.map { String(buffer: $0) }, "abc")
        try await file.close()
    }

    /// 4 GiB 以上的 offset（稀疏文件）：写、读、stat、readAll 都对，加法不会溢出。
    func testOffsetsBeyondFourGiB() async throws {
        let far: UInt64 = (1 << 32) + 12_345
        let file = try await client.openFile(path("sparse"), flags: [.read, .write, .create, .truncate])
        try await file.write(ByteBuffer(string: "tail"), at: far)
        let size = try await file.stat().size
        XCTAssertEqual(size, far + 4)
        let back = try await file.read(from: far, length: 100)
        XCTAssertEqual(back.map { String(buffer: $0) }, "tail")
        let all = try await file.readAll(from: far - 6)
        XCTAssertEqual(Array(all.readableBytesView), [0, 0, 0, 0, 0, 0] + Array("tail".utf8))
        try await file.write(contentsOf: SFTPTestData.bytes(count: 100_000), at: far + 4)
        let grown = try await file.stat().size
        XCTAssertEqual(grown, far + 4 + 100_000)
        // 越过 UInt64 上限的区间：本地就抛错，不 trap。
        await XCTAssertSFTPError(.offsetOutOfRange) {
            try await file.write(contentsOf: SFTPTestData.bytes(count: 10), at: .max - 5)
        }
        await XCTAssertSFTPError(.offsetOutOfRange) {
            _ = try await file.readAll(from: .max - 5)
        }
        try await file.close()
    }

    func testServerExitFailsPendingRequests() async throws {
        process?.terminate()
        let exited = await exit.wait(timeout: .seconds(10))
        XCTAssertTrue(exited)
        await XCTAssertSFTPError(.connectionClosed) { _ = try await self.client.stat(self.root) }
    }
}
