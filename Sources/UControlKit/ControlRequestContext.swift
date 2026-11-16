// macOS 专用：整份文件用平台条件包住，理由同 `UAppKitBridge`。
#if os(macOS)

import Darwin
import Foundation

/// 文件里的一段 `[offset, offset + length)`：续传区间与进度事件里的「已完成段」。
public struct ControlByteRange: Codable, Sendable, Equatable {
    public var offset: Int64
    public var length: Int64

    public var end: Int64 { offset + length }

    public init(offset: Int64, length: Int64) {
        self.offset = offset
        self.length = length
    }
}

/// 处理期间服务端往连接里写的进度行（一行一个 JSON，与最终响应同一条连接）：
/// `{"event":"progress","bytes":…,"totalBytes":…,"done":[{"offset":…,"length":…}]}`。
/// `done` 是**自上一行以来**新完成的段，客户端据此记续传账。
public struct ControlProgressEvent: Codable, Sendable, Equatable {
    public var event = "progress"
    public var bytes: Int64
    public var totalBytes: Int64?
    public var done: [ControlByteRange]

    public init(bytes: Int64, totalBytes: Int64?, done: [ControlByteRange]) {
        self.bytes = bytes
        self.totalBytes = totalBytes
        self.done = done
    }
}

/// 一条 IPC 请求在 socket 之外附带的东西：`SCM_RIGHTS` 交过来的 fd，和往这条连接回写进度的
/// 通道。`ControlSocketServer` 建它、用 `@TaskLocal` 挂在 handler 的任务上；handler 取 fd、报进度。
///
/// **fd 的归属**：`takeFileDescriptor()` 把它交给调用方，之后由调用方负责 `close`；没被取走的由
/// `closeUntaken()` 关 —— 服务端在 handler **真正返回之后**才调它，而不是在 `handler_timeout`
/// 的时候，否则仍在跑的传输会写进一个已关闭、号码随时被复用的 fd。
///
/// **进度是可合并的**：handler 每完成一段就 `recordSegment`，服务端的监督定时器每拍取走一次
/// （`drainProgress`），把这段时间攒下的已完成段拼成一行发出去。客户端慢、socket 缓冲满的时候
/// 就少发几行，已完成段不会丢 —— 它们留在这里等下一行。
public final class ControlRequestContext: @unchecked Sendable {
    @TaskLocal public static var current: ControlRequestContext?

    private let lock = NSLock()
    private var fds: [Int32]
    private var bytes: Int64 = 0
    private var totalBytes: Int64?
    private var done: [ControlByteRange] = []
    private var dirty = false

    public init(fileDescriptors: [Int32]) {
        self.fds = fileDescriptors
    }

    /// 取走随请求交来的第一个 fd（所有权随之转移）。没有就是 nil。
    public func takeFileDescriptor() -> Int32? {
        lock.withLock { fds.isEmpty ? nil : fds.removeFirst() }
    }

    /// 关掉没人取走的 fd。可重复调用。
    public func closeUntaken() {
        let leftovers = lock.withLock { () -> [Int32] in
            defer { fds.removeAll() }
            return fds
        }
        for fd in leftovers { Darwin.close(fd) }
    }

    public func setTotal(_ size: Int64) {
        lock.withLock {
            totalBytes = size
            dirty = true
        }
    }

    /// 一段完成了。顺带打一次活动脉冲：有进度当然就不是静默。
    public func recordSegment(_ range: ControlByteRange) {
        lock.withLock {
            bytes += range.length
            done.append(range)
            dirty = true
        }
        ControlActivity.touch()
    }

    /// 取走自上次以来的进度，编成一行（带结尾 `\n`）。没有新东西返回 nil。
    public func drainProgress() -> Data? {
        let event: ControlProgressEvent? = lock.withLock {
            guard dirty else { return nil }
            defer {
                done.removeAll()
                dirty = false
            }
            return ControlProgressEvent(bytes: bytes, totalBytes: totalBytes, done: done)
        }
        guard let event, var data = try? JSONEncoder().encode(event) else { return nil }
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

#endif
