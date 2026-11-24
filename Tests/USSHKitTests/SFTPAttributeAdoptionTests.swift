import Foundation
import NIOCore
import USSHTestServer
import XCTest
@testable import USSHKit

/// 原子上传继承目标属性时的顺序与特殊位、符号链接目标，以及服务端回 0 字节 DATA 时的下载。
/// 服务端的文件系统是真实临时目录外面包一层 `InterposingFileSystem`：可以把某个路径报成别人的文件（模拟
/// 「覆盖别人的文件」，换属主于是真的被内核拒绝）、记下对打开的文件做过哪些 setstat、改写 READ 的回答。
final class SFTPAttributeAdoptionTests: XCTestCase {
    private var base: SFTPLocalFileSystem!
    private var hooks: InterposingFileSystem.Hooks!
    private var localDirectory: URL!

    override func setUpWithError() throws {
        base = try SFTPLocalFileSystem.makeTemporary(prefix: "usshkit-adopt")
        hooks = InterposingFileSystem.Hooks()
        localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usshkit-adopt-local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? base.removeRoot()
        try? FileManager.default.removeItem(at: localDirectory)
    }

    private func startServer(faults: SFTPFaultInjector = SFTPFaultInjector()) async throws -> SSHTestServer {
        let fileSystem = InterposingFileSystem(base: base, hooks: hooks)
        return try await TestSSH.startServer { configuration in
            configuration.serveSFTP(fileSystem: fileSystem, faults: faults)
        }
    }

    private func open(_ server: SSHTestServer) async throws -> SSHFileTransferSession {
        try await SSHFileTransferSession.open(
            endpoint: TestSSH.endpoint(server), credential: .password(TestSSH.password),
            hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: .insecureAcceptAll, approver: { _ in true })
    }

    private func host(_ path: String) -> String { base.hostPath(for: path) }

    private func mode(ofHost path: String) throws -> Int {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { throw POSIXError(.ENOENT) }
        return Int(info.st_mode) & 0o7777
    }

    private func owner(ofHost path: String) -> SFTPFileOwner {
        var info = Darwin.stat()
        _ = lstat(path, &info)
        return SFTPFileOwner(userID: info.st_uid, groupID: info.st_gid)
    }

    private func upload(_ contents: String, to remotePath: String, faults: SFTPFaultInjector = SFTPFaultInjector()) async throws {
        let server = try await startServer(faults: faults)
        defer { Task { await server.stop() } }
        let session = try await open(server)
        let local = localDirectory.appendingPathComponent(UUID().uuidString)
        try Data(contents.utf8).write(to: local)
        try await session.uploadAtomically(local, to: remotePath)
        await session.close()
    }

    private var serverDefaultMode: Int {
        let mask = umask(0); umask(mask)
        return 0o666 & ~Int(mask)
    }

    // MARK: - setuid / setgid

    /// 覆盖别人的 06755 文件（属主换不过去，内核拒绝 fchown）：setuid 不带过去，结果绝不是一个属于上传者的
    /// setuid 文件；属组相同，setgid 照留。属主在前、权限在后。
    func testSetuidIsDroppedWhenTheOwnerCannotBeAdopted() async throws {
        let path = host("/tool")
        try Data("old".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(chmod(path, 0o6755), 0)
        try XCTSkipIf(try mode(ofHost: path) != 0o6755, "这个文件系统不让设 setuid / setgid")
        let real = owner(ofHost: path)
        hooks.reportOwner(SFTPFileOwner(userID: real.userID &+ 1, groupID: real.groupID), for: "/tool")

        try await upload("new", to: "/tool")

        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "new")
        XCTAssertEqual(owner(ofHost: path), real, "换属主被拒，文件仍属上传者")
        XCTAssertEqual(try mode(ofHost: path), 0o2755, "setuid 去掉，setgid（属组相同）留着")
        XCTAssertEqual(hooks.setAttributeKinds, ["owner", "permissions"], "先换属主再设权限：chown 会清掉特殊位")
    }

