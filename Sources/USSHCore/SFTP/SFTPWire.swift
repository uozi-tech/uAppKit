import NIOCore

// SFTP v3 的线格式：分帧、报文类型、每种报文的编解码。
//
// 依据 draft-ietf-secsh-filexfer-02 与 OpenSSH 的 PROTOCOL 文档（扩展的格式、SYMLINK 参数顺序）。
// 客户端（本模块）与测试服务端（USSHTestServer）共用这一份，所以是 `package` 可见：
// 线上的报文类型不是公开 API，调用方只经 `SFTPClient` / `SFTPFile` 使用。
//
// 解码一律不 trap：长度、计数、字符串都先核对剩余字节，缺了就抛 `SFTPWireError`。

// MARK: - 报文类型

package enum SFTPPacketType: UInt8, Hashable, Sendable {
    case initialize = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case setstat = 9
    case fsetstat = 10
    case opendir = 11
    case readdir = 12
    case remove = 13
    case mkdir = 14
    case rmdir = 15
    case realpath = 16
    case stat = 17
    case rename = 18
    case readlink = 19
    case symlink = 20
    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attributes = 105
    case extended = 200
    case extendedReply = 201
}

package enum SFTPWireError: Error, Hashable, Sendable, CustomStringConvertible {
    /// 帧长度字段为 0（至少要有 1 字节的类型）。
    case emptyPacket
    /// 帧长度超过本端允许的上限。
    case packetTooLarge(length: UInt32, limit: Int)
    /// 报文体比它的类型要求的短。
    case truncated(type: UInt8)
    /// 不认识的报文类型；能读出请求号时带上（服务端据此回 OP_UNSUPPORTED）。
    case unknownPacketType(UInt8, requestID: UInt32?)
    /// 出现在错误方向上的类型（例如客户端收到了 OPEN）。
    case unexpectedPacketType(UInt8)

    package var description: String {
        switch self {
        case .emptyPacket: return "empty SFTP packet"
        case .packetTooLarge(let length, let limit): return "SFTP packet of \(length) bytes exceeds \(limit)"
        case .truncated(let type): return "truncated SFTP packet of type \(type)"
        case .unknownPacketType(let type, _): return "unknown SFTP packet type \(type)"
        case .unexpectedPacketType(let type): return "unexpected SFTP packet type \(type)"
        }
    }
}

/// SSH_FXP_VERSION / SSH_FXP_INIT 里的扩展对。
package struct SFTPWireExtension: Hashable, Sendable {
    package var name: String
    package var data: String

    package init(name: String, data: String) {
        self.name = name
        self.data = data
    }
}

// MARK: - 基础字段

extension ByteBuffer {
    /// SSH string（`uint32` 长度 + 字节），以切片返回，不拷贝。
    mutating func readSFTPBytes() -> ByteBuffer? {
        guard let length = getInteger(at: readerIndex, as: UInt32.self),
              UInt64(length) <= UInt64(readableBytes - 4)
        else { return nil }
        moveReaderIndex(forwardBy: 4)
        return readSlice(length: Int(length))
    }

    /// SSH string 按 UTF-8 解成 `String`（非法序列按 Unicode 规则替换，不失败）。
    mutating func readSFTPString() -> String? {
        readSFTPBytes().map { String(buffer: $0) }
    }

    /// 路径 / 文件名：原样的字节（拷出来，不留着整块接收缓冲）。
    mutating func readSFTPPath() -> SFTPPath? {
        readSFTPBytes().map { SFTPPath(bytes: $0.readableBytesView) }
    }

    mutating func writeSFTPPath(_ path: SFTPPath) {
        writeInteger(UInt32(truncatingIfNeeded: path.bytes.count))
        writeBytes(path.bytes)
    }

    mutating func writeSFTPString(_ string: String) {
        writeInteger(UInt32(truncatingIfNeeded: string.utf8.count))
        writeString(string)
    }

    mutating func writeSFTPBytes(_ bytes: ByteBuffer) {
        writeInteger(UInt32(truncatingIfNeeded: bytes.readableBytes))
        writeImmutableBuffer(bytes)
    }
}

// MARK: - ATTRS

extension SFTPFileAttributes {
    package static let sizeFlag: UInt32 = 0x0000_0001
    package static let ownerFlag: UInt32 = 0x0000_0002
    package static let permissionsFlag: UInt32 = 0x0000_0004
    package static let timesFlag: UInt32 = 0x0000_0008
    package static let extendedFlag: UInt32 = 0x8000_0000

