import Foundation
import NIOCore
import XCTest
import USSHCore
import USSHTestServer

/// `SFTPLocalFileSystem` 的根目录限制：每一种曾经能跳出根目录的路子。
final class SFTPLocalFileSystemTests: XCTestCase {
    private var fs: SFTPLocalFileSystem!
    private var outside: URL!

    override func setUp() async throws {
        fs = try SFTPLocalFileSystem.makeTemporary()
        outside = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? fs.removeRoot()
        try? FileManager.default.removeItem(at: outside)
    }

    private func link(_ name: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: fs.hostPath(for: name), withDestinationPath: destination)
    }

    private func assertStatus(_ code: SFTPStatusCode, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let error as SFTPServerStatusError {
            XCTAssertEqual(error.code, code, error.message, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    /// 悬空链接指向根目录外面一个还不存在的文件：`open(O_CREAT)` 不能顺着它把文件建到外面。
    func testCreatingThroughADanglingSymlinkIsRefused() async throws {
        let target = outside.appendingPathComponent("created-by-escape").path
        try link("/dangling", to: target)
        await assertStatus(.noSuchFile) {
            _ = try await self.fs.openFile("/dangling", flags: [.write, .create], attributes: .none)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
        // 根目录里的悬空链接同样不跟随。
        try link("/inside-dangling", to: fs.hostPath(for: "/missing"))
        await assertStatus(.noSuchFile) {
            _ = try await self.fs.openFile("/inside-dangling", flags: [.write, .create], attributes: .none)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fs.hostPath(for: "/missing")))
    }

    /// 不跟随链接的 setstat（lsetstat）带 size 会穿过链接截断目标：拒绝。跟随的版本则核对目标在不在根目录里。
    func testNoFollowSizeChangeIsRefused() async throws {
        let victim = outside.appendingPathComponent("victim")
        try Data("keep me".utf8).write(to: victim)
        try link("/to-victim", to: victim.path)
        await assertStatus(.badMessage) {
            try await self.fs.setAttributes(SFTPFileAttributes(size: 0), at: "/to-victim", followingSymlinks: false)
        }
        await assertStatus(.permissionDenied) {
            try await self.fs.setAttributes(SFTPFileAttributes(size: 0), at: "/to-victim", followingSymlinks: true)
        }
        XCTAssertEqual(try Data(contentsOf: victim), Data("keep me".utf8))
        // 改链接本身的时间仍然可以。
        try await fs.setAttributes(SFTPFileAttributes(times: SFTPFileTimes(accessSeconds: 1, modificationSeconds: 1)),
                                   at: "/to-victim", followingSymlinks: false)
    }

    /// 硬链接的源是指向外面的符号链接：不能链到外面那个文件上。
    func testHardLinkDoesNotFollowASymlinkedSource() async throws {
        let victim = outside.appendingPathComponent("victim")
        try Data("secret".utf8).write(to: victim)
        try link("/to-victim", to: victim.path)
        do {
            try await fs.createHardLink(at: "/hard", pointingTo: "/to-victim")
        } catch is SFTPServerStatusError {
            // 拒绝也可以；关键是不能链到外面的文件上。
        }
        let count = try FileManager.default.attributesOfItem(atPath: victim.path)[.referenceCount] as? Int
        XCTAssertEqual(count, 1, "outside file gained a hard link")
        if FileManager.default.fileExists(atPath: fs.hostPath(for: "/hard")) ||
            (try? FileManager.default.destinationOfSymbolicLink(atPath: fs.hostPath(for: "/hard"))) != nil {
            await assertStatus(.permissionDenied) {
                _ = try await self.fs.openFile("/hard", flags: .read, attributes: .none)
            }
        }
    }

    /// 相对目标里的 `..` 走出根目录：拒绝；在根目录里面的照常建。
    func testRelativeSymlinkTargetsCannotLeaveTheRoot() async throws {
        try await fs.createDirectory("/a", attributes: .none)
        await assertStatus(.permissionDenied) {
            try await self.fs.createSymlink(at: "/a/up", pointingTo: "../../etc/passwd")
        }
        await assertStatus(.permissionDenied) {
            try await self.fs.createSymlink(at: "/top", pointingTo: "x/../../y")
        }
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: fs.hostPath(for: "/a/up")))
        try await fs.createSymlink(at: "/a/sibling", pointingTo: "../b")
        let target = try await fs.readLink("/a/sibling")
        XCTAssertEqual(target, "../b")
        // 绝对目标按客户端视角存、按客户端视角读回来。
        try await fs.createSymlink(at: "/abs", pointingTo: "/a")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fs.hostPath(for: "/abs")), fs.hostPath(for: "/a"))
        let absolute = try await fs.readLink("/abs")
        XCTAssertEqual(absolute, "/a")
    }

    /// 中间一段目录是指向外面的链接：在它下面建东西、读东西都拒绝。
    func testSymlinkedParentDirectoryIsRefused() async throws {
        try link("/out", to: outside.path)
        try Data("x".utf8).write(to: outside.appendingPathComponent("existing"))
        await assertStatus(.permissionDenied) {
            _ = try await self.fs.openFile("/out/new", flags: [.write, .create], attributes: .none)
        }
        await assertStatus(.permissionDenied) { _ = try await self.fs.attributes(at: "/out/existing", followingSymlinks: false) }
        await assertStatus(.permissionDenied) { try await self.fs.createDirectory("/out/dir", attributes: .none) }
        await assertStatus(.permissionDenied) { try await self.fs.removeFile("/out/existing") }
        await assertStatus(.permissionDenied) { _ = try await self.fs.openDirectory("/out") }
        await assertStatus(.permissionDenied) { try await self.fs.rename("/out/existing", to: "/stolen", replacingExisting: true) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("existing").path))
        // 不跟随时看得到链接本身。
        let attributes = try await fs.attributes(at: "/out", followingSymlinks: false)
        XCTAssertTrue(attributes.isSymbolicLink)
    }

    /// 根目录里面的链接照常跟随。
    func testSymlinksInsideTheRootStillWork() async throws {
        try Data("ok".utf8).write(to: URL(fileURLWithPath: fs.hostPath(for: "/real")))
        try await fs.createSymlink(at: "/alias", pointingTo: "real")
        let file = try await fs.openFile("/alias", flags: .read, attributes: .none)
        let data = try await file.read(at: 0, length: 10)
        XCTAssertEqual(data.map { String(buffer: $0) }, "ok")
        try await file.close()
        let real = try await fs.realPath("/alias")
        XCTAssertEqual(real, "/real")
    }
}
