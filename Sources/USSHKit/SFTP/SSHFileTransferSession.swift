import Foundation
import NIOCore
import USSHCore

/// Non-secret metadata about a remote file, surfaced as plain `Foundation` values.
public struct SSHRemoteFileInfo: Sendable, Hashable {
    public let size: Int64
    public let modificationDate: Date?

    public init(size: Int64, modificationDate: Date?) {
        self.size = size
        self.modificationDate = modificationDate
    }
}

public enum SSHFileTransferError: Error, LocalizedError, Sendable {
    case downloadTooLarge(observed: Int64, maximum: Int64)
    case localFileUnavailable(String)
    /// 上传已经写进了临时文件 `temporaryPath`，旧的 `destination` 也已经删掉（服务器没有 `posix-rename`，只能先删
    /// 再改名），最后的改名却失败了：新内容只在临时文件里，**没有删它**。`reason` 是改名失败的原因。
    case uploadNotMovedIntoPlace(temporaryPath: String, destination: String, reason: String)
    /// 上传已经写进了临时文件 `temporaryPath`，替换 `destination` 的那一步（没有 `posix-rename` 时的删旧文件或改名）
    /// 发出去之后没有得到确定的回答（被取消、连接断了）：旧文件可能已经删掉、新文件可能已经改名到位，**不知道**。
    /// 临时文件（如果还在）没有删。
    case uploadOutcomeUnknown(temporaryPath: String, destination: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .downloadTooLarge(let observed, let maximum):
            return String(localized: "远程文件过大（\(observed) 字节，超过上限 \(maximum) 字节）", bundle: ModuleBundle.bundle)
        case .localFileUnavailable(let path):
            return String(localized: "无法访问本地文件：\(path)", bundle: ModuleBundle.bundle)
        case .uploadNotMovedIntoPlace(let temporaryPath, let destination, let reason):
            return String(localized: "文件已上传到 \(temporaryPath)，但没能替换 \(destination)（旧文件已删除）：\(reason)", bundle: ModuleBundle.bundle)
        case .uploadOutcomeUnknown(let temporaryPath, let destination, let reason):
            return String(localized: "文件已上传到 \(temporaryPath)，替换 \(destination) 的结果无法确定（旧文件可能已删除，新文件可能已就位）：\(reason)", bundle: ModuleBundle.bundle)
        }
    }
}

