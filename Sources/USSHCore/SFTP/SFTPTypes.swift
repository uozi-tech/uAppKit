import Foundation
import NIOCore

// SFTP v3（draft-ietf-secsh-filexfer-02，按 OpenSSH 的实现）里客户端与服务端共用的公开值类型。
// 线格式的编解码在 `SFTPWire.swift`（package 可见），这里只有调用方会碰到的东西。

// MARK: - 状态码

/// SSH_FXP_STATUS 里的状态码。
///
/// 用结构体而不是枚举：v3 只定义了 0–8，但服务端可以回任何 `uint32`（有的实现会回 v4+ 的码，
/// 比如 11 = 文件已存在），收到不认识的码也必须原样交给调用方，不能折成「未知」丢掉数值。
public struct SFTPStatusCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let ok = SFTPStatusCode(0)
    public static let eof = SFTPStatusCode(1)
    public static let noSuchFile = SFTPStatusCode(2)
    public static let permissionDenied = SFTPStatusCode(3)
    public static let failure = SFTPStatusCode(4)
    public static let badMessage = SFTPStatusCode(5)
    public static let noConnection = SFTPStatusCode(6)
    public static let connectionLost = SFTPStatusCode(7)
    public static let operationUnsupported = SFTPStatusCode(8)
    // 下面是 v4 之后的码。v3 的服务端不该发，但确实有实现会发，认出来方便调用方判断。
    public static let invalidHandle = SFTPStatusCode(9)
    public static let noSuchPath = SFTPStatusCode(10)
    public static let fileAlreadyExists = SFTPStatusCode(11)
    public static let writeProtect = SFTPStatusCode(12)
    public static let noMedia = SFTPStatusCode(13)
    public static let noSpaceOnFilesystem = SFTPStatusCode(14)
    public static let quotaExceeded = SFTPStatusCode(15)
    public static let directoryNotEmpty = SFTPStatusCode(18)
    public static let notADirectory = SFTPStatusCode(19)
    public static let fileIsADirectory = SFTPStatusCode(24)

    /// 协议里的名字（`SSH_FX_NO_SUCH_FILE` 之类），只用于日志与诊断。
    public var description: String {
        switch rawValue {
        case 0: return "SSH_FX_OK"
        case 1: return "SSH_FX_EOF"
        case 2: return "SSH_FX_NO_SUCH_FILE"
        case 3: return "SSH_FX_PERMISSION_DENIED"
        case 4: return "SSH_FX_FAILURE"
        case 5: return "SSH_FX_BAD_MESSAGE"
        case 6: return "SSH_FX_NO_CONNECTION"
        case 7: return "SSH_FX_CONNECTION_LOST"
        case 8: return "SSH_FX_OP_UNSUPPORTED"
        case 9: return "SSH_FX_INVALID_HANDLE"
        case 10: return "SSH_FX_NO_SUCH_PATH"
        case 11: return "SSH_FX_FILE_ALREADY_EXISTS"
        case 12: return "SSH_FX_WRITE_PROTECT"
        case 13: return "SSH_FX_NO_MEDIA"
        case 14: return "SSH_FX_NO_SPACE_ON_FILESYSTEM"
        case 15: return "SSH_FX_QUOTA_EXCEEDED"
        case 18: return "SSH_FX_DIR_NOT_EMPTY"
        case 19: return "SSH_FX_NOT_A_DIRECTORY"
        case 24: return "SSH_FX_FILE_IS_A_DIRECTORY"
        default: return "SSH_FX(\(rawValue))"
        }
    }
}

// MARK: - 打开标志

/// SSH_FXP_OPEN 的 `pflags`。
public struct SFTPOpenFlags: OptionSet, Hashable, Sendable {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// SSH_FXF_READ
    public static let read = SFTPOpenFlags(rawValue: 0x0000_0001)
    /// SSH_FXF_WRITE
    public static let write = SFTPOpenFlags(rawValue: 0x0000_0002)
    /// SSH_FXF_APPEND：OpenSSH 的实现里写入一律落到文件末尾，忽略请求里的 offset。
    public static let append = SFTPOpenFlags(rawValue: 0x0000_0004)
    /// SSH_FXF_CREAT
    public static let create = SFTPOpenFlags(rawValue: 0x0000_0008)
    /// SSH_FXF_TRUNC
    public static let truncate = SFTPOpenFlags(rawValue: 0x0000_0010)
    /// SSH_FXF_EXCL：路径已存在时打开失败（v3 只回 SSH_FX_FAILURE，文案依实现而定）。
    public static let exclusive = SFTPOpenFlags(rawValue: 0x0000_0020)
}

// MARK: - 文件属性

