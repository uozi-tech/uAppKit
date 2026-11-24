import NIOConcurrencyHelpers
import NIOCore

/// 一个打开着的远程文件。值语义的 `Sendable` 句柄：拷贝之间共享同一个「已关闭」状态，
/// 可以在多个任务里并发 `read` / `write`（同一条通道上的请求本来就是多路复用的）。
///
/// `read(from:length:)` 与 `write(_:at:)` 各对应**一个** SFTP 请求，是上层自己做窗口化并行传输的原语；
/// `readAll` / `write(contentsOf:)` 是在它们之上带窗口的便捷循环。
public struct SFTPFile: Sendable {
    public let client: SFTPClient
    /// 打开时给的路径（只用于诊断）。
    public let path: SFTPPath
    let handle: ByteBuffer
    private let closed: NIOLockedValueBox<Bool>

    init(client: SFTPClient, path: SFTPPath, handle: ByteBuffer) {
        self.client = client
        self.path = path
        self.handle = handle
        self.closed = NIOLockedValueBox(false)
    }

    public var isClosed: Bool { closed.withLockedValue { $0 } }

    private func checkOpen() throws {
        if isClosed { throw SFTPError.handleClosed }
    }

    // MARK: - 单个请求

    /// 一次 SSH_FXP_READ。返回 nil = EOF；返回的字节可以少于 `length`（短读，调用方自己补发）。
    ///
    /// `length` 超过 `client.maximumReadLength` 时按上限要（协议本来就允许服务端少给）。
    public func read(from offset: UInt64, length: Int) async throws -> ByteBuffer? {
        try checkOpen()
        let wanted = UInt32(clamping: max(0, min(length, client.maximumReadLength)))
        let response = try await client.core.perform {
            .read(id: $0, handle: handle, offset: offset, length: wanted)
        }
        return try SFTPResponseReader.readData(response, requested: Int(wanted))
    }

    /// 一次 SSH_FXP_WRITE。`data` 的切片原样写进通道，不拷贝。
    ///
    /// 超过 `client.maximumWriteLength`（或整帧超过服务端的包长上限）时抛 `requestTooLarge`，不发。
    public func write(_ data: ByteBuffer, at offset: UInt64) async throws {
        try checkOpen()
        try checkWriteLength(data.readableBytes)
        try SFTPResponseReader.ok(try await client.core.perform {
            .write(id: $0, handle: handle, offset: offset, data: data)
        })
    }

    private func checkWriteLength(_ length: Int) throws {
        guard length <= client.maximumWriteLength else {
            throw SFTPError.requestTooLarge(length: length, limit: client.maximumWriteLength)
        }
        // 类型 1 + 请求号 4 + 句柄 4+n + offset 8 + 数据长度 4。
        let packet = 1 + 4 + 4 + handle.readableBytes + 8 + 4 + length
        guard packet <= client.maximumPacketLength else {
            throw SFTPError.requestTooLarge(length: packet, limit: client.maximumPacketLength)
        }
    }

    /// FSTAT。
    public func stat() async throws -> SFTPFileAttributes {
        try checkOpen()
        return try SFTPResponseReader.attributes(try await client.core.perform { .fstat(id: $0, handle: handle) })
    }

    /// FSETSTAT。只有非 nil 的字段会被改（例如只给 `size` = 截断 / 扩展到这个长度）。
    public func setAttributes(_ attributes: SFTPFileAttributes) async throws {
        try checkOpen()
        try SFTPResponseReader.ok(try await client.core.perform {
            .fsetstat(id: $0, handle: handle, attributes: attributes)
        })
    }

    /// `fsync@openssh.com`：让服务端把这个文件刷到盘上。
    public func sync() async throws {
        try checkOpen()
        guard client.supportsExtension(SFTPExtensionName.fsync) else {
            throw SFTPError.extensionUnsupported(SFTPExtensionName.fsync)
        }
        try SFTPResponseReader.ok(try await client.core.perform { .extended(id: $0, request: .fsync(handle: handle)) })
    }

    /// `fstatvfs@openssh.com`：这个文件所在文件系统的容量。
    public func statVFS() async throws -> SFTPFileSystemStats {
        try checkOpen()
        guard client.supportsExtension(SFTPExtensionName.fstatVFS) else {
            throw SFTPError.extensionUnsupported(SFTPExtensionName.fstatVFS)
        }
        let response = try await client.core.perform { .extended(id: $0, request: .fstatVFS(handle: handle)) }
        return try SFTPResponseReader.extendedReply(response, as: SFTPFileSystemStats.decode)
    }

