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

    private func startServer(extensions: [String: String] = SFTPServer.defaultExtensions,
                             faults: SFTPFaultInjector = SFTPFaultInjector()) async throws -> SSHTestServer {
        let fileSystem = self.fileSystem!
        return try await TestSSH.startServer { configuration in
            configuration.serveSFTP(fileSystem: fileSystem,
                                    configuration: SFTPServer.Configuration(extensions: extensions),
                                    faults: faults)
        }
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
        XCTAssertEqual(remoteTemporaryFiles(), [], "临时文件改名进位后不留")
        await session.close()
    }

    /// 服务端的 sftp-server 退出、SSH 连接还在（测试服务端只关掉 SFTP 子通道）：`isConnected` 变成 false（以前只看 SSH
    /// 连接，调用方以为会话还活着、永远不重开），`disconnectReason` 说是 SFTP 通道关了；本端 `close()` 之后为 nil。
    func testSFTPChannelClosingAloneMakesTheSessionDisconnected() async throws {
        let faults = SFTPFaultInjector()
        faults.dropConnection(on: .stat)
        let server = try await startServer(faults: faults)
        defer { Task { await server.stop() } }
        let session = try await open(server)
        XCTAssertTrue(session.isConnected)
        XCTAssertNil(session.disconnectReason)

        do {
            _ = try await session.stat("/anything")
            XCTFail("the dropped request succeeded")
        } catch {}
        let deadline = ContinuousClock.now + .seconds(5)
        while session.isConnected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(session.isConnected)
        guard case .transportError(let error) = session.disconnectReason, error as? SFTPError == .connectionClosed else {
            return XCTFail("\(String(describing: session.disconnectReason))")
        }
        XCTAssertTrue(session.disconnectReason?.userDescription.contains("SFTP") == true,
                      session.disconnectReason?.userDescription ?? "")

        await session.close()
        XCTAssertNil(session.disconnectReason)
        XCTAssertFalse(session.isConnected)
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

    // MARK: - 原子上传保留目标的权限

    private func mode(of path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileSystem.hostPath(for: path))
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func uploadOverExisting(mode: Int, faults: SFTPFaultInjector = SFTPFaultInjector()) async throws -> Int {
        let server = try await startServer(faults: faults)
        defer { Task { await server.stop() } }
        let host = fileSystem.hostPath(for: "/db.sqlite")
        try Data("old".utf8).write(to: URL(fileURLWithPath: host))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: host)
        let session = try await open(server)
        let local = localDirectory.appendingPathComponent("db-\(mode).sqlite")
        try Data("new contents".utf8).write(to: local)
        try await session.uploadAtomically(local, to: "/db.sqlite")
        await session.close()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: host)), Data("new contents".utf8))
        XCTAssertEqual(remoteTemporaryFiles(), [])
        return try self.mode(of: "/db.sqlite")
    }

    /// 改名换上去的是新文件：0600 / 0660 / 0644 的目标换完权限不变（以前一律变成服务端默认）。
    func testAtomicUploadKeepsTheDestinationPermissions() async throws {
        for wanted in [0o600, 0o660, 0o644, 0o640] {
            let got = try await uploadOverExisting(mode: wanted)
            XCTAssertEqual(got, wanted, String(format: "目标原来是 %o", wanted))
        }
    }

    /// 目标不在：照服务端默认（测试服务端是 0666 & umask），不额外设权限。
    func testAtomicUploadWithoutDestinationUsesServerDefault() async throws {
        let faults = SFTPFaultInjector()
        let server = try await startServer(faults: faults)
        defer { Task { await server.stop() } }
        let session = try await open(server)
        let local = localDirectory.appendingPathComponent("fresh.bin")
        try Data("x".utf8).write(to: local)
        try await session.uploadAtomically(local, to: "/fresh.bin")
        await session.close()
        let umaskValue = umask(0); umask(umaskValue)
        XCTAssertEqual(try mode(of: "/fresh.bin"), 0o666 & ~Int(umaskValue))
        XCTAssertEqual(faults.requestCount(of: .fsetstat), 0, "没有目标就不发 FSETSTAT")
    }

    /// stat 带回权限；目标已经没了（上一次替换做到一半）时，`fallbackAttributes` 让新文件接上原来的权限。
    func testFallbackAttributesApplyOnlyWhenTheDestinationIsGone() async throws {
        let server = try await startServer()
        defer { Task { await server.stop() } }
        let host = fileSystem.hostPath(for: "/db.sqlite")
        try Data("old".utf8).write(to: URL(fileURLWithPath: host))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: host)
        let session = try await open(server)
        let remembered = try await session.stat("/db.sqlite")
        XCTAssertEqual(remembered.permissions, 0o640)
        XCTAssertNotNil(remembered.ownerID)

        try FileManager.default.removeItem(atPath: host)
        let local = localDirectory.appendingPathComponent("again.sqlite")
        try Data("new".utf8).write(to: local)
        try await session.uploadAtomically(local, to: "/db.sqlite", fallbackAttributes: remembered)
        XCTAssertEqual(try mode(of: "/db.sqlite"), 0o640, "目标没了也要接上原来的权限")

        // 目标在的时候跟目标走，不用 fallback。
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: host)
        try await session.uploadAtomically(local, to: "/db.sqlite", fallbackAttributes: remembered)
        XCTAssertEqual(try mode(of: "/db.sqlite"), 0o600)
        await session.close()
    }

    /// 目标是符号链接（哪怕悬空）时什么都不继承：调用方给的 fallbackAttributes 也不用——那多半是之前 stat
    /// 跟着链接读到的、链接指向的文件的属性。
    func testFallbackAttributesAreIgnoredWhenTheDestinationIsASymlink() async throws {
        let server = try await startServer()
        defer { Task { await server.stop() } }
        let link = fileSystem.hostPath(for: "/linked.sqlite")
        try? FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/nonexistent/target")
        let session = try await open(server)
        let remembered = SSHRemoteFileInfo(size: 3, modificationDate: nil, permissions: 0o640)
        let local = localDirectory.appendingPathComponent("linked.sqlite")
        try Data("new".utf8).write(to: local)
        try await session.uploadAtomically(local, to: "/linked.sqlite", fallbackAttributes: remembered)
        let umaskValue = umask(0); umask(umaskValue)
        XCTAssertEqual(try mode(of: "/linked.sqlite"), 0o666 & ~Int(umaskValue), "符号链接目标不该套用 fallback 的权限")
        await session.close()
    }

    /// 服务端拒绝改权限：上传照样成功（数据比权限要紧），权限是服务端给的默认值。
    func testAtomicUploadSucceedsWhenSetstatIsRefused() async throws {
        let faults = SFTPFaultInjector()
        faults.fail(.fsetstat, times: nil, with: .permissionDenied)
        let got = try await uploadOverExisting(mode: 0o600, faults: faults)
        let umaskValue = umask(0); umask(umaskValue)
        XCTAssertEqual(got, 0o666 & ~Int(umaskValue))
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

    /// 服务端每次 READ 只给 1000 字节：短读由 `readAll(expectedLength:)` 在同一段里补齐，内容逐字节一致。
    /// （乱序回答由 USSHCore 自己的 readAll 测试覆盖：注入器的乱序要请求数凑满一批，文件尾凑不满会扣住回答。）
    func testDownloadSurvivesShortReads() async throws {
        let faults = SFTPFaultInjector()
        faults.limitReadLength(to: 1000)
        let server = try await startServer(faults: faults)
        defer { Task { await server.stop() } }
        let content = pattern(200 * 1024 + 3)
        try content.write(to: URL(fileURLWithPath: fileSystem.hostPath(for: "/short.bin")))
        let session = try await open(server)

        let local = localDirectory.appendingPathComponent("short.bin")
        try await session.download("/short.bin", to: local)
        XCTAssertEqual(try Data(contentsOf: local), content)
        await session.close()
    }

    /// 上传按服务端宣告的单次 WRITE 上限切块（这里 8 KiB，比迁移前写死的 32 KiB 小：写死的话第一块就 requestTooLarge）。
    func testUploadChunksFollowTheServerWriteLimit() async throws {
        let limits = SFTPServerLimits(maximumPacketLength: 32 * 1024, maximumReadLength: 8 * 1024,
                                      maximumWriteLength: 8 * 1024, maximumOpenHandles: 0)
        let fileSystem = self.fileSystem!
        let server = try await TestSSH.startServer { configuration in
            configuration.serveSFTP(fileSystem: fileSystem, configuration: SFTPServer.Configuration(limits: limits))
        }
        defer { Task { await server.stop() } }
        let session = try await open(server)

        let content = pattern(100 * 1024 + 1)
        let local = localDirectory.appendingPathComponent("limited.bin")
        try content.write(to: local)
        try await session.uploadAtomically(local, to: "/limited.bin")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fileSystem.hostPath(for: "/limited.bin"))), content)

        let back = localDirectory.appendingPathComponent("limited-back.bin")
        try await session.download("/limited.bin", to: back)
        XCTAssertEqual(try Data(contentsOf: back), content)
        await session.close()
    }

    /// 服务端宣告「不限」（`limits@openssh.com` 报到 2^64，收帧上限也开大）：上传照样按 256 KiB 一块从本地读、
    /// 一块一个 WRITE，不会一次把整个文件读进内存。1 MiB + 1 字节正好 5 个 WRITE。
    func testUploadChunksAreCappedWhenTheServerAdvertisesHugeLimits() async throws {
        let huge = SFTPServerLimits(maximumPacketLength: .max, maximumReadLength: .max,
                                    maximumWriteLength: .max, maximumOpenHandles: 0)
        let fileSystem = self.fileSystem!
        let faults = SFTPFaultInjector()
        let server = try await TestSSH.startServer { configuration in
            configuration.serveSFTP(fileSystem: fileSystem,
                                    configuration: SFTPServer.Configuration(limits: huge, maximumPacketLength: 64 << 20),
                                    faults: faults)
        }
        defer { Task { await server.stop() } }
        let session = try await open(server)

        let content = pattern((1 << 20) + 1)
        let local = localDirectory.appendingPathComponent("huge-limits.bin")
        try content.write(to: local)
        try await session.uploadAtomically(local, to: "/huge-limits.bin")
        XCTAssertEqual(faults.requestCount(of: .write), 5)
        XCTAssertEqual(SSHFileTransferSession.uploadChunkBytes, SFTPClient.maximumTransferLength)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fileSystem.hostPath(for: "/huge-limits.bin"))), content)

        let back = localDirectory.appendingPathComponent("huge-limits-back.bin")
        try await session.download("/huge-limits.bin", to: back)
        XCTAssertEqual(try Data(contentsOf: back), content)
        // READ 也一样封顶：每个最多 256 KiB。
        XCTAssertGreaterThanOrEqual(faults.requestCount(of: .read), 4)
        await session.close()
    }

    // MARK: - 失败时不丢数据

    private func remoteTemporaryFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: fileSystem.hostPath(for: "/"))) ?? []
        return names.filter { $0.contains(".utable-upload-") }.sorted()
    }

    private func localTemporaryFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: localDirectory.path)) ?? []
        return names.filter { $0.contains(".usshkit-download-") }
    }

    private func remote(_ path: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: fileSystem.hostPath(for: path)))
    }

    private func withoutPosixRename() -> [String: String] {
        var extensions = SFTPServer.defaultExtensions
        extensions[SFTPExtensionName.posixRename] = nil
        return extensions
    }

    func testTemporaryNamesAreRandom() {
        let a = SSHFileTransferSession.temporaryPath(for: "/srv/x")
        let b = SSHFileTransferSession.temporaryPath(for: "/srv/x")
        XCTAssertNotEqual(a, b)
        XCTAssertNotNil(a.range(of: #"^/srv/x\.utable-upload-[0-9a-f]{16}\.tmp$"#, options: .regularExpression), a)
    }

    /// 没有 posix-rename、第一次改名因为权限之类（不是「目标已存在」）失败：不删目标，临时文件清掉，原样报错。
    func testRenameFailureOtherThanTargetExistsKeepsTheDestination() async throws {
        let faults = SFTPFaultInjector()
        let server = try await startServer(extensions: withoutPosixRename(), faults: faults)
        defer { Task { await server.stop() } }
        try Data("old".utf8).write(to: URL(fileURLWithPath: fileSystem.hostPath(for: "/keep.txt")))
        let session = try await open(server)
        let local = localDirectory.appendingPathComponent("new.txt")
        try Data("new".utf8).write(to: local)
        faults.fail(.rename, with: .permissionDenied)
        do {
            try await session.uploadAtomically(local, to: "/keep.txt")
            XCTFail("应当失败")
        } catch let error as SFTPError {
            XCTAssertEqual(error.statusCode, .permissionDenied)
        }
        XCTAssertEqual(remote("/keep.txt"), Data("old".utf8))
        XCTAssertEqual(remoteTemporaryFiles(), [])
        await session.close()
    }

    /// 没有 posix-rename、旧文件已经删掉、最后的改名失败：临时文件留着，错误里说出它在哪。
    func testFinalRenameFailureKeepsTheTemporaryFileAndSaysWhere() async throws {
        let faults = SFTPFaultInjector()
        let server = try await startServer(extensions: withoutPosixRename(), faults: faults)
        defer { Task { await server.stop() } }
        try Data("old".utf8).write(to: URL(fileURLWithPath: fileSystem.hostPath(for: "/replace.txt")))
        let session = try await open(server)
        let local = localDirectory.appendingPathComponent("new.txt")
        try Data("precious".utf8).write(to: local)
        faults.fail(.rename, occurrence: 2, with: .failure)     // 第一次是真的「已存在」，第二次注入失败
        do {
            try await session.uploadAtomically(local, to: "/replace.txt")
            XCTFail("应当失败")
        } catch SSHFileTransferError.uploadNotMovedIntoPlace(let temporaryPath, let destination, _) {
            XCTAssertEqual(destination, "/replace.txt")
            XCTAssertEqual(remote(temporaryPath), Data("precious".utf8), "新内容只在临时文件里，不能删")
        }
        XCTAssertNil(remote("/replace.txt"))
        XCTAssertEqual(remoteTemporaryFiles().count, 1)
        await session.close()
    }

    func testFailedUploadRemovesTheTemporaryFileAndKeepsTheDestination() async throws {
        let faults = SFTPFaultInjector()
        let server = try await startServer(faults: faults)
        defer { Task { await server.stop() } }
        try Data("old".utf8).write(to: URL(fileURLWithPath: fileSystem.hostPath(for: "/intact.bin")))
        let session = try await open(server)
        let local = localDirectory.appendingPathComponent("big.bin")
        try pattern(700 * 1024).write(to: local)
        faults.fail(.write, occurrence: 2, with: .noSpaceOnFilesystem)
        do {
            try await session.uploadAtomically(local, to: "/intact.bin")
            XCTFail("应当失败")
        } catch let error as SFTPError {
            XCTAssertEqual(error.statusCode, .noSpaceOnFilesystem)
        }
        XCTAssertEqual(remote("/intact.bin"), Data("old".utf8))
        XCTAssertEqual(remoteTemporaryFiles(), [])
        await session.close()
    }

    /// 上传途中被取消：临时文件照样清掉（收尾不受取消影响）。
    func testCancelledUploadRemovesTheTemporaryFile() async throws {
        let faults = SFTPFaultInjector()
        let server = try await startServer(faults: faults)
        defer { Task { await server.stop() } }
        let session = try await open(server)
        let local = localDirectory.appendingPathComponent("slow.bin")
        try pattern(600 * 1024).write(to: local)
        faults.delayResponses(of: .write, by: .milliseconds(500))
        let upload = Task { try await session.uploadAtomically(local, to: "/slow.bin") }
        while faults.requestCount(of: .write) == 0 { try await Task.sleep(for: .milliseconds(5)) }
        upload.cancel()
        do {
            try await upload.value
            XCTFail("应当被取消")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(remoteTemporaryFiles(), [])
        XCTAssertNil(remote("/slow.bin"))
        await session.close()
    }

    /// 下载：远程文件打不开、读到一半失败、被取消，本地原来的文件都原封不动，不留临时文件；成功时原子替换。
    func testDownloadNeverLosesTheExistingLocalFile() async throws {
        let faults = SFTPFaultInjector()
        let server = try await startServer(faults: faults)
        defer { Task { await server.stop() } }
        try pattern(900 * 1024).write(to: URL(fileURLWithPath: fileSystem.hostPath(for: "/remote.bin")))
        let session = try await open(server)
        let local = localDirectory.appendingPathComponent("local.bin")
        let original = Data("keep me".utf8)
        try original.write(to: local)

        faults.fail(.open, with: .permissionDenied)
        do { try await session.download("/remote.bin", to: local); XCTFail("打开应失败") } catch {}
        XCTAssertEqual(try Data(contentsOf: local), original)

        faults.fail(.read, occurrence: 3, with: .failure)
        do { try await session.download("/remote.bin", to: local); XCTFail("读应失败") } catch {}
        XCTAssertEqual(try Data(contentsOf: local), original)

        faults.delayResponses(of: .read, by: .milliseconds(300))
        let download = Task { try await session.download("/remote.bin", to: local) }
        let reads = faults.requestCount(of: .read)
        while faults.requestCount(of: .read) == reads { try await Task.sleep(for: .milliseconds(5)) }
        download.cancel()
        do { _ = try await download.value; XCTFail("应被取消") } catch {}
        XCTAssertEqual(try Data(contentsOf: local), original)
        XCTAssertEqual(localTemporaryFiles(), [])

        faults.reset()
        try await session.download("/remote.bin", to: local)
        XCTAssertEqual(try Data(contentsOf: local), pattern(900 * 1024))
        XCTAssertEqual(localTemporaryFiles(), [])
        await session.close()
    }

    // MARK: - 没有 posix-rename 时删除目标之后的各种结局（第三轮审查）

    private func uploadWithoutPosixRename(_ faults: SFTPFaultInjector, existing: String = "old",
                                          file name: String = "/target.txt") async throws -> (SSHTestServer, SSHFileTransferSession, URL) {
        let server = try await startServer(extensions: withoutPosixRename(), faults: faults)
        try Data(existing.utf8).write(to: URL(fileURLWithPath: fileSystem.hostPath(for: name)))
        let session = try await open(server)
        let local = localDirectory.appendingPathComponent("payload.txt")
        try Data("precious".utf8).write(to: local)
        return (server, session, local)
    }

    /// 删除目标的请求已经发出、还没回答时被取消：目标可能已删，临时文件留着，报「结果无法确定」并给出位置。
    func testCancelWhileRemoveIsInFlightKeepsTheTemporaryFile() async throws {
        let faults = SFTPFaultInjector()
        let (server, session, local) = try await uploadWithoutPosixRename(faults)
        defer { Task { await server.stop() } }
        faults.delayResponses(of: .remove, by: .milliseconds(800))
        let upload = Task { try await session.uploadAtomically(local, to: "/target.txt") }
        while faults.requestCount(of: .remove) == 0 { try await Task.sleep(for: .milliseconds(5)) }
        upload.cancel()
        do {
            try await upload.value
            XCTFail("应当失败")
        } catch SSHFileTransferError.uploadOutcomeUnknown(let temporaryPath, let destination, _) {
            XCTAssertEqual(destination, "/target.txt")
            XCTAssertEqual(remote(temporaryPath), Data("precious".utf8))
        }
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertEqual(remoteTemporaryFiles().count, 1, "新内容必须还在")
        XCTAssertEqual(faults.requestCount(of: .remove), 1, "没有去删临时文件")
        await session.close()
    }

    /// 删除目标时连接断了：同样留着临时文件。
    func testDroppedConnectionDuringRemoveKeepsTheTemporaryFile() async throws {
        let faults = SFTPFaultInjector()
        let (server, session, local) = try await uploadWithoutPosixRename(faults)
        defer { Task { await server.stop() } }
        faults.dropConnection(on: .remove)
        do {
            try await session.uploadAtomically(local, to: "/target.txt")
            XCTFail("应当失败")
        } catch SSHFileTransferError.uploadOutcomeUnknown(let temporaryPath, _, _) {
            XCTAssertEqual(remote(temporaryPath), Data("precious".utf8))
        }
        await session.close()
    }

    /// 服务器明确拒绝删除目标：目标完好，临时文件删掉，原样报错。
    func testRefusedRemoveKeepsTheDestinationAndCleansUp() async throws {
        let faults = SFTPFaultInjector()
        let (server, session, local) = try await uploadWithoutPosixRename(faults)
        defer { Task { await server.stop() } }
        faults.fail(.remove, with: .permissionDenied)
        do {
            try await session.uploadAtomically(local, to: "/target.txt")
            XCTFail("应当失败")
        } catch let error as SFTPError {
            XCTAssertEqual(error.statusCode, .permissionDenied)
        }
        XCTAssertEqual(remote("/target.txt"), Data("old".utf8))
        XCTAssertEqual(remoteTemporaryFiles(), [])
        await session.close()
    }

    /// 最后的改名发出去、还没回答时被取消：改名可能已经成了，不能说成「旧文件已删、没替换」。
    func testCancelDuringFinalRenameIsReportedAsUnknown() async throws {
        let faults = SFTPFaultInjector()
        let (server, session, local) = try await uploadWithoutPosixRename(faults)
        defer { Task { await server.stop() } }
        faults.delayResponses(of: .rename, by: .milliseconds(300))
        let upload = Task { try await session.uploadAtomically(local, to: "/target.txt") }
        while faults.requestCount(of: .rename) < 2 { try await Task.sleep(for: .milliseconds(5)) }
        upload.cancel()
        do {
            try await upload.value
            XCTFail("应当失败")
        } catch SSHFileTransferError.uploadOutcomeUnknown {
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(remote("/target.txt"), Data("precious".utf8), "这里改名其实成了")
        await session.close()
    }

    /// 目标是悬空的符号链接：替换的是链接本身（与 posix-rename、与以前的实现一样），有没有 posix-rename 都一样。
    func testDanglingSymlinkDestinationIsReplaced() async throws {
        for extensions in [withoutPosixRename(), SFTPServer.defaultExtensions] {
            let server = try await startServer(extensions: extensions)
            let link = fileSystem.hostPath(for: "/link.txt")
            try? FileManager.default.removeItem(atPath: link)
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/nonexistent/target")
            let session = try await open(server)
            let local = localDirectory.appendingPathComponent("payload.txt")
            try Data("new".utf8).write(to: local)
            try await session.uploadAtomically(local, to: "/link.txt")
            let type = try FileManager.default.attributesOfItem(atPath: link)[.type] as? FileAttributeType
            XCTAssertEqual(type, .typeRegular, "链接本身被换成了普通文件")
            XCTAssertEqual(remote("/link.txt"), Data("new".utf8))
            await session.close()
            await server.stop()
        }
    }

    // MARK: - 连接卡死时取消马上返回

    func testCancelDownloadOnAFrozenLinkReturnsPromptly() async throws {
        let faults = SFTPFaultInjector()
        let server = try await startServer(faults: faults)
        defer { Task { await server.stop() } }
        try pattern(4 << 20).write(to: URL(fileURLWithPath: fileSystem.hostPath(for: "/big.bin")))
        let session = try await open(server)
        let local = localDirectory.appendingPathComponent("frozen.bin")
        try Data("keep".utf8).write(to: local)
        faults.delayResponses(of: .read, by: .milliseconds(200))
        let download = Task { try await session.download("/big.bin", to: local) }
        while faults.requestCount(of: .read) == 0 { try await Task.sleep(for: .milliseconds(5)) }
        await server.freezeAllConnections()
        let start = ContinuousClock.now
        download.cancel()
        _ = try? await download.value
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2), "取消要马上返回")
        XCTAssertEqual(try Data(contentsOf: local), Data("keep".utf8))
        XCTAssertEqual(localTemporaryFiles(), [])
    }

    func testCancelUploadOnAFrozenLinkReturnsWithinTheCleanupDeadline() async throws {
        let faults = SFTPFaultInjector()
        let server = try await startServer(faults: faults)
        defer { Task { await server.stop() } }
        let session = try await open(server)
        let local = localDirectory.appendingPathComponent("frozen-up.bin")
        try pattern(2 << 20).write(to: local)
        faults.delayResponses(of: .write, by: .milliseconds(200))
        let upload = Task { try await session.uploadAtomically(local, to: "/frozen-up.bin") }
        while faults.requestCount(of: .write) == 0 { try await Task.sleep(for: .milliseconds(5)) }
        await server.freezeAllConnections()
        let start = ContinuousClock.now
        upload.cancel()
        _ = try? await upload.value
        XCTAssertLessThan(ContinuousClock.now - start, SSHFileTransferSession.cleanupDeadline + .seconds(1))
    }

    // MARK: - 长文件名

    /// 255 字节的名字：临时文件名截短原名，在本地和服务器上都合法。
    func testMaximumLengthNamesRoundTrip() async throws {
        let server = try await startServer(extensions: withoutPosixRename())
        defer { Task { await server.stop() } }
        let session = try await open(server)
        let name = String(repeating: "名", count: 85)            // 85 × 3 = 255 字节
        XCTAssertEqual(name.utf8.count, 255)
        let local = localDirectory.appendingPathComponent(name)
        try Data("long name".utf8).write(to: local)
        try await session.uploadAtomically(local, to: "/" + name)
        XCTAssertEqual(remote("/" + name), Data("long name".utf8))
        let back = localDirectory.appendingPathComponent(String(repeating: "长", count: 85))
        try Data("old".utf8).write(to: back)
        try await session.download("/" + name, to: back)
        XCTAssertEqual(try Data(contentsOf: back), Data("long name".utf8))
        XCTAssertEqual(localTemporaryFiles(), [])
        XCTAssertLessThanOrEqual(SSHFileTransferSession.temporaryPath(for: "/d/" + name).split(separator: "/").last!.utf8.count, 255)
        await session.close()
    }
}
