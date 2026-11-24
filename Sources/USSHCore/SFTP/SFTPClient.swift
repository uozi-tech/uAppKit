import NIOConcurrencyHelpers
import NIOCore

/// 改名的方式。
public enum SFTPRenameMode: Hashable, Sendable {
    /// SSH_FXP_RENAME。OpenSSH 的实现里目标已存在就失败（SSH_FX_FAILURE），不覆盖。
    case standard
    /// 服务端宣告了 `posix-rename@openssh.com` 就用它（`rename(2)` 语义：原子地替换已存在的目标），
    /// 否则退回 `.standard`。
    case posixIfSupported
    /// 只用 `posix-rename@openssh.com`；服务端没宣告时抛 `SFTPError.extensionUnsupported`，不发请求。
    case posix
}

/// SFTP v3 客户端，挂在一条已经接好的通道上（通常是 SSH 的 `sftp` 子系统通道）。
///
/// **对接约定**：`start(on:)` 被调用时，`channel` 的 pipeline 在末端以 `ByteBuffer` 收发**任意切分**的
/// 字节流（SSH 通道数据怎么切都行，这里自己分帧）。`start` 在 pipeline 末尾装上分帧解码器与请求多路复用的
/// handler，发 SSH_FXP_INIT(3)、等 SSH_FXP_VERSION；版本不是 3 就关掉通道并抛错。
///
/// **并发**：同一条通道上的请求数量不设上限、可以乱序回答。所有方法都可以从任意任务里并发调用；
/// 记账全在通道的 EventLoop 上，不为每个请求开任务。取消正在等回答的任务会立即抛 `CancellationError`，
/// 迟到的回答被丢弃（被取消的 open 迟到拿到的句柄会被自动关掉）。
///
/// **错误**：服务端的非 OK 状态一律是 `SFTPError.status`；通道关闭时所有在途请求以
/// `SFTPError.connectionClosed` 失败。
///
/// `close()` 关的是整条通道。
public final class SFTPClient: Sendable {
    public struct Configuration: Sendable {
        /// 收到的单帧最大长度（含类型字节）。超过就当协议错误，关通道。
        public var maximumInboundPacketLength: Int
        /// 服务端没宣告 `limits@openssh.com` 时假定的单次 READ 长度上限。
        public var fallbackMaximumReadLength: Int
        /// 服务端没宣告 `limits@openssh.com` 时假定的单次 WRITE 长度上限。
        public var fallbackMaximumWriteLength: Int
        /// 服务端没宣告 `limits@openssh.com` 时假定的单帧长度上限（草案保证至少 34 000）。
        public var fallbackMaximumPacketLength: Int
        /// 服务端宣告了 `limits@openssh.com` 时，`start` 里先问一次。
        public var queriesLimits: Bool

        public init(
            maximumInboundPacketLength: Int = 4 * 1024 * 1024,
            fallbackMaximumReadLength: Int = 32 * 1024,
            fallbackMaximumWriteLength: Int = 32 * 1024,
            fallbackMaximumPacketLength: Int = 34_000,
            queriesLimits: Bool = true
        ) {
            self.maximumInboundPacketLength = maximumInboundPacketLength
            self.fallbackMaximumReadLength = fallbackMaximumReadLength
            self.fallbackMaximumWriteLength = fallbackMaximumWriteLength
            self.fallbackMaximumPacketLength = fallbackMaximumPacketLength
            self.queriesLimits = queriesLimits
        }
    }

    /// 底下那条通道。
    public let channel: Channel
    /// 服务端的协议版本（总是 3：别的版本在 `start` 里就被拒了）。
    public let serverVersion: UInt32
    /// 服务端在 SSH_FXP_VERSION 里宣告的扩展：名字 → 数据（OpenSSH 给的是版本号字符串）。
    public let extensions: [String: String]
    /// `limits@openssh.com` 的回答；服务端没宣告或 `queriesLimits == false` 时为 nil。
    public let limits: SFTPServerLimits?
    /// 单次 READ 最多要多少字节（服务端的上限与本端收帧上限取小）。多要服务端也只会短给。
    public let maximumReadLength: Int
    /// 单次 WRITE 最多写多少字节；超过的 `SFTPFile.write(_:at:)` 抛 `requestTooLarge`。
    public let maximumWriteLength: Int
    /// 发出的单帧最大长度。
    public let maximumPacketLength: Int

