// 只给 Apple 平台的测试用（系统调用写的是 Darwin 的形状）。
#if canImport(Darwin)
import Darwin
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import USSHCore

/// 背后是一个真实目录的 `SFTPServerFileSystem`：客户端看到的 `/` 就是这个目录。
///
/// **路径限制**：客户端的路径先按字面规范化（`.`、`..` 到 `/` 为止，相对路径从 `/` 算起），再映射到根目录下；
/// 会跟随符号链接的操作还要核对解析后的真实路径仍在根目录里，跳出去的一律回 SSH_FX_PERMISSION_DENIED。
/// 建符号链接时，以 `/` 开头的目标按客户端视角解释（存成根目录下的真实路径，`readLink` 时再换回来）。
///
/// 错误码照 OpenSSH 的 `errno_to_portable`。适合测试：不防 TOCTOU。
public struct SFTPLocalFileSystem: SFTPServerFileSystem {
    /// 根目录的真实路径（已解析符号链接，例如 `/var` → `/private/var`）。
    public let rootPath: String
    /// 一次 READDIR 最多回多少项。
    public var directoryBatchSize: Int

    public init(root: URL, directoryBatchSize: Int = 100) throws {
        guard let resolved = Self.canonical(root.path) else {
            throw SFTPServerStatusError.noSuchFile("root \(root.path) does not exist")
        }
        self.rootPath = resolved
        self.directoryBatchSize = max(1, directoryBatchSize)
    }

    /// 在系统临时目录里新建一个空目录当根。用完调 `removeRoot()`。
    public static func makeTemporary(prefix: String = "usshcore-sftp") throws -> SFTPLocalFileSystem {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try SFTPLocalFileSystem(root: url)
    }

    public var rootURL: URL { URL(fileURLWithPath: rootPath, isDirectory: true) }

    /// 删掉整个根目录。
    public func removeRoot() throws {
        try FileManager.default.removeItem(atPath: rootPath)
    }

    /// 客户端路径对应的真实路径（只做字面映射，不核对符号链接）。测试里用来直接检查磁盘上的结果。
    public func hostPath(for path: SFTPPath) -> String {
        hostPath(for: path.string)
    }

    public func hostPath(for path: String) -> String {
        let normalized = Self.normalize(path)
        return normalized == "/" ? rootPath : rootPath + normalized
    }

    // MARK: - 路径

