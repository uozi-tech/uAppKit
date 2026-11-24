import NIOCore
import USSHCore

/// 测试服务端的文件系统要回给客户端的状态。文件系统实现抛它，服务端原样回成 SSH_FXP_STATUS；
/// 抛别的错误一律回 `SSH_FX_FAILURE`，文案是 `String(describing:)`。
public struct SFTPServerStatusError: Error, Hashable, Sendable {
    public var code: SFTPStatusCode
    public var message: String

    public init(_ code: SFTPStatusCode, _ message: String = "") {
        self.code = code
        self.message = message
    }

    public static func noSuchFile(_ message: String = "No such file") -> Self { Self(.noSuchFile, message) }
    public static func permissionDenied(_ message: String = "Permission denied") -> Self { Self(.permissionDenied, message) }
    public static func failure(_ message: String = "Failure") -> Self { Self(.failure, message) }
    public static func unsupported(_ message: String = "Operation unsupported") -> Self { Self(.operationUnsupported, message) }
}

/// 测试服务端背后的文件系统。路径是客户端发来的原样字节（`SFTPPath`），解释（相对路径、`..`、限制在根目录里）由实现负责。
///
/// 方法都是 `async`：服务端为每个请求开一个任务调用它们，所以可以在里面等待、并发执行；
/// 回答的顺序因此可以和请求的顺序不同（客户端必须容忍乱序，这正是要测的）。
/// 可选的操作有默认实现，回 `SSH_FX_OP_UNSUPPORTED`。
public protocol SFTPServerFileSystem: Sendable {
    func realPath(_ path: SFTPPath) async throws -> SFTPPath
    func attributes(at path: SFTPPath, followingSymlinks: Bool) async throws -> SFTPFileAttributes
    func setAttributes(_ attributes: SFTPFileAttributes, at path: SFTPPath, followingSymlinks: Bool) async throws
    func openFile(_ path: SFTPPath, flags: SFTPOpenFlags, attributes: SFTPFileAttributes) async throws -> any SFTPServerFile
    func openDirectory(_ path: SFTPPath) async throws -> any SFTPServerDirectory
    func removeFile(_ path: SFTPPath) async throws
    func createDirectory(_ path: SFTPPath, attributes: SFTPFileAttributes) async throws
    func removeDirectory(_ path: SFTPPath) async throws
    /// `replacingExisting == false` 是 SSH_FXP_RENAME（OpenSSH 语义：目标已存在就失败），
    /// `true` 是 `posix-rename@openssh.com`（`rename(2)`）。
    func rename(_ oldPath: SFTPPath, to newPath: SFTPPath, replacingExisting: Bool) async throws
    func readLink(_ path: SFTPPath) async throws -> SFTPPath
    func createSymlink(at linkPath: SFTPPath, pointingTo targetPath: SFTPPath) async throws
    func createHardLink(at newPath: SFTPPath, pointingTo existingPath: SFTPPath) async throws
    func fileSystemStats(at path: SFTPPath) async throws -> SFTPFileSystemStats
}

extension SFTPServerFileSystem {
    public func setAttributes(_ attributes: SFTPFileAttributes, at path: SFTPPath, followingSymlinks: Bool) async throws {
        throw SFTPServerStatusError.unsupported()
    }

    public func readLink(_ path: SFTPPath) async throws -> SFTPPath {
        throw SFTPServerStatusError.unsupported()
    }

    public func createSymlink(at linkPath: SFTPPath, pointingTo targetPath: SFTPPath) async throws {
        throw SFTPServerStatusError.unsupported()
    }

    public func createHardLink(at newPath: SFTPPath, pointingTo existingPath: SFTPPath) async throws {
        throw SFTPServerStatusError.unsupported()
    }

    public func fileSystemStats(at path: SFTPPath) async throws -> SFTPFileSystemStats {
        throw SFTPServerStatusError.unsupported()
    }
}

/// 打开着的文件。服务端可能并发调用 `read` / `write`（客户端流水线发的请求）。
public protocol SFTPServerFile: Sendable {
    /// 返回 nil = EOF；可以少给。
    func read(at offset: UInt64, length: Int) async throws -> ByteBuffer?
    func write(_ data: ByteBuffer, at offset: UInt64) async throws
    func attributes() async throws -> SFTPFileAttributes
    func setAttributes(_ attributes: SFTPFileAttributes) async throws
    func sync() async throws
    func fileSystemStats() async throws -> SFTPFileSystemStats
    func close() async throws
}

extension SFTPServerFile {
    public func setAttributes(_ attributes: SFTPFileAttributes) async throws {
        throw SFTPServerStatusError.unsupported()
    }

    public func sync() async throws {}

    public func fileSystemStats() async throws -> SFTPFileSystemStats {
        throw SFTPServerStatusError.unsupported()
    }
}

/// 打开着的目录。
public protocol SFTPServerDirectory: Sendable {
    /// 下一批目录项；nil = 读完了（服务端回 SSH_FX_EOF）。
    func nextBatch() async throws -> [SFTPDirectoryEntry]?
    func close() async throws
}

extension SFTPServerDirectory {
    public func close() async throws {}
}