    let core: SFTPClientCore

    private init(core: SFTPClientCore, handshake: SFTPClientChannelHandler.Handshake,
                 limits: SFTPServerLimits?, configuration: Configuration) {
        self.core = core
        self.channel = core.channel
        self.serverVersion = handshake.version
        var extensions: [String: String] = [:]
        for pair in handshake.extensions {
            extensions[pair.name] = pair.data
        }
        self.extensions = extensions
        self.limits = limits

        // 0 = 服务端不限 / 不知道，按回退值算。
        func positive(_ value: UInt64?) -> Int? {
            guard let value, value > 0 else { return nil }
            return value > UInt64(Int.max) ? Int.max : Int(value)
        }
        let packet = positive(limits?.maximumPacketLength) ?? configuration.fallbackMaximumPacketLength
        // 一帧里除了数据还有类型、请求号、句柄、offset 等，留 1 KiB 余量（OpenSSH 自己也是这么定的）。
        let read = positive(limits?.maximumReadLength) ?? configuration.fallbackMaximumReadLength
        let write = positive(limits?.maximumWriteLength) ?? configuration.fallbackMaximumWriteLength
        self.maximumPacketLength = packet
        self.maximumReadLength = max(1, min(read, configuration.maximumInboundPacketLength - 1024))
        self.maximumWriteLength = max(1, min(write, packet - 1024))
    }

    // MARK: - 建立

