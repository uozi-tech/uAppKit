import NIOConcurrencyHelpers
import NIOCore

/// 一个打开着的远程文件。值语义的 `Sendable` 句柄：拷贝之间共享同一份状态，
/// 可以在多个任务里并发 `read` / `write`（同一条通道上的请求本来就是多路复用的）。
///
/// `read(from:length:)` 与 `write(_:at:)` 各对应**一个** SFTP 请求，是上层自己做窗口化并行传输的原语；
/// `readAll` / `write(contentsOf:)` 是在它们之上带窗口的便捷循环。
///
/// **关闭的次序**：OpenSSH 的 sftp-server 会把释放掉的句柄编号马上分给下一个 OPEN，所以 CLOSE 之后
/// 再发到旧句柄上的 READ / WRITE 会落进新开的那个文件，而且回成功。为此每个请求从发出到拿到回答
/// （或被撤掉）都记在这个句柄的在途计数里；`close()` 先把句柄标成「正在关」（之后任何拷贝再发请求都抛
/// `handleClosed`，不会发出去），等在途的都结束，才发 CLOSE。
public struct SFTPFile: Sendable {
    public let client: SFTPClient
    /// 打开时给的路径（只用于诊断）。
    public let path: SFTPPath
    let handle: ByteBuffer
    private let state: SFTPFileState

    init(client: SFTPClient, path: SFTPPath, handle: ByteBuffer) {
        self.client = client
        self.path = path
        self.handle = handle
        self.state = SFTPFileState()
    }

    /// 已经开始关（或关完了）。
    public var isClosed: Bool { state.isClosing }

    private func checkOpen() throws {
        if isClosed { throw SFTPError.handleClosed }
    }

    // MARK: - 在途计数

    /// 记一笔在途再发出去；已经在关时抛 `handleClosed`，什么都不发。每个返回值必须恰好
    /// `waitTracked` 或 `abandonTracked` 一次。
    private func submitTracked(_ build: (UInt32) -> SFTPRequest) throws -> SFTPInFlightRequest {
        try state.begin()
        return client.core.submit(build)
    }

    private func waitTracked(_ request: SFTPInFlightRequest) async throws -> SFTPResponse {
        defer { state.end() }
        return try await client.core.wait(request)
    }

    private func abandonTracked(_ request: SFTPInFlightRequest) {
        client.core.abandon(request)
        state.end()
    }

    /// 一个请求：发出、等回答，全程记在在途计数里。
    private func perform(_ build: (UInt32) -> SFTPRequest) async throws -> SFTPResponse {
        try Task.checkCancellation()
        return try await waitTracked(try submitTracked(build))
    }

    // MARK: - 单个请求

    /// 一次 SSH_FXP_READ。返回 nil = EOF；返回的字节可以少于 `length`（短读，调用方自己补发），但 `length > 0` 时
    /// 不会是空的：服务端回 0 字节的 DATA 抛 `invalidResponse`。
    ///
    /// `length` 超过 `client.maximumReadLength` 时按上限要（协议本来就允许服务端少给）；
    /// `length <= 0` 时不发请求，直接回空。窗口化的调用方按 `client.maximumReadLength` 切段
    /// （不要写死某个数，例如 32 000：不同服务端的上限差得很远）。
    ///
    /// 返回的数据是收帧缓冲里的切片（不拷贝），拿着它就拿着那块缓冲；要长期保存时自己拷一份。
    public func read(from offset: UInt64, length: Int) async throws -> ByteBuffer? {
        try checkOpen()
        // OpenSSH 对 0 字节的 READ 回 EOF：发出去就会在文件中间「读到头」。不发，直接回空。
        guard length > 0 else { return ByteBuffer() }
        let wanted = UInt32(clamping: min(length, client.maximumReadLength))
        let response = try await perform {
            .read(id: $0, handle: handle, offset: offset, length: wanted)
        }
        return try SFTPResponseReader.readData(response, requested: Int(wanted))
    }