/// 文件类型，取自权限字段里的 `S_IFMT` 位。
public enum SFTPFileType: Hashable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case characterDevice
    case blockDevice
    case fifo
    case socket
    case unknown(UInt32)

    /// `S_IFMT` 掩码。
    public static let typeMask: UInt32 = 0o170000

    public init(permissions: UInt32) {
        switch permissions & Self.typeMask {
        case 0o100000: self = .regularFile
        case 0o040000: self = .directory
        case 0o120000: self = .symbolicLink
        case 0o020000: self = .characterDevice
        case 0o060000: self = .blockDevice
        case 0o010000: self = .fifo
        case 0o140000: self = .socket
        case let other: self = .unknown(other)
        }
    }

    /// 这个类型在权限字段里的 `S_IFMT` 位。
    public var modeBits: UInt32 {
        switch self {
        case .regularFile: return 0o100000
        case .directory: return 0o040000
        case .symbolicLink: return 0o120000
        case .characterDevice: return 0o020000
        case .blockDevice: return 0o060000
        case .fifo: return 0o010000
        case .socket: return 0o140000
        case .unknown(let bits): return bits & Self.typeMask
        }
    }
}

/// 文件属主（v3 里 uid 与 gid 只能一起出现）。
public struct SFTPFileOwner: Hashable, Sendable {
    public var userID: UInt32
    public var groupID: UInt32

    public init(userID: UInt32, groupID: UInt32) {
        self.userID = userID
        self.groupID = groupID
    }
}

/// 访问与修改时间（v3 里两者只能一起出现，单位是 Unix 秒，`uint32`）。
///
/// 存原始秒数而不是 `Date`：线上就是秒，往返不丢精度；`Date` 由计算属性给。
public struct SFTPFileTimes: Hashable, Sendable {
    public var accessSeconds: UInt32
    public var modificationSeconds: UInt32

    public init(accessSeconds: UInt32, modificationSeconds: UInt32) {
        self.accessSeconds = accessSeconds
        self.modificationSeconds = modificationSeconds
    }

    /// 由 `Date` 构造。v3 的时间是 `uint32` 秒：**早于 1970 或晚于 2106-02-07 的时间被夹到两端**，
    /// 不足一秒的部分舍去。不能接受夹取的调用方用 `init?(exactAccessDate:modificationDate:)`。
    public init(accessDate: Date, modificationDate: Date) {
        self.accessSeconds = Self.seconds(accessDate)
        self.modificationSeconds = Self.seconds(modificationDate)
    }

    /// 同上，但任何一个时间超出 `uint32` 秒能表示的范围（1970-01-01 至 2106-02-07）就返回 nil，不夹取。
    /// 不足一秒的部分仍然舍去（线上没有更细的精度）。
    public init?(exactAccessDate accessDate: Date, modificationDate: Date) {
        guard let access = Self.exactSeconds(accessDate), let modification = Self.exactSeconds(modificationDate) else {
            return nil
        }
        self.accessSeconds = access
        self.modificationSeconds = modification
    }

    private static func exactSeconds(_ date: Date) -> UInt32? {
        let value = date.timeIntervalSince1970.rounded(.down)
        guard value >= 0, value <= Double(UInt32.max) else { return nil }
        return UInt32(value)
    }

    public var accessDate: Date { Date(timeIntervalSince1970: TimeInterval(accessSeconds)) }
    public var modificationDate: Date { Date(timeIntervalSince1970: TimeInterval(modificationSeconds)) }

    private static func seconds(_ date: Date) -> UInt32 {
        let value = date.timeIntervalSince1970.rounded(.down)
        if !(value > 0) { return 0 }
        if value >= Double(UInt32.max) { return .max }
        return UInt32(value)
    }
}

/// ATTRS 里的一个扩展属性对（`extended_type` / `extended_data`，都是 SSH string）。
public struct SFTPExtendedAttribute: Hashable, Sendable {
    public var name: String
    public var data: ByteBuffer

    public init(name: String, data: ByteBuffer) {
        self.name = name
        self.data = data
    }
}

/// SFTP v3 的 ATTRS。每个字段可选：nil = 线上不带这一项（对 setstat 来说就是「不改」）。
public struct SFTPFileAttributes: Hashable, Sendable {
    public var size: UInt64?
    public var owner: SFTPFileOwner?
    /// 完整的 `st_mode`（含 `S_IFMT` 类型位）。setstat 时服务端只看权限位。
    public var permissions: UInt32?
    public var times: SFTPFileTimes?
    public var extended: [SFTPExtendedAttribute]

    public init(
        size: UInt64? = nil,
        owner: SFTPFileOwner? = nil,
        permissions: UInt32? = nil,
        times: SFTPFileTimes? = nil,
        extended: [SFTPExtendedAttribute] = []
    ) {
        self.size = size
        self.owner = owner
        self.permissions = permissions
        self.times = times
        self.extended = extended
    }

    /// 什么都不带的属性（open / mkdir 不指定属性时用）。
    public static let none = SFTPFileAttributes()

    /// 文件类型；服务端没给权限字段时为 nil。
    public var fileType: SFTPFileType? {
        permissions.map(SFTPFileType.init(permissions:))
    }