    /// 在 `channel` 上启动 SFTP 会话（见类型注释里的对接约定）。
    ///
    /// 失败（版本不对、握手前通道断开、任务被取消）时通道会被关掉。
    public static func start(on channel: Channel, configuration: Configuration = Configuration()) async throws -> SFTPClient {
        let requestIDs = NIOLockedValueBox<UInt32>(1)
        let eventLoop = channel.eventLoop
        let maximumFrame = configuration.maximumInboundPacketLength
        let setup = eventLoop.flatSubmit { () -> EventLoopFuture<(NIOLoopBound<SFTPClientChannelHandler>, SFTPClientChannelHandler.Handshake)> in
            let handler = SFTPClientChannelHandler(requestIDs: requestIDs)
            do {
                try channel.pipeline.syncOperations.addHandlers([
                    ByteToMessageHandler(SFTPFrameDecoder(maximumFrameLength: maximumFrame)),
                    handler,
                ])
            } catch {
                return eventLoop.makeFailedFuture(error)
            }
            let promise = eventLoop.makePromise(of: SFTPClientChannelHandler.Handshake.self)
            handler.beginHandshake(promise: promise)
            let bound = NIOLoopBound(handler, eventLoop: eventLoop)
            return promise.futureResult.map { (bound, $0) }
        }

        let handler: NIOLoopBound<SFTPClientChannelHandler>
        let handshake: SFTPClientChannelHandler.Handshake
        do {
            (handler, handshake) = try await withTaskCancellationHandler {
                try await setup.get()
            } onCancel: {
                channel.close(promise: nil)
            }
            try Task.checkCancellation()
        } catch {
            channel.close(promise: nil)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        guard handshake.version == 3 else {
            channel.close(promise: nil)
            throw SFTPError.unsupportedVersion(handshake.version)
        }

        let core = SFTPClientCore(channel: channel, handler: handler, requestIDs: requestIDs)
        var limits: SFTPServerLimits?
        if configuration.queriesLimits, handshake.extensions.contains(where: { $0.name == SFTPExtensionName.limits }) {
            do {
                let response = try await core.perform { .extended(id: $0, request: .limits) }
                limits = try SFTPResponseReader.extendedReply(response, as: SFTPServerLimits.decode)
            } catch {
                channel.close(promise: nil)
                throw error
            }
        }
        return SFTPClient(core: core, handshake: handshake, limits: limits, configuration: configuration)
    }

    // MARK: - 通道

    public var isActive: Bool { channel.isActive }

    /// 通道关闭时完成。
    public var closeFuture: EventLoopFuture<Void> { channel.closeFuture }

    /// 关掉整条通道；在途请求以 `connectionClosed` 失败。重复调用无害。
    public func close() async {
        channel.close(promise: nil)
        try? await channel.closeFuture.get()
    }

    public func supportsExtension(_ name: String) -> Bool {
        extensions[name] != nil
    }

    private func requireExtension(_ name: String) throws {
        guard supportsExtension(name) else { throw SFTPError.extensionUnsupported(name) }
    }

    // MARK: - 目录

    /// 列目录：OPENDIR → READDIR 直到 EOF → CLOSE。默认去掉 `.` 与 `..`。
    public func listDirectory(_ path: String, includingDotEntries: Bool = false) async throws -> [SFTPDirectoryEntry] {
        let handle = try SFTPResponseReader.handle(try await core.perform { .opendir(id: $0, path: path) })
        var entries: [SFTPDirectoryEntry] = []
        do {
            reading: while true {
                switch try await core.perform({ .readdir(id: $0, handle: handle) }) {
                case .name(_, let batch):
                    if includingDotEntries {
                        entries.append(contentsOf: batch)
                    } else {
                        entries.append(contentsOf: batch.lazy.filter { $0.filename != "." && $0.filename != ".." })
                    }
                case .status(_, let code, _, _) where code == .eof:
                    break reading
                case let other:
                    try SFTPResponseReader.throwUnexpected(other, expected: "SSH_FXP_NAME")
                }
            }
        } catch {
            core.sendDetached { .close(id: $0, handle: handle) }
            throw error
        }
        try SFTPResponseReader.ok(try await core.perform { .close(id: $0, handle: handle) })
        return entries
    }

    public func createDirectory(_ path: String, attributes: SFTPFileAttributes = .none) async throws {
        try SFTPResponseReader.ok(try await core.perform { .mkdir(id: $0, path: path, attributes: attributes) })
    }

    public func removeDirectory(_ path: String) async throws {
        try SFTPResponseReader.ok(try await core.perform { .rmdir(id: $0, path: path) })
    }

    // MARK: - 路径

    /// REALPATH：服务端规范化后的绝对路径（`"."` 即登录目录）。
    public func realPath(_ path: String) async throws -> String {
        try SFTPResponseReader.singleName(try await core.perform { .realpath(id: $0, path: path) }).filename
    }

    /// STAT（跟随符号链接）。
    public func stat(_ path: String) async throws -> SFTPFileAttributes {
        try SFTPResponseReader.attributes(try await core.perform { .stat(id: $0, path: path) })
    }

    /// LSTAT（不跟随符号链接）。
    public func lstat(_ path: String) async throws -> SFTPFileAttributes {
        try SFTPResponseReader.attributes(try await core.perform { .lstat(id: $0, path: path) })
    }

    /// SETSTAT；`followingSymlinks == false` 时用 `lsetstat@openssh.com`（改链接本身）。
    /// 只有非 nil 的字段会被改。
    public func setAttributes(_ attributes: SFTPFileAttributes, at path: String, followingSymlinks: Bool = true) async throws {
        if followingSymlinks {
            try SFTPResponseReader.ok(try await core.perform { .setstat(id: $0, path: path, attributes: attributes) })
        } else {
            try requireExtension(SFTPExtensionName.lsetstat)
            try SFTPResponseReader.ok(try await core.perform {
                .extended(id: $0, request: .lsetstat(path: path, attributes: attributes))
            })
        }
    }

    public func rename(_ oldPath: String, to newPath: String, mode: SFTPRenameMode = .standard) async throws {
        let posix: Bool
        switch mode {
        case .standard: posix = false
        case .posixIfSupported: posix = supportsExtension(SFTPExtensionName.posixRename)
        case .posix:
            try requireExtension(SFTPExtensionName.posixRename)
            posix = true
        }
        let response = try await core.perform { id -> SFTPRequest in
            posix ? .extended(id: id, request: .posixRename(oldPath: oldPath, newPath: newPath))
                : .rename(id: id, oldPath: oldPath, newPath: newPath)
        }
        try SFTPResponseReader.ok(response)
    }

    /// 删文件（REMOVE）。
    public func remove(_ path: String) async throws {
        try SFTPResponseReader.ok(try await core.perform { .remove(id: $0, path: path) })
    }

    /// 符号链接指向哪里（原样返回链接里存的字符串）。
    public func readLink(_ path: String) async throws -> String {
        try SFTPResponseReader.singleName(try await core.perform { .readlink(id: $0, path: path) }).filename
    }

    /// 在 `linkPath` 建一个指向 `targetPath` 的符号链接（线上按 OpenSSH 的参数顺序发，见 `SFTPRequest.symlink`）。
    public func createSymlink(at linkPath: String, pointingTo targetPath: String) async throws {
        try SFTPResponseReader.ok(try await core.perform { .symlink(id: $0, linkPath: linkPath, targetPath: targetPath) })
    }

    /// `hardlink@openssh.com`：在 `newPath` 建一个指向 `existingPath` 的硬链接。
    public func createHardLink(at newPath: String, pointingTo existingPath: String) async throws {
        try requireExtension(SFTPExtensionName.hardLink)
        try SFTPResponseReader.ok(try await core.perform {
            .extended(id: $0, request: .hardLink(oldPath: existingPath, newPath: newPath))
        })
    }

    /// `statvfs@openssh.com`：`path` 所在文件系统的容量。
    public func statVFS(_ path: String) async throws -> SFTPFileSystemStats {
        try requireExtension(SFTPExtensionName.statVFS)
        let response = try await core.perform { .extended(id: $0, request: .statVFS(path: path)) }
        return try SFTPResponseReader.extendedReply(response, as: SFTPFileSystemStats.decode)
    }

    // MARK: - 文件

    /// OPEN。返回的句柄用完要 `close()`（任务被取消、句柄还没交到调用方手里时，客户端会自己关）。
    public func openFile(_ path: String, flags: SFTPOpenFlags, attributes: SFTPFileAttributes = .none) async throws -> SFTPFile {
        let handle = try SFTPResponseReader.handle(try await core.perform {
            .open(id: $0, path: path, flags: flags, attributes: attributes)
        })
        return SFTPFile(client: self, path: path, handle: handle)
    }

    /// 打开、交给 `body`、无论成败都关掉。
    public func withFile<Value: Sendable>(
        _ path: String,
        flags: SFTPOpenFlags,
        attributes: SFTPFileAttributes = .none,
        _ body: (SFTPFile) async throws -> Value
    ) async throws -> Value {
        let file = try await openFile(path, flags: flags, attributes: attributes)
        let result: Value
        do {
            result = try await body(file)
        } catch {
            file.closeDetached()
            throw error
        }
        try await file.close()
        return result
    }
}

// MARK: - 请求的收发

/// 一个已经交出去、还在等回答的请求。
struct SFTPInFlightRequest: Sendable {
    let id: UInt32
    let promise: EventLoopPromise<SFTPResponse>
}

/// 客户端与文件句柄共用的收发内核。
struct SFTPClientCore: Sendable {
    let channel: Channel
    let handler: NIOLoopBound<SFTPClientChannelHandler>
    let requestIDs: NIOLockedValueBox<UInt32>