/// A stand-alone SFTP file-transfer session over one SSH connection.
///
/// USSHKit owns SSH authentication, host-key validation, and the SFTP subsystem;
/// the application supplies endpoint/credential/host-key policy and works purely
/// in terms of `Foundation` values (`URL`, `Data`, paths).
///
/// The session is an `actor`, so all transfers on a given session are serialized;
/// callers do not need to add their own locking around `download`/`upload`.
public actor SSHFileTransferSession {
    private let connected: ConnectedClient
    private let sftp: SFTPClient

    private init(connected: ConnectedClient, sftp: SFTPClient) {
        self.connected = connected
        self.sftp = sftp
    }

    /// Inbound window of the SFTP channel this session opens. The window, not
    /// the request count, caps a download at window/RTT: 16 MB over a 150 ms
    /// link took 36 s at 128 KiB even with reads pipelined. The connection
    /// exists only for file transfer, so a large window costs nothing else.
    ///
    /// NIOSSH 0.15 sizes every child channel's window as 64 × the maximum
    /// packet size, so the session asks for `channelWindowBytes / 64` as its
    /// packet size. USSHCore clamps that to `SSHClient.maximumPacketSizeRange`
    /// (32 KiB…512 KiB), so the window this can actually get is 2 MiB…32 MiB.
    public static let defaultChannelWindowBytes = 1 << 22

    /// The maximum packet size that gives an inbound window of `windowBytes`.
    static func maximumPacketSize(forWindow windowBytes: Int) -> Int {
        windowBytes / 64
    }

    /// Connect to `endpoint` and open an SFTP subsystem channel.
    ///
    /// `logger` receives the connection-level events (e.g. the warning logged when
    /// the server only supports SHA-1-era algorithms and the automatic fallback
    /// used them).
    ///
    /// On any failure after the SSH transport is established the transport is
    /// closed before the error propagates, so a caller that only receives the
    /// thrown error never leaks a live connection.
    public static func open(
        endpoint: SSHEndpoint,
        credential: SSHCredential,
        hostKeyStore: any HostKeyStore,
        hostKeyPolicy: SSHHostKeyPolicy = .ask,
        connectTimeout: Duration = .seconds(30),
        approvalTimeout: Duration = .seconds(180),
        channelWindowBytes: Int = SSHFileTransferSession.defaultChannelWindowBytes,
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool = { _ in false },
        logger: any SSHLogger = NoOpSSHLogger()
    ) async throws -> SSHFileTransferSession {
        let connected = try await SSHClientFactory.connect(
            endpoint: endpoint,
            credential: credential,
            hostKeyStore: hostKeyStore,
            hostKeyPolicy: hostKeyPolicy,
            connectTimeout: connectTimeout,
            approvalTimeout: approvalTimeout,
            approver: approver,
            maximumPacketSize: maximumPacketSize(forWindow: channelWindowBytes),
            logger: logger
        )
        do {
            let sftp = try await connected.target.openSFTP()
            return SSHFileTransferSession(connected: connected, sftp: sftp)
        } catch {
            await connected.close()
            throw error
        }
    }

    /// `stat(2)` the remote file, returning size and modification date.
    public func stat(_ remotePath: String) async throws -> SSHRemoteFileInfo {
        let attributes = try await sftp.stat(remotePath)
        return SSHRemoteFileInfo(
            size: Self.clampedSize(attributes.size),
            modificationDate: attributes.modificationDate
        )
    }

    /// READ requests kept in flight during `download`, all on this session's one
    /// SFTP channel (no extra channels are opened). With a single outstanding
    /// read every chunk costs a full round trip: a 16 MB file took ~560 RTTs —
    /// 90 s over a 150 ms link. 16 × the largest READ OpenSSH allows (255 KiB)
    /// still fits inside `defaultChannelWindowBytes`, so the server never has to
    /// wait for a window adjust.
    static let downloadWindow = 16

    /// 上传时一次从本地文件读进内存（也就是一个 WRITE）的上限，与 OpenSSH 的 256 KiB 一致。实际取它与
    /// `SFTPClient.maximumWriteLength`（服务端的宣告，已经封顶在 `SFTPClient.maximumTransferLength`）的小者。
    static let uploadChunkBytes = 256 * 1024

    /// How much of the stat'ed size one `readAll(expectedLength:)` covers (and
    /// so how much is held in memory before it is written out).
    static let downloadSegmentBytes = 8 << 20

    /// Stream the remote file to `localURL`, overwriting any existing local file.
    ///
    /// The stat'ed size is read with `SFTPFile.readAll(expectedLength:)`, so a
    /// file that is shorter than it claimed (truncated meanwhile, or a server
    /// reporting EOF early) fails with `SFTPError.shortRead` instead of being
    /// reported as a complete download. Bytes past the stat'ed size (the file
    /// grew) are still copied until EOF.
    ///
    /// 先写进临时文件（系统给的替换目录，拿不到时在目标旁边；随机名、独占创建、名字截短到合法长度），读完才原子地
    /// 换到 `localURL`（`replaceItemAt` / `rename(2)`）。远程文件打不开、读到一半失败（`shortRead`、断线）或被取消时，
    /// `localURL` 原来的文件原封不动，临时文件删掉；远程句柄在后台关，连接卡死时取消也马上返回。
    ///
    /// - Parameter maximumBytes: When non-nil, the download fails fast (both from
    ///   the pre-flight `stat` and while reading) once the observed size exceeds
    ///   this bound, so a corrupt/hostile server can't exhaust local storage.
    /// - Returns: The pre-flight `stat` result, so callers need not stat again.
    @discardableResult
    public func download(
        _ remotePath: String,
        to localURL: URL,
        maximumBytes: Int64? = nil
    ) async throws -> SSHRemoteFileInfo {
        let info = try await stat(remotePath)
        if let maximumBytes, info.size > maximumBytes {
            throw SSHFileTransferError.downloadTooLarge(observed: info.size, maximum: maximumBytes)
        }

        let file = try await sftp.openFile(remotePath, flags: .read)
        let fm = FileManager.default
        // 沙盒里通过存储面板拿到的往往只有这一个文件的权限，同目录下另建文件会被拒：临时文件放系统给的
        // 「替换用」目录（同一卷上，换过去仍是原子的），拿不到时才退回目标旁边。
        let replacementDirectory = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: localURL, create: true)
        let suffix = ".usshkit-download-\(Self.randomSuffix())"
        let base = Self.truncated(localURL.lastPathComponent, toBytes: Self.maximumNameBytes - suffix.utf8.count - 1)
        let temporary = (replacementDirectory ?? localURL.deletingLastPathComponent())
            .appendingPathComponent("." + base + suffix)
        func discardTemporary() {
            Darwin.unlink(temporary.path)
            if let replacementDirectory { try? fm.removeItem(at: replacementDirectory) }
        }
        // O_EXCL：不跟随、不复用已经在那儿的东西（包括符号链接）。权限交给 umask，与以前 createFile 的一样。
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else {
            if let replacementDirectory { try? fm.removeItem(at: replacementDirectory) }
            Self.closeInBackground(file)
            throw SSHFileTransferError.localFileUnavailable(localURL.path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let chunk = sftp.maximumReadLength
        do {
            _ = try await Self.segmentedRead(
                expectedSize: info.size,
                segmentBytes: Self.downloadSegmentBytes,
                maximumBytes: maximumBytes,
                readExactly: { offset, length in
                    try await file.readAll(from: offset, expectedLength: length, window: Self.downloadWindow)
                },
                readNext: { offset in try await file.read(from: offset, length: chunk) },
                write: { buffer in try handle.write(contentsOf: Data(buffer.readableBytesView)) }
            )
            try handle.close()
            try await file.close()
            if replacementDirectory != nil, fm.fileExists(atPath: localURL.path) {
                _ = try fm.replaceItemAt(localURL, withItemAt: temporary)
            } else if Darwin.rename(temporary.path, localURL.path) != 0 {
                throw SSHFileTransferError.localFileUnavailable(localURL.path)
            }
            if let replacementDirectory { try? fm.removeItem(at: replacementDirectory) }
        } catch {
            try? handle.close()
            discardTemporary()
            Self.closeInBackground(file)
            throw error
        }
        return info
    }

    /// Read a file whose size was `stat`ed as `expectedSize`: the stat'ed bytes in
    /// segments of `segmentBytes`, each of which must arrive whole (`readExactly`
    /// throws if the file ends early — the session passes `readAll(expectedLength:)`),
    /// then whatever follows until EOF (`readNext` returns nil), so a file that grew
    /// meanwhile is still copied whole. Segments are written strictly in order.
    /// Returns the bytes written.
    static func segmentedRead(
        expectedSize: Int64,
        segmentBytes: Int,
        maximumBytes: Int64?,
        readExactly: (UInt64, Int) async throws -> ByteBuffer,
        readNext: (UInt64) async throws -> ByteBuffer?,
        write: (ByteBuffer) throws -> Void
    ) async throws -> Int64 {
        var received: Int64 = 0
        func accept(_ buffer: ByteBuffer) throws {
            let count = Int64(buffer.readableBytes)
            if let maximumBytes, received > maximumBytes - count {
                throw SSHFileTransferError.downloadTooLarge(observed: received + count, maximum: maximumBytes)
            }
            try write(buffer)
            received += count
        }

        var offset: UInt64 = 0
        let total = UInt64(max(0, expectedSize))
        while offset < total {
            try Task.checkCancellation()
            let length = Int(min(UInt64(segmentBytes), total - offset))
            let segment = try await readExactly(offset, length)
            guard segment.readableBytes == length else {
                // readAll(expectedLength:) never hands back a different length; guard
                // anyway so a short segment can never be written as if complete.
                throw SFTPError.shortRead(expected: length, actual: segment.readableBytes)
            }
            try accept(segment)
            offset += UInt64(length)
        }
        while true {
            try Task.checkCancellation()
            guard let buffer = try await readNext(offset) else { break }
            guard buffer.readableBytes > 0 else { break }
            try accept(buffer)
            offset += UInt64(buffer.readableBytes)
        }
        return received
    }

    /// Upload to a temporary file next to `remotePath`, then move it into place.
    ///
    /// With `posix-rename@openssh.com` (every OpenSSH server) the move atomically
    /// replaces an existing file. Servers without it only have SFTP v3 RENAME,
    /// which refuses to overwrite: there the old file is removed first, so the
    /// replacement is not atomic.
    ///
    /// 临时文件名带随机后缀、独占创建（`SSH_FXF_EXCL`：共享的可写目录里别人预先放好的同名文件或符号链接不会被
    /// 写穿），名字太长时截短原名，保证在目标目录里合法。
    ///
    /// 没有 `posix-rename` 时：只在第一次改名回 `SSH_FX_FAILURE` / `FILE_ALREADY_EXISTS`、而且目标确实在（`lstat`，
    /// 悬空的符号链接也算在）时才先删再改名。目标是符号链接时替换的是**链接本身**（REMOVE 删的是链接，与以前、
    /// 与 `posix-rename` 一样），链接指向的文件不动。删目标的请求发出去以后：
    /// - 服务器明确拒绝删（`SFTPError.status`）：目标完好，删掉临时文件、原样报错；
    /// - 别的结局（被取消、连接断了）：目标可能已删，**留着**临时文件，抛 `.uploadOutcomeUnknown`；
    /// - 删成了、最后的改名被服务器拒绝：留着临时文件，抛 `.uploadNotMovedIntoPlace`；改名没有确定的回答：`.uploadOutcomeUnknown`。
    /// 目标还完好时（上传失败、被取消、第一次改名失败）删掉临时文件并原样抛出（取消仍是 `CancellationError`）。
    /// 收尾在后台进行、最多等 `cleanupDeadline`，连接卡死时取消也能马上返回。
    public func uploadAtomically(_ localURL: URL, to remotePath: String) async throws {
        let tempPath = Self.temporaryPath(for: remotePath)
        let sftp = self.sftp
        let cleanUp = { await Self.bestEffort(within: Self.cleanupDeadline) { try? await sftp.remove(tempPath) } }
        do {
            try await uploadStreaming(localURL, to: tempPath)
        } catch {
            await cleanUp()
            throw error
        }
        if sftp.supportsExtension(SFTPExtensionName.posixRename) {
            do {
                try await sftp.rename(tempPath, to: remotePath, mode: .posix)
            } catch {
                // 原子改名：要么改成了（临时路径已经不在，删它无害），要么没改，目标都完好。
                await cleanUp()
                throw error
            }
            return
        }
        let firstFailure: SFTPError
        do {
            try await sftp.rename(tempPath, to: remotePath)
            return
        } catch let error as SFTPError where error.statusCode == .failure || error.statusCode == .fileAlreadyExists {
            firstFailure = error
        } catch {
            // v3 的 RENAME 不覆盖：改成了说明目标原本不在，没改成目标也完好。
            await cleanUp()
            throw error
        }
        // SSH_FX_FAILURE 是兜底码，先确认目标真的在。用 lstat：悬空的符号链接也是「在」。
        let exists: Bool
        do {
            _ = try await sftp.lstat(remotePath)
            exists = true
        } catch let error as SFTPError where error.statusCode != nil {
            exists = false
        } catch {
            await cleanUp()
            throw error
        }
        guard exists else {
            await cleanUp()
            throw firstFailure
        }
        do {
            try await sftp.remove(remotePath)
        } catch let error as SFTPError where error.statusCode != nil {
            await cleanUp()                                    // 服务器明确拒绝了删除：目标完好
            throw error
        } catch {
            throw SSHFileTransferError.uploadOutcomeUnknown(
                temporaryPath: tempPath, destination: remotePath, reason: SSHErrorText.describe(error))
        }
        do {
            try await sftp.rename(tempPath, to: remotePath)
        } catch let error as SFTPError where error.statusCode != nil {
            throw SSHFileTransferError.uploadNotMovedIntoPlace(
                temporaryPath: tempPath, destination: remotePath, reason: SSHErrorText.describe(error))
        } catch {
            throw SSHFileTransferError.uploadOutcomeUnknown(
                temporaryPath: tempPath, destination: remotePath, reason: SSHErrorText.describe(error))
        }
    }

    /// 一个文件名最长这么多字节（几乎所有文件系统的 NAME_MAX）。临时文件名在这以内。
    static let maximumNameBytes = 255

    /// `<目录>/<原名，必要时截短>.utable-upload-<16 位十六进制>.tmp`：目标名在目录里合法，临时名也合法。
    static func temporaryPath(for remotePath: String) -> String {
        let slash = remotePath.lastIndex(of: "/")
        let directory = slash.map { String(remotePath[...$0]) } ?? ""
        let name = slash.map { String(remotePath[remotePath.index(after: $0)...]) } ?? remotePath
        let suffix = ".utable-upload-\(randomSuffix()).tmp"
        return directory + truncated(name, toBytes: maximumNameBytes - suffix.utf8.count) + suffix
    }

    /// 按 UTF-8 字节截短，不切断字符。
    static func truncated(_ name: String, toBytes limit: Int) -> String {
        guard name.utf8.count > limit else { return name }
        var result = ""
        var used = 0
        for character in name {
            let size = String(character).utf8.count
            guard used + size <= limit else { break }
            result.append(character)
            used += size
        }
        return result
    }

    static func randomSuffix() -> String {
        String(format: "%016llx", UInt64.random(in: .min ... .max))
    }

    /// 收尾（删临时文件）最多等这么久：连接卡死时 SFTP 请求要等到 TCP 放弃（几分钟），不能让取消也跟着卡住。
    static let cleanupDeadline: Duration = .seconds(3)

    /// 在后台跑收尾、最多等 `limit` 就返回（收尾本身照常在后台做完）。不受所在任务的取消影响——取消后 SFTP 请求
    /// 一发就会抛 `CancellationError`，临时文件就留下了。
    static func bestEffort(within limit: Duration, _ body: @escaping @Sendable () async -> Void) async {
        let once = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            once.set(continuation)
            Task { await body(); once.resume() }
            Task { try? await Task.sleep(for: limit); once.resume() }
        }
    }

    /// 远程文件句柄的收尾：发 CLOSE、不等回答（等回答在连接卡死时会一直等下去）。
    static func closeInBackground(_ file: SFTPFile) {
        Task { try? await file.close() }
    }

    private func uploadStreaming(_ localURL: URL, to remotePath: String) async throws {
        guard let handle = try? FileHandle(forReadingFrom: localURL) else {
            throw SSHFileTransferError.localFileUnavailable(localURL.path)
        }
        defer { try? handle.close() }

        let file = try await sftp.openFile(
            remotePath,
            flags: [.write, .create, .exclusive]
        )
        // 每个 WRITE 按服务端允许的上限切（`limits@openssh.com`，没宣告时 SFTPClient 按 32 KiB），再封顶在
        // `uploadChunkBytes`：一次从本地读进内存的就这么多，服务端宣告多大都一样。
        let chunkSize = min(sftp.maximumWriteLength, Self.uploadChunkBytes)
        do {
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                var buffer = ByteBuffer()
                buffer.writeBytes(chunk)
                try await file.write(buffer, at: offset)
                offset += UInt64(chunk.count)
            }
            try await file.close()
        } catch {
            Self.closeInBackground(file)
            throw error
        }
    }

    public func close() async {
        await sftp.close()
        await connected.close()
    }

    /// SFTP sizes are `UInt64`; a corrupt/hostile server can report a value above
    /// `Int64.max`. Saturating avoids a trap that would turn network input into a
    /// process-level crash.
    private static func clampedSize(_ size: UInt64?) -> Int64 {
        guard let size else { return 0 }
        return size > UInt64(Int64.max) ? Int64.max : Int64(size)
    }
}

/// 只恢复一次的 continuation（收尾做完与时限到了，谁先到算谁）。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false

    func set(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeNow = lock.withLock { () -> Bool in
            if resumed { return true }
            self.continuation = continuation
            return false
        }
        if resumeNow { continuation.resume() }
    }

    func resume() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !resumed else { return nil }
            resumed = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}