    package func encode(into buffer: inout ByteBuffer) {
        var flags: UInt32 = 0
        if size != nil { flags |= Self.sizeFlag }
        if owner != nil { flags |= Self.ownerFlag }
        if permissions != nil { flags |= Self.permissionsFlag }
        if times != nil { flags |= Self.timesFlag }
        if !extended.isEmpty { flags |= Self.extendedFlag }
        buffer.writeInteger(flags)
        if let size { buffer.writeInteger(size) }
        if let owner {
            buffer.writeInteger(owner.userID)
            buffer.writeInteger(owner.groupID)
        }
        if let permissions { buffer.writeInteger(permissions) }
        if let times {
            buffer.writeInteger(times.accessSeconds)
            buffer.writeInteger(times.modificationSeconds)
        }
        if !extended.isEmpty {
            buffer.writeInteger(UInt32(truncatingIfNeeded: extended.count))
            for pair in extended {
                buffer.writeSFTPString(pair.name)
                buffer.writeSFTPBytes(pair.data)
            }
        }
    }

    /// 读一组 ATTRS。不认识的标志位照 OpenSSH 的做法忽略（v3 之外的位没有已知长度，后面的字段无从解析，
    /// 但 v3 服务端不会发）。
    package static func decode(from buffer: inout ByteBuffer) -> SFTPFileAttributes? {
        guard let flags = buffer.readInteger(as: UInt32.self) else { return nil }
        var attributes = SFTPFileAttributes()
        if flags & sizeFlag != 0 {
            guard let size = buffer.readInteger(as: UInt64.self) else { return nil }
            attributes.size = size
        }
        if flags & ownerFlag != 0 {
            guard let uid = buffer.readInteger(as: UInt32.self),
                  let gid = buffer.readInteger(as: UInt32.self) else { return nil }
            attributes.owner = SFTPFileOwner(userID: uid, groupID: gid)
        }
        if flags & permissionsFlag != 0 {
            guard let permissions = buffer.readInteger(as: UInt32.self) else { return nil }
            attributes.permissions = permissions
        }
        if flags & timesFlag != 0 {
            guard let atime = buffer.readInteger(as: UInt32.self),
                  let mtime = buffer.readInteger(as: UInt32.self) else { return nil }
            attributes.times = SFTPFileTimes(accessSeconds: atime, modificationSeconds: mtime)
        }
        if flags & extendedFlag != 0 {
            guard let count = buffer.readInteger(as: UInt32.self) else { return nil }
            // 计数来自网络，不按它预留容量；每对至少 8 字节，读不出来就失败，循环必然有界。
            for _ in 0..<count {
                guard let name = buffer.readSFTPString(), let data = buffer.readSFTPBytes() else { return nil }
                attributes.extended.append(SFTPExtendedAttribute(name: name, data: data))
            }
        }
        return attributes
    }
}

// MARK: - 扩展的回答体

extension SFTPFileSystemStats {
    package func encode(into buffer: inout ByteBuffer) {
        for value in [blockSize, fragmentSize, totalBlocks, freeBlocks, availableBlocks, totalInodes,
                      freeInodes, availableInodes, fileSystemID, flags, maximumNameLength] {
            buffer.writeInteger(value)
        }
    }

    package static func decode(from buffer: inout ByteBuffer) -> SFTPFileSystemStats? {
        guard buffer.readableBytes >= 11 * 8 else { return nil }
        var values: [UInt64] = []
        values.reserveCapacity(11)
        for _ in 0..<11 { values.append(buffer.readInteger(as: UInt64.self)!) }
        return SFTPFileSystemStats(
            blockSize: values[0], fragmentSize: values[1], totalBlocks: values[2], freeBlocks: values[3],
            availableBlocks: values[4], totalInodes: values[5], freeInodes: values[6], availableInodes: values[7],
            fileSystemID: values[8], flags: values[9], maximumNameLength: values[10])
    }
}

extension SFTPServerLimits {
    package func encode(into buffer: inout ByteBuffer) {
        buffer.writeInteger(maximumPacketLength)
        buffer.writeInteger(maximumReadLength)
        buffer.writeInteger(maximumWriteLength)
        buffer.writeInteger(maximumOpenHandles)
    }