    /// 属主属组都对得上：setuid / setgid 都带过去，不发多余的换属主请求。
    func testSetuidIsKeptWhenTheOwnerMatches() async throws {
        let path = host("/tool")
        try Data("old".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(chmod(path, 0o6755), 0)
        try XCTSkipIf(try mode(ofHost: path) != 0o6755, "这个文件系统不让设 setuid / setgid")

        try await upload("new", to: "/tool")

        XCTAssertEqual(try mode(ofHost: path), 0o6755)
        XCTAssertEqual(hooks.setAttributeKinds, ["permissions"])
    }

    /// 服务端不报属主（只给权限位）：没法确认属主属组，特殊位全部去掉，普通位照搬。
    func testSpecialBitsAreDroppedWhenTheServerReportsNoOwner() async throws {
        let path = host("/tool")
        try Data("old".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(chmod(path, 0o7755), 0)
        try XCTSkipIf(try mode(ofHost: path) & 0o6000 != 0o6000, "这个文件系统不让设 setuid / setgid")
        hooks.hideOwner(for: "/tool")

        try await upload("new", to: "/tool")

        XCTAssertEqual(try mode(ofHost: path), 0o755)
        XCTAssertEqual(hooks.setAttributeKinds, ["permissions"])
    }

    // MARK: - 符号链接目标

    /// 目标是指向别的文件的符号链接（不是悬空的）：替换的是链接本身，新文件不继承链接指向的那个文件的权限与属主
    /// （以前 stat 跟随链接，把 0640 搬到了新文件上），被指向的文件不动。
    func testLiveSymlinkDestinationDoesNotLendItsTargetsAttributes() async throws {
        let target = host("/secret.bin")
        try Data("target".utf8).write(to: URL(fileURLWithPath: target))
        XCTAssertEqual(chmod(target, 0o640), 0)
        try FileManager.default.createSymbolicLink(atPath: host("/link"), withDestinationPath: "secret.bin")
        let faults = SFTPFaultInjector()

        try await upload("new", to: "/link", faults: faults)

        let attributes = try FileManager.default.attributesOfItem(atPath: host("/link"))
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular, "链接被换成了普通文件")
        XCTAssertEqual(try String(contentsOfFile: host("/link"), encoding: .utf8), "new")
        XCTAssertEqual(try mode(ofHost: host("/link")), serverDefaultMode, "不继承链接指向的文件的 0640")
        XCTAssertEqual(faults.requestCount(of: .fsetstat), 0)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "target")
        XCTAssertEqual(try mode(ofHost: target), 0o640)
    }

    // MARK: - 0 字节的 DATA

    /// stat 出来的那部分读完之后，服务端对文件尾的 READ 回 0 字节的 DATA（而不是 EOF）：下载失败，本地原来的
    /// 文件不动。以前这一步被当成 EOF，截断的文件当成功交了出去。
    func testZeroLengthDataAfterTheStatedSizeFailsTheDownload() async throws {
        let content = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try content.write(to: URL(fileURLWithPath: host("/grow.bin")))
        hooks.emptyReads(from: UInt64(content.count))
        let server = try await startServer()
        defer { Task { await server.stop() } }
        let session = try await open(server)
        let local = localDirectory.appendingPathComponent("grow.bin")
        try Data("keep me".utf8).write(to: local)
        do {
            _ = try await session.download("/grow.bin", to: local)
            XCTFail("a zero-length DATA was taken as end of file")
        } catch SFTPError.invalidResponse(let detail) {
            XCTAssertTrue(detail.contains("zero-length"), detail)
        }
        XCTAssertEqual(try Data(contentsOf: local), Data("keep me".utf8))
        await session.close()
    }
}

/// 包一层真实的文件系统，见 `SFTPAttributeAdoptionTests`。
struct InterposingFileSystem: SFTPServerFileSystem {
    final class Hooks: @unchecked Sendable {
        private struct State {
            var reportedOwners: [String: SFTPFileOwner?] = [:]
            var setAttributes: [SFTPFileAttributes] = []
            var emptyReadsFrom: UInt64?
        }
        private let lock = NSLock()
        private var state = State()

        private func withState<T>(_ body: (inout State) -> T) -> T { lock.withLock { body(&state) } }

        /// `path` 的 stat / lstat 把属主报成 `owner`。
        func reportOwner(_ owner: SFTPFileOwner, for path: String) {
            withState { $0.reportedOwners[path] = .some(owner) }
        }

        /// `path` 的 stat / lstat 不带属主。
        func hideOwner(for path: String) {
            withState { $0.reportedOwners[path] = .some(nil) }
        }

