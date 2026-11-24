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

    public var errorDescription: String? {
        switch self {
        case .downloadTooLarge(let observed, let maximum):
            return String(localized: "远程文件过大（\(observed) 字节，超过上限 \(maximum) 字节）", bundle: ModuleBundle.bundle)
        case .localFileUnavailable(let path):
            return String(localized: "无法访问本地文件：\(path)", bundle: ModuleBundle.bundle)
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
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool = { _ in false }
    ) async throws -> SSHFileTransferSession {
        let connected = try await SSHClientFactory.connect(
            endpoint: endpoint,
            credential: credential,
            hostKeyStore: hostKeyStore,
            hostKeyPolicy: hostKeyPolicy,
            connectTimeout: connectTimeout,
            approvalTimeout: approvalTimeout,
            approver: approver,
            maximumPacketSize: maximumPacketSize(forWindow: channelWindowBytes)
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

        let fm = FileManager.default
        try? fm.removeItem(at: localURL)
        guard fm.createFile(atPath: localURL.path, contents: nil) else {
            throw SSHFileTransferError.localFileUnavailable(localURL.path)
        }
        let handle = try FileHandle(forWritingTo: localURL)
        defer { try? handle.close() }

        let file = try await sftp.openFile(remotePath, flags: .read)
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
            try await file.close()
        } catch {
            try? await file.close()
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
    public func uploadAtomically(_ localURL: URL, to remotePath: String) async throws {
        let tempPath = remotePath + ".utable-upload.tmp"
        try await uploadStreaming(localURL, to: tempPath)
        do {
            if sftp.supportsExtension(SFTPExtensionName.posixRename) {
                try await sftp.rename(tempPath, to: remotePath, mode: .posix)
            } else {
                do {
                    try await sftp.rename(tempPath, to: remotePath)
                } catch let error as SFTPError where error.statusCode != nil {
                    // 目标已存在时 v3 的 RENAME 回 FAILURE：删掉旧文件再改名。
                    try? await sftp.remove(remotePath)
                    try await sftp.rename(tempPath, to: remotePath)
                }
            }
        } catch {
            try? await sftp.remove(tempPath)
            throw error
        }
    }

    private func uploadStreaming(_ localURL: URL, to remotePath: String) async throws {
        guard let handle = try? FileHandle(forReadingFrom: localURL) else {
            throw SSHFileTransferError.localFileUnavailable(localURL.path)
        }
        defer { try? handle.close() }

        let file = try await sftp.openFile(
            remotePath,
            flags: [.write, .create, .truncate]
        )
        // 每个 WRITE 按服务端允许的上限切（`limits@openssh.com`，没宣告时 SFTPClient 按 32 KiB）。
        let chunkSize = sftp.maximumWriteLength
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
            try? await file.close()
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
