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

    public var errorDescription: String? {
        switch self {
        case .downloadTooLarge(let observed, let maximum):
            return String(localized: "远程文件过大（\(observed) 字节，超过上限 \(maximum) 字节）", bundle: ModuleBundle.bundle)
        case .localFileUnavailable(let path):
            return String(localized: "无法访问本地文件：\(path)", bundle: ModuleBundle.bundle)
        case .uploadNotMovedIntoPlace(let temporaryPath, let destination, let reason):
            return String(localized: "文件已上传到 \(temporaryPath)，但没能替换 \(destination)（旧文件已删除）：\(reason)", bundle: ModuleBundle.bundle)
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
    /// `keepAliveInterval` sends `keepalive@openssh.com` on every hop at that
    /// interval; after `SSHClient.Configuration.keepAliveMaximumUnanswered` (3)
    /// unanswered probes the connection is closed (`disconnectReason` becomes
    /// `.keepAliveTimeout`) and every request in flight fails instead of hanging.
    /// `nil` (the default) sends none.
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
        logger: any SSHLogger = NoOpSSHLogger(),
        keepAliveInterval: Duration? = nil
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
            keepAliveInterval: keepAliveInterval,
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

    /// Every hop of the SSH connection is still up. Once the connection is lost
    /// (server closed it, transport error, keepalive timeout) the session never
    /// recovers: open a new one.
    public nonisolated var isConnected: Bool { connected.isConnected }

    /// Why the SSH connection went away, or nil while it is up or after a local
    /// `close()`.
    public nonisolated var disconnectReason: SSHDisconnectReason? {
        let reason = connected.target.disconnectReason ?? connected.bastion?.disconnectReason
        if let reason, reason.isLocalClose { return nil }
        return reason
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
    /// 先写进同目录下的临时文件（随机名、独占创建），读完才 `rename(2)` 原子地换到 `localURL`。远程文件打不开、读到一半
    /// 失败（`shortRead`、断线）或被取消时，`localURL` 原来的文件原封不动，临时文件删掉。
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
        let temporary = localURL.deletingLastPathComponent()
            .appendingPathComponent(".\(localURL.lastPathComponent).usshkit-download-\(Self.randomSuffix())")
        // O_EXCL：不跟随、不复用已经在那儿的东西（包括符号链接）。权限交给 umask，与以前 createFile 的一样。
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else {
            try? await file.close()
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
            guard Darwin.rename(temporary.path, localURL.path) == 0 else {
                throw SSHFileTransferError.localFileUnavailable(localURL.path)
            }
        } catch {
            try? handle.close()
            Darwin.unlink(temporary.path)
            await Self.ignoringCancellation { try? await file.close() }
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
    /// 写穿）。目标还完好时（上传失败、被取消、改名失败）删掉临时文件；没有 `posix-rename`、旧文件已经删掉之后
    /// 最后的改名失败了，就**留着**临时文件，抛 `SSHFileTransferError.uploadNotMovedIntoPlace` 说出它在哪。
    /// 只在第一次改名的失败可能是「目标已存在」（SFTP v3 只回 `SSH_FX_FAILURE`；v5 起的 `FILE_ALREADY_EXISTS`）、
    /// 而且目标确实存在时才走「先删再改名」，权限不足之类的失败原样报出，不删目标。
    public func uploadAtomically(_ localURL: URL, to remotePath: String) async throws {
        let tempPath = Self.temporaryPath(for: remotePath)
        let sftp = self.sftp
        let cleanUp = { await Self.ignoringCancellation { try? await sftp.remove(tempPath) } }
        // 目标已经在的话，新文件要继承它的权限（以及尽量继承属主 / 属组）：改名是换一个新文件上去，
        // 不继承的话 0660 的库会变成服务端默认的 0644、属主变成登录用户。目标不在就照服务端默认。
        let destination = try? await sftp.stat(remotePath)
        do {
            try await uploadStreaming(localURL, to: tempPath, matching: destination?.isRegularFile == true ? destination : nil)
        } catch {
            await cleanUp()
            throw error
        }
        if sftp.supportsExtension(SFTPExtensionName.posixRename) {
            do {
                try await sftp.rename(tempPath, to: remotePath, mode: .posix)
            } catch {
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
            await cleanUp()
            throw error
        }
        // SSH_FX_FAILURE 是兜底码，先确认目标真的在。
        guard (try? await sftp.stat(remotePath)) != nil else {
            await cleanUp()
            throw firstFailure
        }
        do {
            try await sftp.remove(remotePath)
        } catch {
            await cleanUp()                                    // 目标没删掉，还完好
            throw error
        }
        do {
            try await sftp.rename(tempPath, to: remotePath)
        } catch {
            throw SSHFileTransferError.uploadNotMovedIntoPlace(
                temporaryPath: tempPath, destination: remotePath, reason: SSHErrorText.describe(error))
        }
    }

    /// 让临时文件的权限位（含 setuid / setgid / sticky）与属主 / 属组跟目标一样。尽力而为：服务端拒绝
    /// （`PERMISSION_DENIED`、不支持 setstat……）就算了，上传照样成功——数据比权限要紧。只改和临时文件现状
    /// 不同的那几项（不是 root 的用户改不了属主，白发一次请求还会多一条拒绝）。
    static func adoptAttributes(of destination: SFTPFileAttributes, on file: SFTPFile) async {
        let current = try? await file.stat()
        if let bits = destination.permissionBits, current?.permissionBits != bits {
            try? await file.setAttributes(SFTPFileAttributes(permissions: bits))
        }
        guard let owner = destination.owner, let currentOwner = current?.owner, currentOwner != owner else { return }
        do {
            try await file.setAttributes(SFTPFileAttributes(owner: owner))
        } catch {
            // 换不了属主（不是 root）时属组往往还能换（登录用户在那个组里）。
            if currentOwner.groupID != owner.groupID {
                try? await file.setAttributes(SFTPFileAttributes(
                    owner: SFTPFileOwner(userID: currentOwner.userID, groupID: owner.groupID)))
            }
        }
    }

    /// `<remotePath>.utable-upload-<16 位十六进制>.tmp`。
    static func temporaryPath(for remotePath: String) -> String {
        "\(remotePath).utable-upload-\(randomSuffix()).tmp"
    }

    static func randomSuffix() -> String {
        String(format: "%016llx", UInt64.random(in: .min ... .max))
    }

    /// 收尾动作不受所在任务的取消影响（取消后 SFTP 请求一发就会抛 `CancellationError`，临时文件就留下了）。
    static func ignoringCancellation(_ body: @escaping @Sendable () async -> Void) async {
        await Task { await body() }.value
    }

    private func uploadStreaming(_ localURL: URL, to remotePath: String,
                                 matching destination: SFTPFileAttributes? = nil) async throws {
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
            if let destination {
                await Self.adoptAttributes(of: destination, on: file)
            }
            try await file.close()
        } catch {
            await Self.ignoringCancellation { try? await file.close() }
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