    /// 取号、建 promise、交给 EventLoop 上的 handler。不检查取消（清理路径也用它）。
    func submit(_ build: (UInt32) -> SFTPRequest) -> SFTPInFlightRequest {
        let id = requestIDs.withLockedValue { next in
            defer { next &+= 1 }
            return next
        }
        let request = build(id)
        let promise = channel.eventLoop.makePromise(of: SFTPResponse.self)
        let handler = self.handler
        channel.eventLoop.execute {
            handler.value.enqueue(request, promise: promise)
        }
        return SFTPInFlightRequest(id: id, promise: promise)
    }

    /// 等回答。任务被取消时立刻抛 `CancellationError`，并撤掉 handler 里的记录。
    func wait(_ request: SFTPInFlightRequest) async throws -> SFTPResponse {
        try await withTaskCancellationHandler {
            try await request.promise.futureResult.get()
        } onCancel: {
            abandon(request)
        }
    }

    /// 不再等这个请求了（取消、或者批量读写里前面的请求已经失败）。
    func abandon(_ request: SFTPInFlightRequest) {
        // promise 被完成两次时 NIO 静默忽略第二次：这里先让等的一方走，handler 那边随后再完成也无妨。
        request.promise.fail(CancellationError())
        let handler = self.handler
        let id = request.id
        channel.eventLoop.execute {
            handler.value.forget(id)
        }
    }