    /// CLOSE。只有第一次调用会发请求，之后（包括并发的另一份拷贝）直接返回。
    /// 之后这个句柄上的读写抛 `handleClosed`。
    public func close() async throws {
        guard markClosed() else { return }
        try SFTPResponseReader.ok(try await client.core.wait(client.core.submit { .close(id: $0, handle: handle) }))
    }

    /// 发 CLOSE 不等回答（出错路径上用）。
    func closeDetached() {
        guard markClosed() else { return }
        client.core.sendDetached { .close(id: $0, handle: handle) }
    }

    private func markClosed() -> Bool {
        closed.withLockedValue { closed in
            defer { closed = true }
            return !closed
        }
    }

    // MARK: - 便捷循环

    /// 从 `offset` 读到 EOF，最多 `window` 个 READ 同时在途，按顺序拼起来。
    ///
    /// 某一段短读时，在同一段里接着补发，补齐之后才拼后面的段；读到 EOF 就收尾（后面已发出的请求作废）。
    /// `maximumBytes` 非 nil 时，拼进来之前先核对，超了抛 `limitExceeded`（不会先把超限的数据收进内存）。
    public func readAll(from offset: UInt64 = 0, maximumBytes: Int? = nil, window: Int = 16) async throws -> ByteBuffer {
        try checkOpen()
        let chunk = client.maximumReadLength
        let core = client.core
        let handle = self.handle
        var result = ByteBuffer()
        var nextOffset = offset
        var queue = CircularBuffer<(offset: UInt64, request: SFTPInFlightRequest)>(initialCapacity: max(1, window))

        func issue() {
            let at = nextOffset
            let request = core.submit { .read(id: $0, handle: handle, offset: at, length: UInt32(chunk)) }
            queue.append((at, request))
            nextOffset &+= UInt64(chunk)
        }
        func accept(_ data: ByteBuffer) throws {
            if let maximumBytes, result.readableBytes + data.readableBytes > maximumBytes {
                throw SFTPError.limitExceeded(maximumBytes: maximumBytes)
            }
            var data = data
            result.writeBuffer(&data)
        }

        do {
            try Task.checkCancellation()
            while queue.count < max(1, window) { issue() }
            reading: while let head = queue.popFirst() {
                guard let data = try SFTPResponseReader.readData(try await core.wait(head.request), requested: chunk) else {
                    break reading
                }
                try accept(data)
                var got = data.readableBytes
                // 短读：同一段剩下的部分串行补齐（后面的段已经在路上了，拼的时候要连续）。
                while got < chunk {
                    let at = head.offset + UInt64(got)
                    let rest = chunk - got
                    let response = try await core.perform {
                        .read(id: $0, handle: handle, offset: at, length: UInt32(rest))
                    }
                    guard let more = try SFTPResponseReader.readData(response, requested: rest) else {
                        break reading
                    }
                    // 0 字节的 DATA 不算 EOF，但也不能原地打转。
                    if more.readableBytes == 0 { break reading }
                    try accept(more)
                    got += more.readableBytes
                }
                issue()
            }
        } catch {
            while let pending = queue.popFirst() { core.abandon(pending.request) }
            throw error
        }
        while let pending = queue.popFirst() { core.abandon(pending.request) }
        return result
    }

    /// 把 `data` 写到 `offset` 起的位置：按 `client.maximumWriteLength` 切片，最多 `window` 个 WRITE 同时在途。
    /// 切片共享 `data` 的存储，不拷贝。任何一片失败就抛它的错误（之前发出的片可能已经落盘）。
    public func write(contentsOf data: ByteBuffer, at offset: UInt64 = 0, window: Int = 16) async throws {
        try checkOpen()
        let total = data.readableBytes
        guard total > 0 else { return }
        let chunk = client.maximumWriteLength
        try checkWriteLength(min(chunk, total))
        let core = client.core
        let handle = self.handle
        var queue = CircularBuffer<SFTPInFlightRequest>(initialCapacity: max(1, window))
        var cursor = 0
        do {
            try Task.checkCancellation()
            while cursor < total || !queue.isEmpty {
                while queue.count < max(1, window), cursor < total {
                    let length = min(chunk, total - cursor)
                    let slice = data.getSlice(at: data.readerIndex + cursor, length: length)!
                    let at = offset + UInt64(cursor)
                    queue.append(core.submit { .write(id: $0, handle: handle, offset: at, data: slice) })
                    cursor += length
                }
                let head = queue.removeFirst()
                try SFTPResponseReader.ok(try await core.wait(head))
            }
        } catch {
            while let pending = queue.popFirst() { core.abandon(pending) }
            throw error
        }
    }
}
