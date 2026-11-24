import NIOConcurrencyHelpers
import NIOCore

// 关闭不能等对端：对端不回 CHANNEL_CLOSE（链路被黑洞、服务端卡死）时，NIOSSH 的子通道要等到整条连接断了才算关，
// 而那可能要等保活判死（几十秒到几分钟），没开保活就是永远。各个 `close()` 都只等对端配合
// `SSHClient.closeGracePeriod`，之后在本端收尾：在途的请求失败、之后的操作立刻失败、`isActive` 报 false。
// 留下的 NIOSSH 子通道随连接一起拆掉。

/// 一次性的「已关」信号：关了就一直是关的，等它的人在关的那一刻放行。
final class SSHCloseSignal: Sendable {
    private struct State {
        var closed = false
        var nextID: UInt64 = 0
        var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = NIOLockedValueBox(State())

    var isClosed: Bool { state.withLockedValue { $0.closed } }

    func markClosed() {
        let waiters = state.withLockedValue { state -> [CheckedContinuation<Void, Never>] in
            guard !state.closed else { return [] }
            state.closed = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }

    /// 等到关；所在任务被取消时立刻返回。
    func wait() async {
        let id = state.withLockedValue { state -> UInt64 in
            defer { state.nextID += 1 }
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = state.withLockedValue { state -> Bool in
                    if state.closed || Task.isCancelled { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            state.withLockedValue { $0.waiters.removeValue(forKey: id) }?.resume()
        }
    }
}

extension EventLoopFuture {
    /// 最多等 `limit` 等它完成（成功失败都算）：完成了回 true，到时或所在任务被取消时回 false。不动 future 本身。
    func completes(within limit: Duration) async -> Bool {
        let result = SSHBoundedResult()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                result.set(continuation)
                self.whenComplete { _ in result.resolve(true) }
                Task {
                    try? await Task.sleep(for: limit)
                    result.resolve(false)
                }
            }
        } onCancel: {
            result.resolve(false)
        }
    }
}

/// `completes(within:)` 的结果：谁先到算谁，只恢复一次。
private final class SSHBoundedResult: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Bool, Never>?
        var value: Bool?
    }

    private let state = NIOLockedValueBox(State())

    func set(_ continuation: CheckedContinuation<Bool, Never>) {
        let ready = state.withLockedValue { state -> Bool? in
            if let value = state.value { return value }
            state.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(returning: ready) }
    }

    func resolve(_ value: Bool) {
        let continuation = state.withLockedValue { state -> CheckedContinuation<Bool, Never>? in
            guard state.value == nil else { return nil }
            state.value = value
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(returning: value)
    }
}
