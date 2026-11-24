import NIOConcurrencyHelpers
import NIOCore
@testable import USSHCore
import USSHTestServer

/// 测试用的内存文件系统：名字按**字节**存（可以有非 UTF-8 的名字、NFC 与 NFD 并存），
/// 还能用 `readOverride` 让某些 READ 回特定结果（谎报 EOF、回 0 字节的 DATA）。
final class SFTPMemoryFileSystem: SFTPServerFileSystem {
    enum ReadOverride: Sendable {
        /// 回 SSH_FX_EOF。
        case eof
        /// 回这些字节（可以是 0 字节）。
        case data(ByteBuffer)
    }

    private enum Node {
        case file([UInt8])
        case directory
    }

    private let nodes = NIOLockedValueBox<[SFTPPath: Node]>(["/": .directory])
    /// 返回非 nil 就用它代替真实读取。参数：文件路径、offset、长度。
    let readOverride = NIOLockedValueBox<(@Sendable (SFTPPath, UInt64, Int) -> ReadOverride?)?>(nil)

    /// 字面规范化：以 `/` 开头，去掉 `.`、`..`、重复的 `/`，按字节处理。
    static func normalize(_ path: SFTPPath) -> SFTPPath {
        var parts: [ArraySlice<UInt8>] = []
        for part in path.bytes.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true) {
            if part.elementsEqual([UInt8(ascii: ".")]) { continue }
            if part.elementsEqual([UInt8(ascii: "."), UInt8(ascii: ".")]) {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        var bytes: [UInt8] = []
        for part in parts {
            bytes.append(UInt8(ascii: "/"))
            bytes.append(contentsOf: part)
        }
        return bytes.isEmpty ? "/" : SFTPPath(bytes: bytes)
    }

    private static func parent(_ path: SFTPPath) -> SFTPPath {
        guard let slash = path.bytes.lastIndex(of: UInt8(ascii: "/")), slash > 0 else { return "/" }
        return SFTPPath(bytes: path.bytes[..<slash])
    }

    private static func lastComponent(_ path: SFTPPath) -> SFTPPath {
        guard let slash = path.bytes.lastIndex(of: UInt8(ascii: "/")) else { return path }
        return SFTPPath(bytes: path.bytes[(slash + 1)...])
    }

    // MARK: 给测试直接用

    func put(_ path: SFTPPath, _ contents: [UInt8]) {
        let key = Self.normalize(path)
        nodes.withLockedValue { $0[key] = .file(contents) }
    }

    func makeDirectory(_ path: SFTPPath) {
        let key = Self.normalize(path)
        nodes.withLockedValue { $0[key] = .directory }
    }

    func contents(_ path: SFTPPath) -> [UInt8]? {
        let key = Self.normalize(path)
        return nodes.withLockedValue { nodes in
            if case .file(let bytes)? = nodes[key] { return bytes }
            return nil
        }
    }

    func exists(_ path: SFTPPath) -> Bool {
        let key = Self.normalize(path)
        return nodes.withLockedValue { $0[key] != nil }
    }

    // MARK: 文件内容（句柄用）

    fileprivate func read(_ path: SFTPPath, at offset: UInt64, length: Int) throws -> ByteBuffer? {
        if let override = readOverride.withLockedValue({ $0 })?(path, offset, length) {
            switch override {
            case .eof: return nil
            case .data(let data): return data
            }
        }
        guard let bytes = contents(path) else { throw SFTPServerStatusError.noSuchFile() }
        guard offset < UInt64(bytes.count) else { return nil }
        let start = Int(offset)
        let end = min(bytes.count, start + length)
        return ByteBuffer(bytes: bytes[start..<end])
    }

    fileprivate func write(_ path: SFTPPath, _ data: ByteBuffer, at offset: UInt64) throws {
        let key = Self.normalize(path)
        try nodes.withLockedValue { nodes in
            guard case .file(var bytes)? = nodes[key] else { throw SFTPServerStatusError.noSuchFile() }
            let start = Int(offset)
            let end = start + data.readableBytes
            if bytes.count < end { bytes.append(contentsOf: [UInt8](repeating: 0, count: end - bytes.count)) }
            bytes.replaceSubrange(start..<end, with: data.readableBytesView)
            nodes[key] = .file(bytes)
        }
    }

    private func attributes(of node: Node) -> SFTPFileAttributes {
        switch node {
        case .file(let bytes): return SFTPFileAttributes(size: UInt64(bytes.count), permissions: 0o100644)
        case .directory: return SFTPFileAttributes(size: 0, permissions: 0o040755)
        }
    }

    // MARK: SFTPServerFileSystem

    func realPath(_ path: SFTPPath) async throws -> SFTPPath {
        let key = Self.normalize(path)
        guard exists(key) else { throw SFTPServerStatusError.noSuchFile() }
        return key
    }

    func attributes(at path: SFTPPath, followingSymlinks: Bool) async throws -> SFTPFileAttributes {
        let key = Self.normalize(path)
        guard let node = nodes.withLockedValue({ $0[key] }) else { throw SFTPServerStatusError.noSuchFile() }
        return attributes(of: node)
    }

    func openFile(_ path: SFTPPath, flags: SFTPOpenFlags, attributes: SFTPFileAttributes) async throws -> any SFTPServerFile {
        let key = Self.normalize(path)
        try nodes.withLockedValue { nodes in
            guard case .directory? = nodes[Self.parent(key)] else { throw SFTPServerStatusError.noSuchFile() }
            switch nodes[key] {
            case .directory?:
                throw SFTPServerStatusError.failure("is a directory")
            case .file?:
                if flags.contains(.create) && flags.contains(.exclusive) { throw SFTPServerStatusError.failure("exists") }
                if flags.contains(.truncate) { nodes[key] = .file([]) }
            case nil:
                guard flags.contains(.create) else { throw SFTPServerStatusError.noSuchFile() }
                nodes[key] = .file([])
            }
        }
        return MemoryFile(fileSystem: self, path: key)
    }

    func openDirectory(_ path: SFTPPath) async throws -> any SFTPServerDirectory {
        let key = Self.normalize(path)
        let entries = try nodes.withLockedValue { nodes -> [SFTPDirectoryEntry] in
            guard case .directory? = nodes[key] else { throw SFTPServerStatusError.noSuchFile() }
            return nodes.compactMap { child, node in
                guard child != key, Self.parent(child) == key else { return nil }
                let name = Self.lastComponent(child)
                return SFTPDirectoryEntry(name: name, longname: name.string, attributes: attributes(of: node))
            }.sorted { $0.name.bytes.lexicographicallyPrecedes($1.name.bytes) }
        }
        return MemoryDirectory(entries: entries)
    }

    func removeFile(_ path: SFTPPath) async throws {
        let key = Self.normalize(path)
        try nodes.withLockedValue { nodes in
            guard case .file? = nodes[key] else { throw SFTPServerStatusError.noSuchFile() }
            nodes[key] = nil
        }
    }

    func createDirectory(_ path: SFTPPath, attributes: SFTPFileAttributes) async throws {
        let key = Self.normalize(path)
        try nodes.withLockedValue { nodes in
            guard nodes[key] == nil else { throw SFTPServerStatusError.failure("exists") }
            guard case .directory? = nodes[Self.parent(key)] else { throw SFTPServerStatusError.noSuchFile() }
            nodes[key] = .directory
        }
    }

    func removeDirectory(_ path: SFTPPath) async throws {
        let key = Self.normalize(path)
        try nodes.withLockedValue { nodes in
            guard case .directory? = nodes[key] else { throw SFTPServerStatusError.noSuchFile() }
            guard !nodes.keys.contains(where: { $0 != key && Self.parent($0) == key }) else {
                throw SFTPServerStatusError.failure("not empty")
            }
            nodes[key] = nil
        }
    }

    func rename(_ oldPath: SFTPPath, to newPath: SFTPPath, replacingExisting: Bool) async throws {
        let old = Self.normalize(oldPath)
        let new = Self.normalize(newPath)
        try nodes.withLockedValue { nodes in
            guard case .file(let bytes)? = nodes[old] else { throw SFTPServerStatusError.noSuchFile() }
            if nodes[new] != nil && !replacingExisting { throw SFTPServerStatusError.failure("exists") }
            nodes[old] = nil
            nodes[new] = .file(bytes)
        }
    }
}

private struct MemoryFile: SFTPServerFile {
    let fileSystem: SFTPMemoryFileSystem
    let path: SFTPPath

    func read(at offset: UInt64, length: Int) async throws -> ByteBuffer? {
        try fileSystem.read(path, at: offset, length: length)
    }

    func write(_ data: ByteBuffer, at offset: UInt64) async throws {
        try fileSystem.write(path, data, at: offset)
    }

    func attributes() async throws -> SFTPFileAttributes {
        SFTPFileAttributes(size: UInt64(fileSystem.contents(path)?.count ?? 0), permissions: 0o100644)
    }

    func close() async throws {}
}

private final class MemoryDirectory: SFTPServerDirectory {
    private let remaining: NIOLockedValueBox<[SFTPDirectoryEntry]?>

    init(entries: [SFTPDirectoryEntry]) {
        remaining = NIOLockedValueBox(entries)
    }

    func nextBatch() async throws -> [SFTPDirectoryEntry]? {
        remaining.withLockedValue { remaining in
            defer { remaining = nil }
            return remaining
        }
    }
}
