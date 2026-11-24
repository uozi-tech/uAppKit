import NIOConcurrencyHelpers
import NIOCore

/// 一条连接的生灭状态：是否已连上、断开原因、断开观察者。`SSHClient` 和挂在 pipeline 上的
/// `SSHConnectionGuard` 共用同一份；前者在任意线程读，后者在 EventLoop 上写，所以用锁。
final class SSHConnectionLifecycle: Sendable {
    typealias Observer = @Sendable (SSHDisconnectReason) -> Void

    private struct State {
        var isConnected = false
        var localCloseRequested = false
        var reason: SSHDisconnectReason?
        var nextObserverID: UInt64 = 0
        var observers: [UInt64: Observer] = [:]
        var waiters: [CheckedContinuation<SSHDisconnectReason, Never>] = []
        var nextWaiterID: UInt64 = 0
        /// 限时等待的人（`waitForDisconnect(within:)`）：断开、到时、取消，谁先到谁把它取走。
        var boundedWaiters: [UInt64: CheckedContinuation<SSHDisconnectReason?, Never>] = [:]
    }

    private let state = NIOLockedValueBox(State())

    var isConnected: Bool { state.withLockedValue { $0.isConnected } }
    var disconnectReason: SSHDisconnectReason? { state.withLockedValue { $0.reason } }

    /// 认证成功。
    func markConnected() {
        state.withLockedValue { state in
            if state.reason == nil { state.isConnected = true }
        }
    }

    /// 本端开始关闭。返回 false 表示已经断开了（那时原因早就定了，不改）。
    @discardableResult
    func markLocalClose() -> Bool {
        state.withLockedValue { state in
            guard state.reason == nil else { return false }
            state.localCloseRequested = true
            return true
        }
    }

    var localCloseRequested: Bool { state.withLockedValue { $0.localCloseRequested } }

    /// 连接断了。只有第一次有效；观察者在锁外、在调用线程（EventLoop）上同步回调。
    func finish(_ reason: SSHDisconnectReason) {
        let (observers, waiters, bounded): ([Observer], [CheckedContinuation<SSHDisconnectReason, Never>],
                                            [CheckedContinuation<SSHDisconnectReason?, Never>]) =
            state.withLockedValue { state in
                guard state.reason == nil else { return ([], [], []) }
                state.reason = reason
                state.isConnected = false
                let observers = state.observers.sorted { $0.key < $1.key }.map(\.value)
                state.observers.removeAll()
                let waiters = state.waiters
                state.waiters.removeAll()
                let bounded = Array(state.boundedWaiters.values)
                state.boundedWaiters.removeAll()
                return (observers, waiters, bounded)
            }
        for observer in observers { observer(reason) }
        for waiter in waiters { waiter.resume(returning: reason) }
        for waiter in bounded { waiter.resume(returning: reason) }
    }

    /// 挂一个观察者。已经断开了就立刻（在调用线程上）回调一次，返回的 token 照常可以移除（无效果）。
    func addObserver(_ observer: @escaping Observer) -> UInt64 {
        let result: (UInt64, SSHDisconnectReason?) = state.withLockedValue { state in
            let id = state.nextObserverID
            state.nextObserverID += 1
            if let reason = state.reason { return (id, reason) }
            state.observers[id] = observer
            return (id, nil)
        }
        if let reason = result.1 { observer(reason) }
        return result.0
    }

    func removeObserver(_ id: UInt64) {
        _ = state.withLockedValue { $0.observers.removeValue(forKey: id) }
    }

    /// 最多等 `limit` 等到断开：断开了回原因；到时或所在任务被取消时回 nil（不吞取消：取消后立刻返回）。
    func waitForDisconnect(within limit: Duration) async -> SSHDisconnectReason? {
        if let reason = disconnectReason { return reason }
        let id = state.withLockedValue { state -> UInt64 in
            defer { state.nextWaiterID += 1 }
            return state.nextWaiterID
        }
        let take: @Sendable () -> CheckedContinuation<SSHDisconnectReason?, Never>? = { [state] in
            state.withLockedValue { $0.boundedWaiters.removeValue(forKey: id) }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SSHDisconnectReason?, Never>) in
                let immediate: SSHDisconnectReason?? = state.withLockedValue { state in
                    if let reason = state.reason { return .some(reason) }
                    if Task.isCancelled { return .some(nil) }
                    state.boundedWaiters[id] = continuation
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                    return
                }
                Task {
                    try? await Task.sleep(for: limit)
                    take()?.resume(returning: nil)
                }
            }
        } onCancel: {
            take()?.resume(returning: nil)
        }
    }

    /// 等到断开。
    func waitForDisconnect() async -> SSHDisconnectReason {
        await withCheckedContinuation { continuation in
            let reason: SSHDisconnectReason? = state.withLockedValue { state in
                if let reason = state.reason { return reason }
                state.waiters.append(continuation)
                return nil
            }
            if let reason { continuation.resume(returning: reason) }
        }
    }
}