    package static func decode(from buffer: inout ByteBuffer) -> SFTPServerLimits? {
        guard let packet = buffer.readInteger(as: UInt64.self),
              let read = buffer.readInteger(as: UInt64.self),
              let write = buffer.readInteger(as: UInt64.self),
              let handles = buffer.readInteger(as: UInt64.self) else { return nil }
        return SFTPServerLimits(maximumPacketLength: packet, maximumReadLength: read,
                                maximumWriteLength: write, maximumOpenHandles: handles)
    }
}

// MARK: - 帧

/// 帧的写入：先占 4 字节长度，写完报文体再回填。
private struct SFTPFrameWriter {
    let lengthIndex: Int

    init(_ buffer: inout ByteBuffer, type: SFTPPacketType) {
        lengthIndex = buffer.writerIndex
        buffer.writeInteger(UInt32(0))
        buffer.writeInteger(type.rawValue)
    }

    /// `trailing`：紧跟在这一帧后面、由调用方另行写出的字节数（大块数据不拷进头部）。
    func finish(_ buffer: inout ByteBuffer, trailing: Int = 0) {
        let length = buffer.writerIndex - lengthIndex - 4 + trailing
        buffer.setInteger(UInt32(truncatingIfNeeded: length), at: lengthIndex)
    }
}

/// 把字节流切成一帧帧的报文体（类型字节 + 内容，不含长度字段），以切片返回、不拷贝。
package struct SFTPFrameDecoder: NIOSingleStepByteToMessageDecoder {
    package typealias InboundOut = ByteBuffer

    package let maximumFrameLength: Int

    package init(maximumFrameLength: Int) {
        self.maximumFrameLength = maximumFrameLength
    }

    package mutating func decode(buffer: inout ByteBuffer) throws -> ByteBuffer? {
        guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self) else { return nil }
        guard length > 0 else { throw SFTPWireError.emptyPacket }
        guard UInt64(length) <= UInt64(maximumFrameLength) else {
            throw SFTPWireError.packetTooLarge(length: length, limit: maximumFrameLength)
        }
        guard buffer.readableBytes - 4 >= Int(length) else { return nil }
        buffer.moveReaderIndex(forwardBy: 4)
        return buffer.readSlice(length: Int(length))
    }

    package mutating func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> ByteBuffer? {
        try decode(buffer: &buffer)
    }
}

// MARK: - 扩展请求

package enum SFTPExtendedRequest: Hashable, Sendable {
    case posixRename(oldPath: SFTPPath, newPath: SFTPPath)
    case statVFS(path: SFTPPath)
    case fstatVFS(handle: ByteBuffer)
    case hardLink(oldPath: SFTPPath, newPath: SFTPPath)
    case fsync(handle: ByteBuffer)
    case lsetstat(path: SFTPPath, attributes: SFTPFileAttributes)
    case limits
    case other(name: String, data: ByteBuffer)

    package var name: String {
        switch self {
        case .posixRename: return SFTPExtensionName.posixRename
        case .statVFS: return SFTPExtensionName.statVFS
        case .fstatVFS: return SFTPExtensionName.fstatVFS
        case .hardLink: return SFTPExtensionName.hardLink
        case .fsync: return SFTPExtensionName.fsync
        case .lsetstat: return SFTPExtensionName.lsetstat
        case .limits: return SFTPExtensionName.limits
        case .other(let name, _): return name
        }
    }

    fileprivate func encodeBody(into buffer: inout ByteBuffer) {
        buffer.writeSFTPString(name)
        switch self {
        case .posixRename(let oldPath, let newPath), .hardLink(let oldPath, let newPath):
            buffer.writeSFTPPath(oldPath)
            buffer.writeSFTPPath(newPath)
        case .statVFS(let path):
            buffer.writeSFTPPath(path)
        case .fstatVFS(let handle), .fsync(let handle):
            buffer.writeSFTPBytes(handle)
        case .lsetstat(let path, let attributes):
            buffer.writeSFTPPath(path)
            attributes.encode(into: &buffer)
        case .limits:
            break
        case .other(_, let data):
            buffer.writeImmutableBuffer(data)
        }
    }

    fileprivate static func decodeBody(from buffer: inout ByteBuffer) -> SFTPExtendedRequest? {
        guard let name = buffer.readSFTPString() else { return nil }
        switch name {
        case SFTPExtensionName.posixRename:
            guard let old = buffer.readSFTPPath(), let new = buffer.readSFTPPath() else { return nil }
            return .posixRename(oldPath: old, newPath: new)
        case SFTPExtensionName.hardLink:
            guard let old = buffer.readSFTPPath(), let new = buffer.readSFTPPath() else { return nil }
            return .hardLink(oldPath: old, newPath: new)
        case SFTPExtensionName.statVFS:
            guard let path = buffer.readSFTPPath() else { return nil }
            return .statVFS(path: path)
        case SFTPExtensionName.fstatVFS:
            guard let handle = buffer.readSFTPBytes() else { return nil }
            return .fstatVFS(handle: handle)
        case SFTPExtensionName.fsync:
            guard let handle = buffer.readSFTPBytes() else { return nil }
            return .fsync(handle: handle)
        case SFTPExtensionName.lsetstat:
            guard let path = buffer.readSFTPPath(),
                  let attributes = SFTPFileAttributes.decode(from: &buffer) else { return nil }
            return .lsetstat(path: path, attributes: attributes)
        case SFTPExtensionName.limits:
            return .limits
        default:
            let rest = buffer.readSlice(length: buffer.readableBytes) ?? ByteBuffer()
            return .other(name: name, data: rest)
        }
    }
}

