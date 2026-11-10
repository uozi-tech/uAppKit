import Foundation

/// 给事件流加静默超时：每收到一个**事件**续期一次，连续 `timeout` 没有事件就以
/// `timeoutError` 结束，并取消仍挂在底层的生产者。
///
/// 这是按事件计时的版本，给不经 `LLMWireTransport` 的流用（测试替身、自定义后端）。
/// 走 `LLMWireTransport.stream` 的请求请用它的 `idleTimeout` 参数：传输层看得见不产出事件的
/// 进展（thinking 与工具参数的增量、思考期间的 `ping`），不会把「模型还在想」判成卡住；
/// 两层不要叠用，外面再套这一层会把长思考掐掉。
public func withIdleTimeout(
    _ stream: AsyncThrowingStream<LLMEvent, Error>,
    timeout: Duration,
    timeoutError: Error = LLMWireError.streamIdleTimeout
) -> AsyncThrowingStream<LLMEvent, Error> {
    AsyncThrowingStream { continuation in
        let gate = LLMStreamIdleGate(timeout: timeout, timeoutError: timeoutError, continuation: continuation)
        let producer = Task {
            await gate.start()
            do {
                for try await event in stream {
                    continuation.yield(event)
                    await gate.touch()
                }
                if await gate.complete() { continuation.finish() }
            } catch {
                if await gate.complete() { continuation.finish(throwing: error) }
            }
        }
        Task { await gate.attach(producer) }
        continuation.onTermination = { _ in
            Task { await gate.cancel() }
        }
    }
}

/// 静默看门狗 + 「谁来结束这条流」的仲裁。`touch()` 续期；超时由它结束 continuation 并取消
/// 生产者；生产者自己结束前先 `complete()`，拿到 true 才去结束 continuation。
/// `timeout` 为 nil 时不计时，只做仲裁。
actor LLMStreamIdleGate {
    private let timeout: Duration?
    private let timeoutError: Error
    private let continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    private var producer: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var isFinished = false

    init(timeout: Duration?, timeoutError: Error,
         continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation) {
        self.timeout = timeout
        self.timeoutError = timeoutError
        self.continuation = continuation
    }

    func attach(_ producer: Task<Void, Never>) {
        guard !isFinished else {
            producer.cancel()
            return
        }
        self.producer = producer
    }

    func start() {
        armWatchdog()
    }

    /// 有进展，重新计时。
    func touch() {
        guard !isFinished else { return }
        armWatchdog()
    }

    /// 返回 true 表示调用方赢得了落定权，应结束 continuation。
    func complete() -> Bool {
        guard !isFinished else { return false }
        isFinished = true
        watchdog?.cancel()
        watchdog = nil
        producer = nil
        return true
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        watchdog?.cancel()
        watchdog = nil
        producer?.cancel()
        producer = nil
    }

    private func armWatchdog() {
        watchdog?.cancel()
        guard let timeout else { return }
        watchdog = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.timeOut()
        }
    }

    private func timeOut() {
        guard !isFinished else { return }
        isFinished = true
        watchdog = nil
        continuation.finish(throwing: timeoutError)
        producer?.cancel()
        producer = nil
    }
}
