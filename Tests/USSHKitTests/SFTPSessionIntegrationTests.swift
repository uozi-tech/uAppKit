import NIOCore
import USSHTestServer
import XCTest
@testable import USSHKit

/// `SSHFileTransferSession` 对着进程内的 SSH + SFTP 服务端（真实临时目录）。
final class SFTPSessionIntegrationTests: XCTestCase {
    private var fileSystem: SFTPLocalFileSystem!
    private var localDirectory: URL!

    override func setUpWithError() throws {
        fileSystem = try SFTPLocalFileSystem.makeTemporary(prefix: "usshkit-sftp")
        localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usshkit-local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileSystem.removeRoot()
        try? FileManager.default.removeItem(at: localDirectory)
    }

    private func startServer(extensions: [String: String] = SFTPServer.defaultExtensions) async throws -> SSHTestServer {
        let fileSystem = self.fileSystem!
        let configuration = SFTPServer.Configuration(extensions: extensions)
        return try await TestSSH.startServer(subsystems: [
            "sftp": { channel in
                channel.eventLoop.makeCompletedFuture {
                    _ = try SFTPServer.install(on: channel, fileSystem: fileSystem, configuration: configuration)
                }
            },
        ])
    }

    private func open(_ server: SSHTestServer) async throws -> SSHFileTransferSession {
        try await SSHFileTransferSession.open(
            endpoint: TestSSH.endpoint(server), credential: .password(TestSSH.password),
            hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: .insecureAcceptAll, approver: { _ in true })
    }

    private func pattern(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) })
    }

    func testUploadStatAndDownloadRoundTrip() async throws {
        let server = try await startServer()
        defer { Task { await server.stop() } }
        let session = try await open(server)

        let content = pattern(300 * 1024 + 7)
        let local = localDirectory.appendingPathComponent("up.bin")
        try content.write(to: local)
        try await session.uploadAtomically(local, to: "/data.bin")

        let info = try await session.stat("/data.bin")
        XCTAssertEqual(info.size, Int64(content.count))
        XCTAssertNotNil(info.modificationDate)

        let downloaded = localDirectory.appendingPathComponent("down.bin")
        let reported = try await session.download("/data.bin", to: downloaded)
        XCTAssertEqual(reported, info)
        XCTAssertEqual(try Data(contentsOf: downloaded), content)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileSystem.hostPath(for: "/data.bin.utable-upload.tmp")))
        await session.close()
    }

    /// 目标已存在：有 posix-rename 时原子替换。
    func testUploadReplacesExistingFile() async throws {
        let server = try await startServer()
        defer { Task { await server.stop() } }
        try Data("old".utf8).write(to: URL(fileURLWithPath: fileSystem.hostPath(for: "/existing.txt")))
        let session = try await open(server)

        let local = localDirectory.appendingPathComponent("new.txt")
        try Data("new contents".utf8).write(to: local)
        try await session.uploadAtomically(local, to: "/existing.txt")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fileSystem.hostPath(for: "/existing.txt"))),
                       Data("new contents".utf8))
        await session.close()
    }

    /// 服务端没有 posix-rename：v3 的 RENAME 不覆盖，删掉旧文件再改名（迁移前的行为，保留给非 OpenSSH 的服务端）。
    func testUploadReplacesExistingFileWithoutPosixRename() async throws {
        var extensions = SFTPServer.defaultExtensions
        extensions[SFTPExtensionName.posixRename] = nil
        let server = try await startServer(extensions: extensions)
        defer { Task { await server.stop() } }
        try Data("old".utf8).write(to: URL(fileURLWithPath: fileSystem.hostPath(for: "/existing.txt")))
        let session = try await open(server)

        let local = localDirectory.appendingPathComponent("new.txt")
        try Data("replacement".utf8).write(to: local)
        try await session.uploadAtomically(local, to: "/existing.txt")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fileSystem.hostPath(for: "/existing.txt"))),
                       Data("replacement".utf8))
        await session.close()
    }

    func testDownloadSizeCap() async throws {
        let server = try await startServer()
        defer { Task { await server.stop() } }
        try pattern(64 * 1024).write(to: URL(fileURLWithPath: fileSystem.hostPath(for: "/big.bin")))
        let session = try await open(server)

        do {
            try await session.download("/big.bin", to: localDirectory.appendingPathComponent("big.bin"),
                                       maximumBytes: 1024)
            XCTFail("超过上限必须报错")
        } catch SSHFileTransferError.downloadTooLarge(let observed, let maximum) {
            XCTAssertEqual(observed, 64 * 1024)
            XCTAssertEqual(maximum, 1024)
        }
        await session.close()
    }

    /// 服务端的错误是 USSHCore 的 `SFTPError.status`（只有这一种），带本地化文案。
    func testMissingFileIsSFTPStatusError() async throws {
        let server = try await startServer()
        defer { Task { await server.stop() } }
        let session = try await open(server)

        do {
            _ = try await session.stat("/missing")
            XCTFail("不存在的文件")
        } catch let error as SFTPError {
            XCTAssertEqual(error.statusCode, .noSuchFile)
            XCTAssertEqual(error.localizedDescription, String(localized: "文件或路径不存在", bundle: ModuleBundle.bundle))
        }
        await session.close()
    }

    func testMissingLocalFileIsReported() async throws {
        let server = try await startServer()
        defer { Task { await server.stop() } }
        let session = try await open(server)
        let missing = localDirectory.appendingPathComponent("nope")
        do {
            try await session.uploadAtomically(missing, to: "/x")
            XCTFail("本地文件不存在")
        } catch SSHFileTransferError.localFileUnavailable(let path) {
            XCTAssertEqual(path, missing.path)
        }
        await session.close()
    }
}