// MARK: - 客户端 → 服务端

package enum SFTPRequest: Hashable, Sendable {
    case initialize(version: UInt32, extensions: [SFTPWireExtension])
    case open(id: UInt32, path: SFTPPath, flags: SFTPOpenFlags, attributes: SFTPFileAttributes)
    case close(id: UInt32, handle: ByteBuffer)
    case read(id: UInt32, handle: ByteBuffer, offset: UInt64, length: UInt32)
    case write(id: UInt32, handle: ByteBuffer, offset: UInt64, data: ByteBuffer)
    case lstat(id: UInt32, path: SFTPPath)
    case fstat(id: UInt32, handle: ByteBuffer)
    case setstat(id: UInt32, path: SFTPPath, attributes: SFTPFileAttributes)
    case fsetstat(id: UInt32, handle: ByteBuffer, attributes: SFTPFileAttributes)
    case opendir(id: UInt32, path: SFTPPath)
    case readdir(id: UInt32, handle: ByteBuffer)
    case remove(id: UInt32, path: SFTPPath)
    case mkdir(id: UInt32, path: SFTPPath, attributes: SFTPFileAttributes)
    case rmdir(id: UInt32, path: SFTPPath)
    case realpath(id: UInt32, path: SFTPPath)
    case stat(id: UInt32, path: SFTPPath)
    case rename(id: UInt32, oldPath: SFTPPath, newPath: SFTPPath)
    case readlink(id: UInt32, path: SFTPPath)
    /// 在 `linkPath` 建一个指向 `targetPath` 的符号链接。
    ///
    /// ⚠️ 线上的参数顺序照 OpenSSH：**先 target、后 link**。草案写的是反的，但 OpenSSH 的
    /// sftp-server 从一开始就实现反了、而且为了兼容永远不改（见 OpenSSH 的 PROTOCOL §4.1），
    /// 事实上的服务端都跟它走。
    case symlink(id: UInt32, linkPath: SFTPPath, targetPath: SFTPPath)
    case extended(id: UInt32, request: SFTPExtendedRequest)

    package var packetType: SFTPPacketType {
        switch self {
        case .initialize: return .initialize
        case .open: return .open
        case .close: return .close
        case .read: return .read
        case .write: return .write
        case .lstat: return .lstat
        case .fstat: return .fstat
        case .setstat: return .setstat
        case .fsetstat: return .fsetstat
        case .opendir: return .opendir
        case .readdir: return .readdir
        case .remove: return .remove
        case .mkdir: return .mkdir
        case .rmdir: return .rmdir
        case .realpath: return .realpath
        case .stat: return .stat
        case .rename: return .rename
        case .readlink: return .readlink
        case .symlink: return .symlink
        case .extended: return .extended
        }
    }

    /// 请求号；INIT 没有。
    package var requestID: UInt32? {
        switch self {
        case .initialize: return nil
        case .open(let id, _, _, _), .close(let id, _), .read(let id, _, _, _), .write(let id, _, _, _),
             .lstat(let id, _), .fstat(let id, _), .setstat(let id, _, _), .fsetstat(let id, _, _),
             .opendir(let id, _), .readdir(let id, _), .remove(let id, _), .mkdir(let id, _, _),
             .rmdir(let id, _), .realpath(let id, _), .stat(let id, _), .rename(let id, _, _),
             .readlink(let id, _), .symlink(let id, _, _), .extended(let id, _):
            return id
        }
    }

    /// 写出整帧，但 WRITE 的数据不拷进 `buffer`：作为返回值交给调用方紧跟着写出（长度字段已经算上它）。
    package func encodeHeader(into buffer: inout ByteBuffer) -> ByteBuffer? {
        let frame = SFTPFrameWriter(&buffer, type: packetType)
        var trailing: ByteBuffer?
        switch self {
        case .initialize(let version, let extensions):
            buffer.writeInteger(version)
            for pair in extensions {
                buffer.writeSFTPString(pair.name)
                buffer.writeSFTPString(pair.data)
            }
        case .open(let id, let path, let flags, let attributes):
            buffer.writeInteger(id)
            buffer.writeSFTPPath(path)
            buffer.writeInteger(flags.rawValue)
            attributes.encode(into: &buffer)
        case .close(let id, let handle), .fstat(let id, let handle), .readdir(let id, let handle):
            buffer.writeInteger(id)
            buffer.writeSFTPBytes(handle)
        case .read(let id, let handle, let offset, let length):
            buffer.writeInteger(id)
            buffer.writeSFTPBytes(handle)
            buffer.writeInteger(offset)
            buffer.writeInteger(length)
        case .write(let id, let handle, let offset, let data):
            buffer.writeInteger(id)
            buffer.writeSFTPBytes(handle)
            buffer.writeInteger(offset)
            buffer.writeInteger(UInt32(truncatingIfNeeded: data.readableBytes))
            trailing = data
        case .lstat(let id, let path), .opendir(let id, let path), .remove(let id, let path),
             .rmdir(let id, let path), .realpath(let id, let path), .stat(let id, let path),
             .readlink(let id, let path):
            buffer.writeInteger(id)
            buffer.writeSFTPPath(path)
        case .setstat(let id, let path, let attributes), .mkdir(let id, let path, let attributes):
            buffer.writeInteger(id)
            buffer.writeSFTPPath(path)
            attributes.encode(into: &buffer)
        case .fsetstat(let id, let handle, let attributes):
            buffer.writeInteger(id)
            buffer.writeSFTPBytes(handle)
            attributes.encode(into: &buffer)
        case .rename(let id, let oldPath, let newPath):
            buffer.writeInteger(id)
            buffer.writeSFTPPath(oldPath)
            buffer.writeSFTPPath(newPath)
        case .symlink(let id, let linkPath, let targetPath):
            buffer.writeInteger(id)
            buffer.writeSFTPPath(targetPath)
            buffer.writeSFTPPath(linkPath)
        case .extended(let id, let request):
            buffer.writeInteger(id)
            request.encodeBody(into: &buffer)
        }
        frame.finish(&buffer, trailing: trailing?.readableBytes ?? 0)
        return trailing
    }

    /// 写出完整的一帧（含 WRITE 的数据）。
    package func encode(into buffer: inout ByteBuffer) {
        if let trailing = encodeHeader(into: &buffer) {
            buffer.writeImmutableBuffer(trailing)
        }
    }

    /// 解一帧报文体（`SFTPFrameDecoder` 的产物：类型字节 + 内容）。
    package static func decode(frame: ByteBuffer) throws -> SFTPRequest {
        var body = frame
        guard let rawType = body.readInteger(as: UInt8.self) else { throw SFTPWireError.emptyPacket }
        guard let type = SFTPPacketType(rawValue: rawType) else {
            throw SFTPWireError.unknownPacketType(rawType, requestID: body.getInteger(at: body.readerIndex, as: UInt32.self))
        }
        let truncated = SFTPWireError.truncated(type: rawType)
        if type == .initialize {
            guard let version = body.readInteger(as: UInt32.self) else { throw truncated }
            return .initialize(version: version, extensions: try decodeExtensions(&body, type: rawType))
        }
        switch type {
        case .version, .status, .handle, .data, .name, .attributes, .extendedReply:
            throw SFTPWireError.unexpectedPacketType(rawType)
        default:
            break
        }
        guard let id = body.readInteger(as: UInt32.self) else { throw truncated }
        func path() throws -> SFTPPath {
            guard let value = body.readSFTPPath() else { throw truncated }
            return value
        }
        func bytes() throws -> ByteBuffer {
            guard let value = body.readSFTPBytes() else { throw truncated }
            return value
        }
        func attributes() throws -> SFTPFileAttributes {
            guard let value = SFTPFileAttributes.decode(from: &body) else { throw truncated }
            return value
        }
        func uint64() throws -> UInt64 {
            guard let value = body.readInteger(as: UInt64.self) else { throw truncated }
            return value
        }
        func uint32() throws -> UInt32 {
            guard let value = body.readInteger(as: UInt32.self) else { throw truncated }
            return value
        }
        switch type {
        case .open:
            let path = try path()
            let flags = SFTPOpenFlags(rawValue: try uint32())
            return .open(id: id, path: path, flags: flags, attributes: try attributes())
        case .close: return .close(id: id, handle: try bytes())
        case .read:
            let handle = try bytes()
            let offset = try uint64()
            return .read(id: id, handle: handle, offset: offset, length: try uint32())
        case .write:
            let handle = try bytes()
            let offset = try uint64()
            return .write(id: id, handle: handle, offset: offset, data: try bytes())
        case .lstat: return .lstat(id: id, path: try path())
        case .fstat: return .fstat(id: id, handle: try bytes())
        case .setstat:
            let path = try path()
            return .setstat(id: id, path: path, attributes: try attributes())
        case .fsetstat:
            let handle = try bytes()
            return .fsetstat(id: id, handle: handle, attributes: try attributes())
        case .opendir: return .opendir(id: id, path: try path())
        case .readdir: return .readdir(id: id, handle: try bytes())
        case .remove: return .remove(id: id, path: try path())
        case .mkdir:
            let path = try path()
            return .mkdir(id: id, path: path, attributes: try attributes())
        case .rmdir: return .rmdir(id: id, path: try path())
        case .realpath: return .realpath(id: id, path: try path())
        case .stat: return .stat(id: id, path: try path())
        case .rename:
            let old = try path()
            return .rename(id: id, oldPath: old, newPath: try path())
        case .readlink: return .readlink(id: id, path: try path())
        case .symlink:
            let target = try path()
            return .symlink(id: id, linkPath: try path(), targetPath: target)
        case .extended:
            guard let request = SFTPExtendedRequest.decodeBody(from: &body) else { throw truncated }
            return .extended(id: id, request: request)
        case .initialize, .version, .status, .handle, .data, .name, .attributes, .extendedReply:
            throw SFTPWireError.unexpectedPacketType(rawType)
        }
    }
}