    public var isDirectory: Bool { fileType == .directory }
    public var isRegularFile: Bool { fileType == .regularFile }
    public var isSymbolicLink: Bool { fileType == .symbolicLink }

    /// 去掉类型位之后的权限（`0o7777` 以内，含 setuid / setgid / sticky）。
    public var permissionBits: UInt32? {
        permissions.map { $0 & 0o7777 }
    }

    public var modificationDate: Date? { times?.modificationDate }
    public var accessDate: Date? { times?.accessDate }
}

// MARK: - 目录项

/// SSH_FXP_NAME 里的一项：READDIR 的目录项，也是 REALPATH / READLINK 的回答。
public struct SFTPDirectoryEntry: Hashable, Sendable {
    /// 名字的原始字节。拿目录项去做后续操作（stat、打开、改名、删除）时用它，不要用 `filename`。
    public var name: SFTPPath
    /// `ls -l` 风格的一行（v3 有，内容依实现而定，只适合原样显示）。
    public var longname: String
    public var attributes: SFTPFileAttributes

    public init(name: SFTPPath, longname: String, attributes: SFTPFileAttributes) {
        self.name = name
        self.longname = longname
        self.attributes = attributes
    }

    public init(filename: String, longname: String, attributes: SFTPFileAttributes) {
        self.init(name: SFTPPath(filename), longname: longname, attributes: attributes)
    }

    /// 名字按 UTF-8 解出的字符串（非法序列替换，只适合显示）。
    public var filename: String { name.string }
}

// MARK: - 扩展的返回值

/// `statvfs@openssh.com` / `fstatvfs@openssh.com` 的回答，字段同 `statvfs(3)`。
public struct SFTPFileSystemStats: Hashable, Sendable {
    public var blockSize: UInt64
    public var fragmentSize: UInt64
    public var totalBlocks: UInt64
    public var freeBlocks: UInt64
    public var availableBlocks: UInt64
    public var totalInodes: UInt64
    public var freeInodes: UInt64
    public var availableInodes: UInt64
    public var fileSystemID: UInt64
    public var flags: UInt64
    public var maximumNameLength: UInt64

    /// `SSH_FXE_STATVFS_ST_RDONLY`
    public static let readOnlyFlag: UInt64 = 0x1
    /// `SSH_FXE_STATVFS_ST_NOSUID`
    public static let noSetUIDFlag: UInt64 = 0x2

    public init(
        blockSize: UInt64, fragmentSize: UInt64, totalBlocks: UInt64, freeBlocks: UInt64,
        availableBlocks: UInt64, totalInodes: UInt64, freeInodes: UInt64, availableInodes: UInt64,
        fileSystemID: UInt64, flags: UInt64, maximumNameLength: UInt64
    ) {
        self.blockSize = blockSize
        self.fragmentSize = fragmentSize
        self.totalBlocks = totalBlocks
        self.freeBlocks = freeBlocks
        self.availableBlocks = availableBlocks
        self.totalInodes = totalInodes
        self.freeInodes = freeInodes
        self.availableInodes = availableInodes
        self.fileSystemID = fileSystemID
        self.flags = flags
        self.maximumNameLength = maximumNameLength
    }

    public var isReadOnly: Bool { flags & Self.readOnlyFlag != 0 }
    /// 非 root 用户可用的字节数（`f_frsize × f_bavail`，饱和）。
    public var availableBytes: UInt64 { fragmentSize.multipliedReportingOverflow(by: availableBlocks).overflow ? .max : fragmentSize &* availableBlocks }
    /// 总字节数（`f_frsize × f_blocks`，饱和）。
    public var totalBytes: UInt64 { fragmentSize.multipliedReportingOverflow(by: totalBlocks).overflow ? .max : fragmentSize &* totalBlocks }
}

/// `limits@openssh.com` 的回答。0 表示服务端不限 / 不知道。
public struct SFTPServerLimits: Hashable, Sendable {
    public var maximumPacketLength: UInt64
    public var maximumReadLength: UInt64
    public var maximumWriteLength: UInt64
    public var maximumOpenHandles: UInt64

    public init(maximumPacketLength: UInt64, maximumReadLength: UInt64, maximumWriteLength: UInt64, maximumOpenHandles: UInt64) {
        self.maximumPacketLength = maximumPacketLength
        self.maximumReadLength = maximumReadLength
        self.maximumWriteLength = maximumWriteLength
        self.maximumOpenHandles = maximumOpenHandles
    }
}

/// OpenSSH 在 SSH_FXP_VERSION 里宣告的扩展名。
public enum SFTPExtensionName {
    public static let posixRename = "posix-rename@openssh.com"
    public static let statVFS = "statvfs@openssh.com"
    public static let fstatVFS = "fstatvfs@openssh.com"
    public static let hardLink = "hardlink@openssh.com"
    public static let fsync = "fsync@openssh.com"
    public static let lsetstat = "lsetstat@openssh.com"
    public static let limits = "limits@openssh.com"
}
