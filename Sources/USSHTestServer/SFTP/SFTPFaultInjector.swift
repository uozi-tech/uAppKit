import NIOConcurrencyHelpers
import USSHCore

/// 测试服务端认得的操作，用来给故障注入挑对象。
public enum SFTPServerOperation: Hashable, Sendable {
    case open, close, read, write, lstat, fstat, setstat, fsetstat
    case opendir, readdir, remove, mkdir, rmdir, realpath, stat, rename, readlink, symlink
    /// SSH_FXP_EXTENDED，带扩展名（`posix-rename@openssh.com` 等）。
    case extended(String)
}

/// 测试服务端的故障注入。线程安全，可以在会话进行中随时改；规则对之后到达的请求生效。
///
/// 每条规则可以只针对某个操作（`operation`），也可以传 nil 针对全部操作。
/// 「第 N 次」从规则装上之后开始数，命中之后规则自动作废（`times` 次）。
public final class SFTPFaultInjector: Sendable {
    struct Decision {
        var delay: Duration?
        var failure: SFTPServerStatusError?
        var dropConnection = false
        var withhold = false
        var readLengthCap: Int?
    }

    private struct CountdownRule {
        var operation: SFTPServerOperation?
        /// 还要放过几次才命中（0 = 下一次就命中）。
        var skip: Int
        /// 命中几次后作废（nil = 一直命中）。
        var remaining: Int?
        var failure: SFTPServerStatusError?
    }

    private struct State {
        var delays: [(operation: SFTPServerOperation?, delay: Duration)] = []
        var failures: [CountdownRule] = []
        var drops: [CountdownRule] = []
        var withheld: [SFTPServerOperation?] = []
        var readLengthCap: Int?
        var reverseBatchSize: Int?
        var counts: [SFTPServerOperation: Int] = [:]
    }

    private let state = NIOLockedValueBox(State())

    public init() {}

    // MARK: 装规则

    /// 给匹配的请求的回答加一段延迟（不阻塞别的请求：先算完，延迟后才写回答）。传 nil 时长取消。
    public func delayResponses(of operation: SFTPServerOperation? = nil, by delay: Duration?) {
        state.withLockedValue { state in
            state.delays.removeAll { $0.operation == operation }
            if let delay { state.delays.append((operation, delay)) }
        }
    }

    /// 让匹配的第 `occurrence` 个请求（从现在起数，1 起）回指定状态，连续 `times` 次（nil = 之后一直）。
    public func fail(
        _ operation: SFTPServerOperation? = nil,
        occurrence: Int = 1,
        times: Int? = 1,
        with code: SFTPStatusCode,
        message: String = "injected failure"
    ) {
        state.withLockedValue { state in
            state.failures.append(CountdownRule(
                operation: operation, skip: max(0, occurrence - 1), remaining: times,
                failure: SFTPServerStatusError(code, message)))
        }
    }

    /// 收到匹配的第 `occurrence` 个请求时不回答、直接关掉通道（模拟请求进行到一半断线）。
    public func dropConnection(on operation: SFTPServerOperation? = nil, occurrence: Int = 1) {
        state.withLockedValue { state in
            state.drops.append(CountdownRule(operation: operation, skip: max(0, occurrence - 1), remaining: 1, failure: nil))
        }
    }

    /// 匹配的请求照常执行，但永远不回答（测取消、测关闭时的在途请求）。
    public func withholdResponses(of operation: SFTPServerOperation? = nil, _ enabled: Bool = true) {
        state.withLockedValue { state in
            state.withheld.removeAll { $0 == operation }
            if enabled { state.withheld.append(operation) }
        }
    }

    /// 每个 READ 最多给这么多字节（强制短读）。nil 取消。
    public func limitReadLength(to length: Int?) {
        state.withLockedValue { $0.readLengthCap = length }
    }

    /// 攒满 `batchSize` 个回答再倒序写出（保证乱序）。nil 取消；取消时攒着的回答立刻按原序写出。
    ///
    /// 只要请求数凑不满一批，攒着的回答就不会发出——用的时候让请求数是批大小的整数倍。
    public func reverseResponseOrder(batchSize: Int?) {
        state.withLockedValue { $0.reverseBatchSize = batchSize.map { max(1, $0) } }
    }

    /// 清掉全部规则（计数保留）。
    public func reset() {
        state.withLockedValue { state in
            let counts = state.counts
            state = State()
            state.counts = counts
        }
    }

    /// 到目前为止各操作收到了多少个请求。
    public var requestCounts: [SFTPServerOperation: Int] {
        state.withLockedValue { $0.counts }
    }

    public func requestCount(of operation: SFTPServerOperation) -> Int {
        state.withLockedValue { $0.counts[operation] ?? 0 }
    }

    // MARK: 服务端用

    var reverseBatchSize: Int? {
        state.withLockedValue { $0.reverseBatchSize }
    }

    func decide(for operation: SFTPServerOperation) -> Decision {
        state.withLockedValue { state in
            state.counts[operation, default: 0] += 1
            var decision = Decision()
            decision.delay = state.delays.last { $0.operation == nil || $0.operation == operation }?.delay
            decision.withhold = state.withheld.contains { $0 == nil || $0 == operation }
            decision.readLengthCap = state.readLengthCap
            decision.dropConnection = Self.consume(&state.drops, operation) != nil
            decision.failure = Self.consume(&state.failures, operation)?.failure
            return decision
        }
    }

    /// 让匹配的规则走一步；命中时返回规则（并按 `remaining` 作废）。
    private static func consume(_ rules: inout [CountdownRule], _ operation: SFTPServerOperation) -> CountdownRule? {
        guard let index = rules.firstIndex(where: { $0.operation == nil || $0.operation == operation }) else { return nil }
        if rules[index].skip > 0 {
            rules[index].skip -= 1
            return nil
        }
        let hit = rules[index]
        if let remaining = hit.remaining {
            if remaining <= 1 { rules.remove(at: index) } else { rules[index].remaining = remaining - 1 }
        }
        return hit
    }
}