    /// 字面规范化成以 `/` 开头、没有 `.` / `..` / 重复斜杠的路径；`..` 到根为止。
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(component)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func canonical(_ path: String) -> String? {
        guard let pointer = Darwin.realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private func isInsideRoot(_ hostPath: String) -> Bool {
        hostPath == rootPath || hostPath.hasPrefix(rootPath + "/")
    }

    /// 映射到真实路径并核对限制。`followingFinal`：最后一段若是符号链接，是否要跟随（核对它的目标）。
    private func confined(_ path: String, followingFinal: Bool) throws -> String {
        let host = hostPath(for: path)
        var info = Darwin.stat()
        let exists = lstat(host, &info) == 0
        if exists && followingFinal {
            // 跟随整条路径；悬空的链接解析不出来，交给后面的系统调用去报 ENOENT。
            if let resolved = Self.canonical(host) {
                guard isInsideRoot(resolved) else { throw SFTPServerStatusError.permissionDenied("path escapes root") }
                return host
            }
        }
        // 不跟随最后一段：只核对它所在的目录。
        let parent = (host as NSString).deletingLastPathComponent
        if let resolvedParent = Self.canonical(parent), !isInsideRoot(resolvedParent) {
            throw SFTPServerStatusError.permissionDenied("path escapes root")
        }
        return host
    }

    private func virtualPath(forHost host: String) -> String? {
        if host == rootPath { return "/" }
        guard host.hasPrefix(rootPath + "/") else { return nil }
        return String(host.dropFirst(rootPath.count))
    }

    /// 这台机器的文件系统（APFS）只收合法 UTF-8 的名字；别的名字照系统的做法拒绝（EILSEQ → SSH_FX_FAILURE）。
    /// 要测非 UTF-8 名字，换一个自己实现的 `SFTPServerFileSystem`。
    static func text(_ path: SFTPPath) throws -> String {
        guard path.isLosslessUTF8, !path.bytes.contains(0) else { throw error(EILSEQ) }
        return path.string
    }

    // MARK: - 错误

    static func error(_ code: Int32 = errno) -> SFTPServerStatusError {
        let message = String(cString: strerror(code))
        switch code {
        case ENOENT, ENOTDIR, EBADF, ELOOP: return SFTPServerStatusError(.noSuchFile, message)
        case EPERM, EACCES, EFAULT: return SFTPServerStatusError(.permissionDenied, message)
        case ENAMETOOLONG, EINVAL: return SFTPServerStatusError(.badMessage, message)
        case ENOSYS: return SFTPServerStatusError(.operationUnsupported, message)
        default: return SFTPServerStatusError(.failure, message)
        }
    }

    private static func check(_ result: Int32) throws {
        if result != 0 { throw error() }
    }

    // MARK: - 属性

    static func attributes(from info: Darwin.stat) -> SFTPFileAttributes {
        SFTPFileAttributes(
            size: UInt64(clamping: info.st_size),
            owner: SFTPFileOwner(userID: info.st_uid, groupID: info.st_gid),
            permissions: UInt32(info.st_mode),
            times: SFTPFileTimes(accessSeconds: UInt32(clamping: info.st_atimespec.tv_sec),
                                 modificationSeconds: UInt32(clamping: info.st_mtimespec.tv_sec)))
    }

    static func stats(from info: statvfs) -> SFTPFileSystemStats {
        SFTPFileSystemStats(
            blockSize: UInt64(info.f_bsize), fragmentSize: UInt64(info.f_frsize),
            totalBlocks: UInt64(info.f_blocks), freeBlocks: UInt64(info.f_bfree),
            availableBlocks: UInt64(info.f_bavail), totalInodes: UInt64(info.f_files),
            freeInodes: UInt64(info.f_ffree), availableInodes: UInt64(info.f_favail),
            fileSystemID: UInt64(info.f_fsid), flags: UInt64(info.f_flag),
            maximumNameLength: UInt64(info.f_namemax))
    }

    /// `ls -l` 风格的一行，格式照 OpenSSH 的 `ls_file`（只用于显示）。
    static func longname(_ name: String, _ info: Darwin.stat) -> String {
        let mode = UInt32(info.st_mode)
        let type: Character
        switch SFTPFileType(permissions: mode) {
        case .directory: type = "d"
        case .symbolicLink: type = "l"
        case .characterDevice: type = "c"
        case .blockDevice: type = "b"
        case .fifo: type = "p"
        case .socket: type = "s"
        default: type = "-"
        }
        var bits = String(type)
        for (index, char) in "rwxrwxrwx".enumerated() {
            bits.append(mode & (0o400 >> UInt32(index)) != 0 ? char : "-")
        }
        let date = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm"
        return "\(bits) \(String(info.st_nlink).leftPadded(3)) \(String(info.st_uid).rightPadded(8)) \(String(info.st_gid).rightPadded(8)) \(String(info.st_size).leftPadded(8)) \(formatter.string(from: date)) \(name)"
    }

    private func apply(_ attributes: SFTPFileAttributes, toHost host: String, followingSymlinks: Bool) throws {
        if let size = attributes.size {
            try Self.check(truncate(host, off_t(clamping: size)))
        }
        if let permissions = attributes.permissions {
            let mode = mode_t(permissions & 0o7777)
            try Self.check(followingSymlinks ? chmod(host, mode) : lchmod(host, mode))
        }
        if let owner = attributes.owner {
            try Self.check(followingSymlinks ? chown(host, owner.userID, owner.groupID) : lchown(host, owner.userID, owner.groupID))
        }
        if let times = attributes.times {
            var values = [timeval(tv_sec: Int(times.accessSeconds), tv_usec: 0),
                          timeval(tv_sec: Int(times.modificationSeconds), tv_usec: 0)]
            try Self.check(followingSymlinks ? utimes(host, &values) : lutimes(host, &values))
        }
    }

    // MARK: - SFTPServerFileSystem

    public func realPath(_ path: SFTPPath) async throws -> SFTPPath {
        let path = try Self.text(path)
        let host = try confined(path, followingFinal: true)
        guard let resolved = Self.canonical(host) else { throw Self.error() }
        guard let virtual = virtualPath(forHost: resolved) else {
            throw SFTPServerStatusError.permissionDenied("path escapes root")
        }
        return SFTPPath(virtual)
    }

    public func attributes(at path: SFTPPath, followingSymlinks: Bool) async throws -> SFTPFileAttributes {
        let path = try Self.text(path)
        let host = try confined(path, followingFinal: followingSymlinks)
        var info = Darwin.stat()
        try Self.check(followingSymlinks ? stat(host, &info) : lstat(host, &info))
        return Self.attributes(from: info)
    }

    public func setAttributes(_ attributes: SFTPFileAttributes, at path: SFTPPath, followingSymlinks: Bool) async throws {
        let path = try Self.text(path)
        let host = try confined(path, followingFinal: followingSymlinks)
        try apply(attributes, toHost: host, followingSymlinks: followingSymlinks)
    }

    public func openFile(_ path: SFTPPath, flags: SFTPOpenFlags, attributes: SFTPFileAttributes) async throws -> any SFTPServerFile {
        let path = try Self.text(path)
        let host = try confined(path, followingFinal: true)
        var oflags: Int32
        switch (flags.contains(.read), flags.contains(.write)) {
        case (true, true): oflags = O_RDWR
        case (false, true): oflags = O_WRONLY
        default: oflags = O_RDONLY
        }
        if flags.contains(.append) { oflags |= O_APPEND }
        if flags.contains(.create) { oflags |= O_CREAT }
        if flags.contains(.truncate) { oflags |= O_TRUNC }
        if flags.contains(.exclusive) { oflags |= O_EXCL }
        let mode = mode_t(attributes.permissions.map { $0 & 0o7777 } ?? 0o666)
        let fd = open(host, oflags, mode)
        guard fd >= 0 else { throw Self.error() }
        return SFTPLocalFile(descriptor: fd, appends: flags.contains(.append))
    }

    public func openDirectory(_ path: SFTPPath) async throws -> any SFTPServerDirectory {
        let path = try Self.text(path)
        let host = try confined(path, followingFinal: true)
        var info = Darwin.stat()
        try Self.check(stat(host, &info))
        guard SFTPFileType(permissions: UInt32(info.st_mode)) == .directory else { throw Self.error(ENOTDIR) }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: host).sorted()
        } catch {
            throw Self.error(EACCES)
        }
        // 和 OpenSSH 一样带上 `.` 与 `..`。
        var entries: [SFTPDirectoryEntry] = []
        for name in [".", ".."] + names {
            var entryInfo = Darwin.stat()
            let entryHost = name == "." ? host : name == ".." ? (host as NSString).deletingLastPathComponent : host + "/" + name
            guard lstat(entryHost, &entryInfo) == 0 else { continue }
            entries.append(SFTPDirectoryEntry(
                filename: name, longname: Self.longname(name, entryInfo),
                attributes: Self.attributes(from: entryInfo)))
        }
        return SFTPLocalDirectory(entries: entries, batchSize: directoryBatchSize)
    }

    public func removeFile(_ path: SFTPPath) async throws {
        let path = try Self.text(path)
        let host = try confined(path, followingFinal: false)
        try Self.check(unlink(host))
    }

    public func createDirectory(_ path: SFTPPath, attributes: SFTPFileAttributes) async throws {
        let path = try Self.text(path)
        let host = try confined(path, followingFinal: false)
        try Self.check(mkdir(host, mode_t(attributes.permissions.map { $0 & 0o7777 } ?? 0o777)))
    }

    public func removeDirectory(_ path: SFTPPath) async throws {
        let path = try Self.text(path)
        let host = try confined(path, followingFinal: false)
        try Self.check(rmdir(host))
    }

    public func rename(_ oldPath: SFTPPath, to newPath: SFTPPath, replacingExisting: Bool) async throws {
        let oldPath = try Self.text(oldPath)
        let newPath = try Self.text(newPath)
        let old = try confined(oldPath, followingFinal: false)
        let new = try confined(newPath, followingFinal: false)
        if !replacingExisting {
            // OpenSSH 的 SSH_FXP_RENAME：目标已存在就失败，不覆盖。
            var info = Darwin.stat()
            if lstat(new, &info) == 0 { throw SFTPServerStatusError.failure("File exists") }
        }
        try Self.check(Darwin.rename(old, new))
    }

    public func readLink(_ path: SFTPPath) async throws -> SFTPPath {
        let path = try Self.text(path)
        let host = try confined(path, followingFinal: false)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(host, &buffer, buffer.count - 1)
        guard count >= 0 else { throw Self.error() }
        let target = String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        // 建链接时换成了真实路径的绝对目标，换回客户端视角。
        return SFTPPath(virtualPath(forHost: target) ?? target)
    }

    public func createSymlink(at linkPath: SFTPPath, pointingTo targetPath: SFTPPath) async throws {
        let linkPath = try Self.text(linkPath)
        let targetPath = try Self.text(targetPath)
        let host = try confined(linkPath, followingFinal: false)
        let target = targetPath.hasPrefix("/") ? hostPath(for: targetPath) : targetPath
        try Self.check(symlink(target, host))
    }

    public func createHardLink(at newPath: SFTPPath, pointingTo existingPath: SFTPPath) async throws {
        let newPath = try Self.text(newPath)
        let existingPath = try Self.text(existingPath)
        let existing = try confined(existingPath, followingFinal: false)
        let new = try confined(newPath, followingFinal: false)
        try Self.check(link(existing, new))
    }

    public func fileSystemStats(at path: SFTPPath) async throws -> SFTPFileSystemStats {
        let path = try Self.text(path)
        let host = try confined(path, followingFinal: true)
        var info = statvfs()
        try Self.check(statvfs(host, &info))
        return Self.stats(from: info)
    }
}

