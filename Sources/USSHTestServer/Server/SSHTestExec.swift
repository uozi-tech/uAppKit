import NIOConcurrencyHelpers
import NIOCore
import NIOSSH

/// 伪终端请求的内容。
public struct SSHTestPTYInfo: Sendable, Hashable {
    public var term: String
    public var columns: Int
    public var rows: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var modes: SSHTerminalModes

    public init(term: String, columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int, modes: SSHTerminalModes) {
        self.term = term
        self.columns = columns
        self.rows = rows
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.modes = modes
    }
}

/// 终端尺寸（window-change）。
public struct SSHTestWindowSize: Sendable, Hashable {
    public var columns: Int
    public var rows: Int
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        self.columns = columns
        self.rows = rows
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// exec / shell 处理函数的结局。
public enum SSHTestExit: Sendable, Hashable {
    /// 发 exit-status。
    case status(Int)
    /// 发 exit-signal。
    case signal(String)
    /// 什么都不报，直接 EOF + 关通道。
    case noStatus
}

/// 一条 exec / shell 通道在服务端这一侧。处理函数用它读标准输入、写输出。
public final class SSHTestExecContext: Sendable {
    /// exec 的命令；shell 是空串。
    public let command: String
    /// 已接受的环境变量。
    public let environment: [String: String]
    /// 伪终端（没要就是 nil）。
    public let pty: SSHTestPTYInfo?
    /// 客户端写来的数据，客户端发 EOF 或通道关闭时结束。
    public let stdin: AsyncStream<ByteBuffer>
    /// 客户端发来的 window-change。
    public let windowChanges: AsyncStream<SSHTestWindowSize>
    /// 底层子通道。
    public let channel: any Channel

    let receivedSignal = NIOLockedValueBox<String?>(nil)

    init(command: String, environment: [String: String], pty: SSHTestPTYInfo?, stdin: AsyncStream<ByteBuffer>,
         windowChanges: AsyncStream<SSHTestWindowSize>, channel: any Channel) {
        self.command = command
        self.environment = environment
        self.pty = pty
        self.stdin = stdin
        self.windowChanges = windowChanges
        self.channel = channel
    }

    /// 客户端发来的信号（RFC 4254 §6.9），收到时处理函数的任务会被取消。
    public var signal: String? { receivedSignal.withLockedValue { $0 } }

    /// 通道还开着。
    public var isActive: Bool { channel.isActive }

    /// 写 stdout（通道数据）。返回时数据已进连接；客户端窗口满时会等，所以能用来测背压。
    public func write(_ buffer: ByteBuffer) async throws {
        try await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
    }

    public func write(_ string: String) async throws {
        try await write(channel.allocator.buffer(string: string))
    }

    /// 写 stderr（扩展数据 type 1）。
    public func writeStderr(_ buffer: ByteBuffer) async throws {
        try await channel.writeAndFlush(SSHChannelData(type: .stdErr, data: .byteBuffer(buffer)))
    }

    public func writeStderr(_ string: String) async throws {
        try await writeStderr(channel.allocator.buffer(string: string))
    }

    /// 发 EOF。
    public func sendEOF() async {
        try? await channel.close(mode: .output)
    }

    /// 故障注入：不发 EOF、不报退出状态，直接 CHANNEL_CLOSE。客户端那边若还有没读走的数据，
    /// 就是「对端先关、本端还在排空缓冲」的情形。
    public func closeChannel() async {
        try? await channel.close()
    }
}

/// exec / shell 的处理函数。抛错按 `.status(1)` 结束；任务被取消（客户端关了通道、发了信号）时
/// 按收到的信号报 `.signal`，没有信号就不报状态。
public struct SSHTestExecHandler: Sendable {
    public let run: @Sendable (SSHTestExecContext) async throws -> SSHTestExit

    public init(_ run: @escaping @Sendable (SSHTestExecContext) async throws -> SSHTestExit) {
        self.run = run
    }

    /// 写好的输出与退出状态。
    public static func scripted(stdout: String = "", stderr: String = "", exitStatus: Int = 0) -> SSHTestExecHandler {
        SSHTestExecHandler { context in
            if !stdout.isEmpty { try await context.write(stdout) }
            if !stderr.isEmpty { try await context.writeStderr(stderr) }
            return .status(exitStatus)
        }
    }

    /// 把标准输入原样写回 stdout，直到 EOF，退出 0。
    public static var echo: SSHTestExecHandler {
        SSHTestExecHandler { context in
            for await chunk in context.stdin {
                try await context.write(chunk)
            }
            return .status(0)
        }
    }

    /// 交互 shell 的替身：逐块回显输入；输入里出现 Ctrl-D（0x04）就退出 0。
    public static var echoShell: SSHTestExecHandler {
        SSHTestExecHandler { context in
            for await chunk in context.stdin {
                try await context.write(chunk)
                if chunk.readableBytesView.contains(0x04) { return .status(0) }
            }
            return .status(0)
        }
    }

    /// 一直输出：每块 `chunk`，共 `count` 块（`nil` 不停），块之间可以停一下。
    public static func stream(chunk: ByteBuffer, count: Int?, interval: Duration? = nil,
                              exitStatus: Int = 0) -> SSHTestExecHandler {
        SSHTestExecHandler { context in
            var sent = 0
            while count.map({ sent < $0 }) ?? true {
                try Task.checkCancellation()
                try await context.write(chunk)
                sent += 1
                if let interval { try await Task.sleep(for: interval) }
            }
            return .status(exitStatus)
        }
    }

    /// 命令找不到（127）。
    public static var notFound: SSHTestExecHandler {
        SSHTestExecHandler { context in
            try await context.writeStderr("\(context.command): command not found\n")
            return .status(127)
        }
    }

    /// 按命令分派，没匹配上的交给 `fallback`。
    public static func routes(_ routes: [String: SSHTestExecHandler],
                              fallback: SSHTestExecHandler = .notFound) -> SSHTestExecHandler {
        SSHTestExecHandler { context in
            try await (routes[context.command] ?? fallback).run(context)
        }
    }
}