    func perform(_ build: (UInt32) -> SFTPRequest) async throws -> SFTPResponse {
        try Task.checkCancellation()
        return try await wait(submit(build))
    }

    /// 发出去不等回答（出错路径上的 CLOSE）。
    func sendDetached(_ build: (UInt32) -> SFTPRequest) {
        _ = submit(build)
    }
}

/// 把回答解释成各个操作期望的形状；形状不对就是 `invalidResponse`，非 OK 状态就是 `status`。
enum SFTPResponseReader {
    static func throwUnexpected(_ response: SFTPResponse, expected: String) throws -> Never {
        if case .status(_, let code, let message, let languageTag) = response {
            throw SFTPError.status(code: code, message: message, languageTag: languageTag)
        }
        throw SFTPError.invalidResponse("expected \(expected), got \(response.packetType)")
    }

    static func ok(_ response: SFTPResponse) throws {
        if case .status(_, let code, _, _) = response, code == .ok { return }
        try throwUnexpected(response, expected: "SSH_FXP_STATUS")
    }

    static func handle(_ response: SFTPResponse) throws -> ByteBuffer {
        if case .handle(_, let handle) = response { return handle }
        try throwUnexpected(response, expected: "SSH_FXP_HANDLE")
    }

    static func attributes(_ response: SFTPResponse) throws -> SFTPFileAttributes {
        if case .attributes(_, let attributes) = response { return attributes }
        try throwUnexpected(response, expected: "SSH_FXP_ATTRS")
    }

    static func singleName(_ response: SFTPResponse) throws -> SFTPDirectoryEntry {
        if case .name(_, let entries) = response {
            guard let first = entries.first else {
                throw SFTPError.invalidResponse("SSH_FXP_NAME with no entries")
            }
            return first
        }
        try throwUnexpected(response, expected: "SSH_FXP_NAME")
    }

    static func extendedReply<T>(_ response: SFTPResponse, as decode: (inout ByteBuffer) -> T?) throws -> T {
        if case .extendedReply(_, var data) = response {
            guard let value = decode(&data) else {
                throw SFTPError.invalidResponse("malformed SSH_FXP_EXTENDED_REPLY")
            }
            return value
        }
        try throwUnexpected(response, expected: "SSH_FXP_EXTENDED_REPLY")
    }

    /// READ 的回答：数据、或 nil（EOF）。数据比要的多是协议错误。
    static func readData(_ response: SFTPResponse, requested: Int) throws -> ByteBuffer? {
        switch response {
        case .data(_, let data):
            guard data.readableBytes <= requested else {
                throw SFTPError.invalidResponse("SSH_FXP_DATA of \(data.readableBytes) bytes for a \(requested)-byte read")
            }
            return data
        case .status(_, let code, _, _) where code == .eof:
            return nil
        default:
            try throwUnexpected(response, expected: "SSH_FXP_DATA")
        }
    }
}