private func decodeExtensions(_ body: inout ByteBuffer, type: UInt8) throws -> [SFTPWireExtension] {
    var extensions: [SFTPWireExtension] = []
    while body.readableBytes > 0 {
        guard let name = body.readSFTPString(), let data = body.readSFTPString() else {
            throw SFTPWireError.truncated(type: type)
        }
        extensions.append(SFTPWireExtension(name: name, data: data))
    }
    return extensions
}

// MARK: - 服务端 → 客户端

package enum SFTPResponse: Hashable, Sendable {
    case version(version: UInt32, extensions: [SFTPWireExtension])
    case status(id: UInt32, code: SFTPStatusCode, message: String, languageTag: String)
    case handle(id: UInt32, handle: ByteBuffer)
    case data(id: UInt32, data: ByteBuffer)
    case name(id: UInt32, entries: [SFTPDirectoryEntry])
    case attributes(id: UInt32, attributes: SFTPFileAttributes)
    case extendedReply(id: UInt32, data: ByteBuffer)

    package var packetType: SFTPPacketType {
        switch self {
        case .version: return .version
        case .status: return .status
        case .handle: return .handle
        case .data: return .data
        case .name: return .name
        case .attributes: return .attributes
        case .extendedReply: return .extendedReply
        }
    }

    package var requestID: UInt32? {
        switch self {
        case .version: return nil
        case .status(let id, _, _, _), .handle(let id, _), .data(let id, _), .name(let id, _),
             .attributes(let id, _), .extendedReply(let id, _):
            return id
        }
    }

    /// 同 `SFTPRequest.encodeHeader`：DATA 的数据不拷进 `buffer`，作为返回值交给调用方紧跟着写出。
    package func encodeHeader(into buffer: inout ByteBuffer) -> ByteBuffer? {
        let frame = SFTPFrameWriter(&buffer, type: packetType)
        var trailing: ByteBuffer?
        switch self {
        case .version(let version, let extensions):
            buffer.writeInteger(version)
            for pair in extensions {
                buffer.writeSFTPString(pair.name)
                buffer.writeSFTPString(pair.data)
            }
        case .status(let id, let code, let message, let languageTag):
            buffer.writeInteger(id)
            buffer.writeInteger(code.rawValue)
            buffer.writeSFTPString(message)
            buffer.writeSFTPString(languageTag)
        case .handle(let id, let handle):
            buffer.writeInteger(id)
            buffer.writeSFTPBytes(handle)
        case .data(let id, let data):
            buffer.writeInteger(id)
            buffer.writeInteger(UInt32(truncatingIfNeeded: data.readableBytes))
            trailing = data
        case .name(let id, let entries):
            buffer.writeInteger(id)
            buffer.writeInteger(UInt32(truncatingIfNeeded: entries.count))
            for entry in entries {
                buffer.writeSFTPPath(entry.name)
                buffer.writeSFTPString(entry.longname)
                entry.attributes.encode(into: &buffer)
            }
        case .attributes(let id, let attributes):
            buffer.writeInteger(id)
            attributes.encode(into: &buffer)
        case .extendedReply(let id, let data):
            buffer.writeInteger(id)
            buffer.writeImmutableBuffer(data)
        }
        frame.finish(&buffer, trailing: trailing?.readableBytes ?? 0)
        return trailing
    }

    package func encode(into buffer: inout ByteBuffer) {
        if let trailing = encodeHeader(into: &buffer) {
            buffer.writeImmutableBuffer(trailing)
        }
    }

    package static func decode(frame: ByteBuffer) throws -> SFTPResponse {
        var body = frame
        guard let rawType = body.readInteger(as: UInt8.self) else { throw SFTPWireError.emptyPacket }
        guard let type = SFTPPacketType(rawValue: rawType) else {
            throw SFTPWireError.unknownPacketType(rawType, requestID: body.getInteger(at: body.readerIndex, as: UInt32.self))
        }
        let truncated = SFTPWireError.truncated(type: rawType)
        if type == .version {
            guard let version = body.readInteger(as: UInt32.self) else { throw truncated }
            return .version(version: version, extensions: try decodeExtensions(&body, type: rawType))
        }
        switch type {
        case .status, .handle, .data, .name, .attributes, .extendedReply: break
        default: throw SFTPWireError.unexpectedPacketType(rawType)
        }
        guard let id = body.readInteger(as: UInt32.self) else { throw truncated }
        switch type {
        case .status:
            guard let code = body.readInteger(as: UInt32.self) else { throw truncated }
            // 草案 -02 才加上文案与语言；更老的服务端只回状态码，按空串处理。
            let message = body.readSFTPString() ?? ""
            let languageTag = body.readSFTPString() ?? ""
            return .status(id: id, code: SFTPStatusCode(code), message: message, languageTag: languageTag)
        case .handle:
            guard let handle = body.readSFTPBytes() else { throw truncated }
            return .handle(id: id, handle: handle)
        case .data:
            guard let data = body.readSFTPBytes() else { throw truncated }
            return .data(id: id, data: data)
        case .name:
            guard let count = body.readInteger(as: UInt32.self) else { throw truncated }
            // 每项至少 12 字节（两个空串 + 4 字节标志）；计数来自网络，按剩余字节封顶后再预留。
            var entries: [SFTPDirectoryEntry] = []
            entries.reserveCapacity(min(Int(count), body.readableBytes / 12))
            for _ in 0..<count {
                guard let name = body.readSFTPPath(),
                      let longname = body.readSFTPString(),
                      let attributes = SFTPFileAttributes.decode(from: &body) else { throw truncated }
                entries.append(SFTPDirectoryEntry(name: name, longname: longname, attributes: attributes))
            }
            return .name(id: id, entries: entries)
        case .attributes:
            guard let attributes = SFTPFileAttributes.decode(from: &body) else { throw truncated }
            return .attributes(id: id, attributes: attributes)
        case .extendedReply:
            return .extendedReply(id: id, data: body.readSlice(length: body.readableBytes) ?? ByteBuffer())
        default:
            throw SFTPWireError.unexpectedPacketType(rawType)
        }
    }
}
