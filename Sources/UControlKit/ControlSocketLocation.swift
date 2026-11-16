// macOS 专用：整份文件用平台条件包住，理由同 `UAppKitBridge`。
#if os(macOS)

import Darwin
import Foundation

/// 一个接入本机 IPC 的 app 是谁。只描述「身份与布局」，不含任何文案。
///
/// 这些字符串都已经随各 app 发过版（socket 路径、ctl 名、bundle id 都写死在客户端脚本里），
/// 核心不做任何归一化，原样拼路径。
public struct ControlAppIdentity: Sendable, Hashable {
    /// 给人看的 app 名，出现在服务端兜底错误的消息里（`server_busy` 之类）。
    public var appName: String
    /// 沙盒容器名就是它：`~/Library/Containers/<bundleIdentifier>/`。
    public var bundleIdentifier: String
    /// `<Application Support>/<directoryName>/` 是 socket 的默认目录。
    public var directoryName: String
    /// 命令行客户端的名字（`utablectl` / `utermctl`）。核心不用它拼路径，留给技能安装与 UI。
    public var ctlName: String
    /// 当前构建开不开沙盒。决定 socket 的退路目录与客户端候选路径的形状，见 `ControlSocketLocation`。
    ///
    /// 注意它可能随构建配置变：uTable 的 Debug 不开沙盒、Release 开；uTerm 两种都开；uGit 都不开。
    public var isSandboxed: Bool

    public init(
        appName: String,
        bundleIdentifier: String,
        directoryName: String,
        ctlName: String,
        isSandboxed: Bool
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.directoryName = directoryName
        self.ctlName = ctlName
        self.isSandboxed = isSandboxed
    }
}

/// socket 文件放在哪、客户端按什么顺序找它。
///
/// 默认放在 `<Application Support>/<directoryName>/<filename>`。沙盒容器里这条路径除用户名外
/// 就有九十多字节，用户名稍长（uTable 9 个字符、uTerm 11 个字符起）就放不进 `sun_path` 的
/// 104 字节（含结尾 NUL），这时改放临时目录：
///
/// - 沙盒：`NSTemporaryDirectory()`，也就是容器的 `Data/tmp/`。客户端按
///   `~/Library/Containers/<bundle id>/Data/tmp/` 找得到。
/// - 非沙盒：`confstr(_CS_DARWIN_USER_TEMP_DIR)`，即 `/var/folders/…/T/`。客户端（另一个进程）
///   同样能用这个系统调用算出来，而 `NSTemporaryDirectory()` 会被 `TMPDIR` 环境变量改掉，
///   两边可能对不上，所以非沙盒不用它。
///
/// 两处都放不下时仍返回短的那条，由 `ControlSocketServer.start()` 报错（不 bind）。
public struct ControlSocketLocation: Sendable, Hashable {
    /// `sockaddr_un.sun_path` 的字节上限（含结尾 NUL）。
    public static let maxSunPathLength = 104

    public var identity: ControlAppIdentity
    /// socket 文件名。各 app 已发版的约定是 Release `control.sock`、Debug `dev.sock`，由调用方传入。
    public var filename: String

    public init(identity: ControlAppIdentity, filename: String) {
        self.identity = identity
        self.filename = filename
    }

    /// 路径能不能放进 `sun_path`（要给结尾的 NUL 留 1 字节）。
    public static func fitsInSunPath(_ url: URL) -> Bool {
        url.path.utf8.count <= maxSunPathLength - 1
    }

    /// 当前进程该监听的位置。
    public var socketURL: URL {
        socketURL(applicationSupport: applicationSupportDirectory, temporaryDirectory: temporaryDirectory)
    }

    /// 纯函数版：给定两个候选目录，按「默认放得下就用默认，否则退到临时目录」挑一条。
    /// 测试用它构造任意用户名的容器路径。
    public func socketURL(applicationSupport: URL, temporaryDirectory: URL) -> URL {
        let primary = applicationSupport.appending(path: filename).standardizedFileURL
        if Self.fitsInSunPath(primary) { return primary }
        return temporaryDirectory.appending(path: filename).standardizedFileURL
    }

    /// `<Application Support>/<directoryName>/`。沙盒里系统已经把它映射进容器。
    public var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appending(path: identity.directoryName, directoryHint: .isDirectory)
            .standardizedFileURL
    }

    /// 退路目录：沙盒是容器的 `Data/tmp/`，非沙盒是 `_CS_DARWIN_USER_TEMP_DIR`。
    public var temporaryDirectory: URL {
        if identity.isSandboxed {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        }
        return Self.darwinUserTemporaryDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    /// `confstr(_CS_DARWIN_USER_TEMP_DIR)`：不看 `TMPDIR`，同一用户的任意进程算出来都一样。
    public static var darwinUserTemporaryDirectory: URL? {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// 客户端应当按顺序尝试的路径，与 `socketURL(applicationSupport:temporaryDirectory:)` 的选择
    /// 规则一一对应：先默认目录，再退路目录。
    ///
    /// - 沙盒：两条都写成 `~/` 开头（客户端 `expanduser`），与 `scripts/<ctl>` 的
    ///   `SOCKET_CANDIDATES` 逐字一致。
    /// - 非沙盒：第一条 `~/Library/Application Support/<dir>/<filename>`，第二条是本进程算出的
    ///   `_CS_DARWIN_USER_TEMP_DIR` 绝对路径（客户端应自己用 `confstr` 算，这里给出的是同一个值）。
    public func clientCandidates(for filename: String) -> [String] {
        let directory = identity.directoryName
        if identity.isSandboxed {
            let container = "~/Library/Containers/\(identity.bundleIdentifier)/Data"
            return [
                "\(container)/Library/Application Support/\(directory)/\(filename)",
                "\(container)/tmp/\(filename)",
            ]
        }
        var candidates = ["~/Library/Application Support/\(directory)/\(filename)"]
        if let temporary = Self.darwinUserTemporaryDirectory {
            candidates.append(temporary.appending(path: filename).path)
        }
        return candidates
    }

    /// 这条路径上是不是已经有活着的监听者。连得上就是有；`ECONNREFUSED`（残留文件）
    /// 和路径不存在都算没有。
    public static func isSocketServed(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        guard var address = UnixSocketAddress(path: url.path) else { return false }
        return address.withSockaddr { pointer, length in
            Darwin.connect(fd, pointer, length)
        } == 0
    }
}

/// `sockaddr_un` 的构造。路径超长时返回 nil（调用方据此报 `socket_path_too_long`）。
struct UnixSocketAddress {
    private var storage = sockaddr_un()
    private let length: Int

    init?(path: String) {
        let pathBytes = Array(path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: storage.sun_path) else { return nil }
        length = MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathBytes.count
        storage.sun_len = UInt8(length)
        storage.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &storage.sun_path) { $0.copyBytes(from: pathBytes) }
    }

    mutating func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        let length = socklen_t(length)
        return withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }
}

#endif