        /// 打开的文件在 `offset` 及以后的 READ 回 0 字节的 DATA。
        func emptyReads(from offset: UInt64) {
            withState { $0.emptyReadsFrom = offset }
        }

        /// 对打开的文件做过的 setstat，按顺序：`owner` / `permissions` / `owner+permissions`。
        var setAttributeKinds: [String] {
            withState { state in
                state.setAttributes.map { attributes in
                    [attributes.owner != nil ? "owner" : nil, attributes.permissions != nil ? "permissions" : nil]
                        .compactMap { $0 }.joined(separator: "+")
                }
            }
        }

        func adjust(_ attributes: SFTPFileAttributes, at path: SFTPPath) -> SFTPFileAttributes {
            let key = String(decoding: path.bytes, as: UTF8.self)
            guard let override = withState({ $0.reportedOwners[key] }) else { return attributes }
            var attributes = attributes
            attributes.owner = override
            return attributes
        }

        func record(_ attributes: SFTPFileAttributes) {
            withState { $0.setAttributes.append(attributes) }
        }

        func readsEmpty(at offset: UInt64) -> Bool {
            withState { state in state.emptyReadsFrom.map { offset >= $0 } ?? false }
        }
    }

    struct File: SFTPServerFile {
        let base: any SFTPServerFile
        let hooks: Hooks

        func read(at offset: UInt64, length: Int) async throws -> ByteBuffer? {
            if hooks.readsEmpty(at: offset) { return ByteBuffer() }
            return try await base.read(at: offset, length: length)
        }
        func write(_ data: ByteBuffer, at offset: UInt64) async throws { try await base.write(data, at: offset) }
        func attributes() async throws -> SFTPFileAttributes { try await base.attributes() }
        func setAttributes(_ attributes: SFTPFileAttributes) async throws {
            hooks.record(attributes)
            try await base.setAttributes(attributes)
        }
        func sync() async throws { try await base.sync() }
        func fileSystemStats() async throws -> SFTPFileSystemStats { try await base.fileSystemStats() }
        func close() async throws { try await base.close() }
    }

    let base: SFTPLocalFileSystem
    let hooks: Hooks

    func realPath(_ path: SFTPPath) async throws -> SFTPPath { try await base.realPath(path) }
    func attributes(at path: SFTPPath, followingSymlinks: Bool) async throws -> SFTPFileAttributes {
        hooks.adjust(try await base.attributes(at: path, followingSymlinks: followingSymlinks), at: path)
    }
    func setAttributes(_ attributes: SFTPFileAttributes, at path: SFTPPath, followingSymlinks: Bool) async throws {
        try await base.setAttributes(attributes, at: path, followingSymlinks: followingSymlinks)
    }
    func openFile(_ path: SFTPPath, flags: SFTPOpenFlags, attributes: SFTPFileAttributes) async throws -> any SFTPServerFile {
        File(base: try await base.openFile(path, flags: flags, attributes: attributes), hooks: hooks)
    }
    func openDirectory(_ path: SFTPPath) async throws -> any SFTPServerDirectory { try await base.openDirectory(path) }
    func removeFile(_ path: SFTPPath) async throws { try await base.removeFile(path) }
    func createDirectory(_ path: SFTPPath, attributes: SFTPFileAttributes) async throws {
        try await base.createDirectory(path, attributes: attributes)
    }
    func removeDirectory(_ path: SFTPPath) async throws { try await base.removeDirectory(path) }
    func rename(_ oldPath: SFTPPath, to newPath: SFTPPath, replacingExisting: Bool) async throws {
        try await base.rename(oldPath, to: newPath, replacingExisting: replacingExisting)
    }
    func readLink(_ path: SFTPPath) async throws -> SFTPPath { try await base.readLink(path) }
    func createSymlink(at linkPath: SFTPPath, pointingTo targetPath: SFTPPath) async throws {
        try await base.createSymlink(at: linkPath, pointingTo: targetPath)
    }
    func createHardLink(at newPath: SFTPPath, pointingTo existingPath: SFTPPath) async throws {
        try await base.createHardLink(at: newPath, pointingTo: existingPath)
    }
    func fileSystemStats(at path: SFTPPath) async throws -> SFTPFileSystemStats { try await base.fileSystemStats(at: path) }
}