    /// 一次 SSH_FXP_WRITE。`data` 的切片原样写进通道，不拷贝。
    ///
    /// 超过 `client.maximumWriteLength`（或整帧超过服务端的包长上限）时抛 `requestTooLarge`，不发；
    /// 窗口化的调用方按 `client.maximumWriteLength` 切片。区间越过 `UInt64` 上限时抛 `offsetOutOfRange`。
    public func write(_ data: ByteBuffer, at offset: UInt64) async throws {
        try checkOpen()
        guard !offset.addingReportingOverflow(UInt64(data.readableBytes)).overflow else { throw SFTPError.offsetOutOfRange }
        try checkWriteLength(data.readableBytes)
        try SFTPResponseReader.ok(try await perform {
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
        return try SFTPResponseReader.attributes(try await perform { .fstat(id: $0, handle: handle) })
    }

    /// FSETSTAT。只有非 nil 的字段会被改（例如只给 `size` = 截断 / 扩展到这个长度）。
    public func setAttributes(_ attributes: SFTPFileAttributes) async throws {
        try checkOpen()
        try SFTPResponseReader.ok(try await perform {
            .fsetstat(id: $0, handle: handle, attributes: attributes)
        })
    }

    /// `fsync@openssh.com`：让服务端把这个文件刷到盘上。
    public func sync() async throws {
        try checkOpen()
        guard client.supportsExtension(SFTPExtensionName.fsync) else {
            throw SFTPError.extensionUnsupported(SFTPExtensionName.fsync)
        }
        try SFTPResponseReader.ok(try await perform { .extended(id: $0, request: .fsync(handle: handle)) })
    }

    /// `fstatvfs@openssh.com`：这个文件所在文件系统的容量。
    public func statVFS() async throws -> SFTPFileSystemStats {
        try checkOpen()
        guard client.supportsExtension(SFTPExtensionName.fstatVFS) else {
            throw SFTPError.extensionUnsupported(SFTPExtensionName.fstatVFS)
        }
        let response = try await perform { .extended(id: $0, request: .fstatVFS(handle: handle)) }
        return try SFTPResponseReader.extendedReply(response, as: SFTPFileSystemStats.decode)
    }

    /// CLOSE。先标成「正在关」（之后这个句柄上的请求抛 `handleClosed`，不发出去），
    /// 等已经发出的请求都结束，再发 CLOSE。只有第一次调用会发，之后（包括别的拷贝）直接返回。
    ///
    /// 等待期间任务被取消：抛 `CancellationError`，CLOSE 改在后台等在途结束后发出（不等回答）。
    public func close() async throws {
        guard state.beginClosing() else { return }
        let finished = await state.waitUntilIdle()
        guard finished else {
            sendCloseWhenIdle()
            throw CancellationError()
        }
        try SFTPResponseReader.ok(try await client.core.wait(client.core.submit { .close(id: $0, handle: handle) }))
    }

    /// 关掉、不等回答（出错路径上用）：同样等在途的请求结束后才发 CLOSE。
    func closeDetached() {
        guard state.beginClosing() else { return }
        sendCloseWhenIdle()
    }

    private func sendCloseWhenIdle() {
        let state = self.state
        let core = client.core
        let handle = self.handle
        Task {
            _ = await state.waitUntilIdle(cancellable: false)
            core.sendDetached { .close(id: $0, handle: handle) }
        }
    }

    // MARK: - 便捷循环

    /// 从 `offset` 读到 EOF（或读满 `expectedLength`），最多 `window` 个 READ 同时在途，按顺序拼起来。
    ///
    /// 数据完整性的规矩（短读、空读都不能被当成「读完了」悄悄收尾）：
    /// - 某一段短读：在同一段里接着补发，补齐之后才拼后面的段；
    /// - 0 字节的 DATA 不是 EOF，是协议错误（`invalidResponse`）——原地打转与当成 EOF 都会出事；
    /// - 某一段回 EOF：等已经发出去的后面几段都回来，它们也必须是 EOF；有数据就是中间凭空多了个洞，
    ///   抛 `invalidResponse`，绝不把带洞的数据当成功交出去；
    /// - 给了 `expectedLength`（调用方 stat 过，知道这些字节一定在）：只读这么多，不够就抛 `shortRead`。
    ///
    /// `maximumBytes` 非 nil 时，拼进来之前先核对，超了抛 `limitExceeded`（不会先把超限的数据收进内存）。
    /// 区间越过 `UInt64` 上限时抛 `offsetOutOfRange`。
    public func readAll(
        from offset: UInt64 = 0,
        expectedLength: Int? = nil,
        maximumBytes: Int? = nil,
        window: Int = 16
    ) async throws -> ByteBuffer {
        try checkOpen()
        let end: UInt64?
        if let expectedLength {
            let (value, overflow) = offset.addingReportingOverflow(UInt64(max(0, expectedLength)))
            guard !overflow else { throw SFTPError.offsetOutOfRange }
            end = value
        } else {
            end = nil
        }
        let chunk = UInt64(client.maximumReadLength)
        let handle = self.handle
        var result = ByteBuffer()
        var nextOffset = offset
        var queue = CircularBuffer<(offset: UInt64, length: Int, request: SFTPInFlightRequest)>(initialCapacity: max(1, window))

        /// 再发一段；已经发到 `end` 时什么都不做。
        func issue() throws {
            var length = chunk
            if let end {
                guard nextOffset < end else { return }
                length = min(chunk, end - nextOffset)
            }
            let (after, overflow) = nextOffset.addingReportingOverflow(length)
            guard !overflow else { throw SFTPError.offsetOutOfRange }
            let at = nextOffset
            let request = try submitTracked {
                .read(id: $0, handle: handle, offset: at, length: UInt32(clamping: length))
            }
            queue.append((at, Int(length), request))
            nextOffset = after
        }
        func accept(_ data: ByteBuffer, at position: UInt64) throws {
            guard data.readableBytes > 0 else {
                throw SFTPError.invalidResponse("zero-length SSH_FXP_DATA at offset \(position)")
            }
            if let maximumBytes, result.readableBytes + data.readableBytes > maximumBytes {
                throw SFTPError.limitExceeded(maximumBytes: maximumBytes)
            }
            var data = data
            result.writeBuffer(&data)
        }

        do {
            try Task.checkCancellation()
            for _ in 0..<max(1, window) { try issue() }
            var reachedEOF = false
            reading: while let head = queue.popFirst() {
                guard let data = try SFTPResponseReader.readData(try await waitTracked(head.request), requested: head.length) else {
                    reachedEOF = true
                    break reading
                }
                try accept(data, at: head.offset)
                var got = data.readableBytes
                // 短读：同一段剩下的部分串行补齐（后面的段已经在路上了，拼的时候要连续）。
                while got < head.length {
                    let at = head.offset + UInt64(got)
                    let rest = head.length - got
                    let response = try await perform {
                        .read(id: $0, handle: handle, offset: at, length: UInt32(clamping: rest))
                    }
                    guard let more = try SFTPResponseReader.readData(response, requested: rest) else {
                        reachedEOF = true
                        break reading
                    }
                    try accept(more, at: at)
                    got += more.readableBytes
                }
                try issue()
            }
            if reachedEOF {
                // 到头了：已经发出去的后面几段也必须是 EOF，否则中间凭空多了个洞。
                while let next = queue.popFirst() {
                    let response = try await waitTracked(next.request)
                    if let data = try SFTPResponseReader.readData(response, requested: next.length) {
                        throw SFTPError.invalidResponse(
                            "SSH_FXP_DATA of \(data.readableBytes) bytes at offset \(next.offset) after end of file")
                    }
                }
            }
        } catch {
            while let pending = queue.popFirst() { abandonTracked(pending.request) }
            throw error
        }
        if let expectedLength, result.readableBytes < expectedLength {
            throw SFTPError.shortRead(expected: expectedLength, actual: result.readableBytes)
        }
        return result
    }

    /// 把 `data` 写到 `offset` 起的位置：按 `client.maximumWriteLength` 切片，最多 `window` 个 WRITE 同时在途。
    /// 切片共享 `data` 的存储，不拷贝。任何一片失败就抛它的错误（之前发出的片可能已经落盘）。
    /// 区间越过 `UInt64` 上限时抛 `offsetOutOfRange`，什么都不发。
    public func write(contentsOf data: ByteBuffer, at offset: UInt64 = 0, window: Int = 16) async throws {
        try checkOpen()
        let total = data.readableBytes
        guard total > 0 else { return }
        guard !offset.addingReportingOverflow(UInt64(total)).overflow else { throw SFTPError.offsetOutOfRange }
        let chunk = client.maximumWriteLength
        try checkWriteLength(min(chunk, total))
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
                    queue.append(try submitTracked { .write(id: $0, handle: handle, offset: at, data: slice) })
                    cursor += length
                }
                let head = queue.removeFirst()
                try SFTPResponseReader.ok(try await waitTracked(head))
            }
        } catch {
            while let pending = queue.popFirst() { abandonTracked(pending) }
            throw error
        }
    }
}