// MARK: - 句柄

/// 一个打开的文件描述符。`pread` / `pwrite` 本身线程安全，并发的读写互不干扰。
final class SFTPLocalFile: SFTPServerFile {
    private let descriptor: Int32
    private let appends: Bool
    private let closed = NIOLockedValueBox(false)

    init(descriptor: Int32, appends: Bool) {
        self.descriptor = descriptor
        self.appends = appends
    }

    deinit {
        if !closed.withLockedValue({ $0 }) { Darwin.close(descriptor) }
    }

    func read(at offset: UInt64, length: Int) async throws -> ByteBuffer? {
        guard length > 0 else { return ByteBuffer() }
        var buffer = ByteBufferAllocator().buffer(capacity: length)
        var result = 0
        buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: length) { pointer in
            result = pread(descriptor, pointer.baseAddress, length, off_t(clamping: offset))
            return max(0, result)
        }
        if result < 0 { throw SFTPLocalFileSystem.error() }
        // pread 返回 0 = offset 处已是文件尾。
        return result == 0 ? nil : buffer
    }

    func write(_ data: ByteBuffer, at offset: UInt64) async throws {
        var position = off_t(clamping: offset)
        var remaining = data
        while remaining.readableBytes > 0 {
            let written = remaining.withUnsafeReadableBytes { pointer in
                appends
                    ? Darwin.write(descriptor, pointer.baseAddress, pointer.count)
                    : pwrite(descriptor, pointer.baseAddress, pointer.count, position)
            }
            guard written > 0 else { throw SFTPLocalFileSystem.error() }
            remaining.moveReaderIndex(forwardBy: written)
            position += off_t(written)
        }
    }

    func attributes() async throws -> SFTPFileAttributes {
        var info = Darwin.stat()
        guard fstat(descriptor, &info) == 0 else { throw SFTPLocalFileSystem.error() }
        return SFTPLocalFileSystem.attributes(from: info)
    }

    func setAttributes(_ attributes: SFTPFileAttributes) async throws {
        if let size = attributes.size, ftruncate(descriptor, off_t(clamping: size)) != 0 {
            throw SFTPLocalFileSystem.error()
        }
        if let permissions = attributes.permissions, fchmod(descriptor, mode_t(permissions & 0o7777)) != 0 {
            throw SFTPLocalFileSystem.error()
        }
        if let owner = attributes.owner, fchown(descriptor, owner.userID, owner.groupID) != 0 {
            throw SFTPLocalFileSystem.error()
        }
        if let times = attributes.times {
            var values = [timeval(tv_sec: Int(times.accessSeconds), tv_usec: 0),
                          timeval(tv_sec: Int(times.modificationSeconds), tv_usec: 0)]
            if futimes(descriptor, &values) != 0 { throw SFTPLocalFileSystem.error() }
        }
    }

    func sync() async throws {
        if fsync(descriptor) != 0 { throw SFTPLocalFileSystem.error() }
    }

    func fileSystemStats() async throws -> SFTPFileSystemStats {
        var info = statvfs()
        guard fstatvfs(descriptor, &info) == 0 else { throw SFTPLocalFileSystem.error() }
        return SFTPLocalFileSystem.stats(from: info)
    }

    func close() async throws {
        let first = closed.withLockedValue { closed in
            defer { closed = true }
            return !closed
        }
        if first, Darwin.close(descriptor) != 0 { throw SFTPLocalFileSystem.error() }
    }
}

/// 打开目录时拍下的快照，按批交出去。
final class SFTPLocalDirectory: SFTPServerDirectory {
    private let remaining: NIOLockedValueBox<ArraySlice<SFTPDirectoryEntry>>
    private let batchSize: Int

    init(entries: [SFTPDirectoryEntry], batchSize: Int) {
        self.remaining = NIOLockedValueBox(entries[...])
        self.batchSize = batchSize
    }

    func nextBatch() async throws -> [SFTPDirectoryEntry]? {
        remaining.withLockedValue { remaining in
            guard !remaining.isEmpty else { return nil }
            let batch = Array(remaining.prefix(batchSize))
            remaining = remaining.dropFirst(batch.count)
            return batch
        }
    }
}

private extension String {
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }

    func rightPadded(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
#endif