/// 一个句柄的在途计数与「正在关」标志（同一把锁下）。`SFTPFile` 的每份拷贝共享同一个。
final class SFTPFileState: Sendable {
    private struct State {
        var inFlight = 0
        var closing = false
        var nextWaiter = 0
        var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]
        /// 取消先于等待登记到达的那些等待者（登记时直接返回 false）。
        var cancelledWaiters: Set<Int> = []
    }

    private let state = NIOLockedValueBox(State())

    var isClosing: Bool { state.withLockedValue { $0.closing } }

    /// 记一笔在途；已经在关时抛 `handleClosed`。
    func begin() throws {
        try state.withLockedValue { state in
            guard !state.closing else { throw SFTPError.handleClosed }
            state.inFlight += 1
        }
    }

    func end() {
        let waiters = state.withLockedValue { state -> [CheckedContinuation<Bool, Never>] in
            state.inFlight -= 1
            guard state.inFlight == 0, state.closing else { return [] }
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume(returning: true) }
    }

    /// 标成「正在关」；只有第一次调用返回 true。
    func beginClosing() -> Bool {
        state.withLockedValue { state in
            defer { state.closing = true }
            return !state.closing
        }
    }

    /// 等在途计数归零（只在 `beginClosing` 之后调用）。返回 false = 等的时候任务被取消了。
    func waitUntilIdle(cancellable: Bool = true) async -> Bool {
        let token = state.withLockedValue { state -> Int in
            defer { state.nextWaiter += 1 }
            return state.nextWaiter
        }
        let wait = {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let immediate = self.state.withLockedValue { state -> Bool? in
                    if state.cancelledWaiters.remove(token) != nil { return false }
                    if state.inFlight == 0 { return true }
                    state.waiters[token] = continuation
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        }
        guard cancellable else { return await wait() }
        return await withTaskCancellationHandler {
            await wait()
        } onCancel: {
            let waiter = self.state.withLockedValue { state -> CheckedContinuation<Bool, Never>? in
                if let waiter = state.waiters.removeValue(forKey: token) { return waiter }
                state.cancelledWaiters.insert(token)
                return nil
            }
            waiter?.resume(returning: false)
        }
    }
}
