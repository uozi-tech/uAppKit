import Foundation

/// 一条尚未发出的排队消息：Agent 忙碌时用户提交的输入。运行期纯内存，不落库。
public struct AgentQueuedMessage: Identifiable, Equatable, Sendable {
    /// 这条消息什么时候交给模型。
    public enum Delivery: Equatable, Sendable {
        /// 等整轮结束（含全部工具续轮）后，作为新一轮发出。
        case afterTurn
        /// 不打断在途回复：当前这一步的工具结果齐了、下一次请求模型之前并入会话。
        /// 本轮没有下一步（模型直接答完）时，等同排在队首的 `afterTurn`。
        case nextStep
    }

    public let id: UUID
    public let text: String
    public internal(set) var delivery: Delivery

    public init(id: UUID = UUID(), text: String, delivery: Delivery = .afterTurn) {
        self.id = id
        self.text = text
        self.delivery = delivery
    }
}

/// Agent 忙碌期间的待发队列。只管顺序与送达时机，不碰会话、不发请求 —— 状态机在两个
/// 时点来取：
///
/// - **一步结束**（本条 assistant 消息的工具调用全部有了结果、还没发下一次请求）：
///   `takeNextStep()`，取到的消息作为用户消息并进会话再续轮。
/// - **整轮结束**（回到空闲 / 失败）：`takeNextTurn()`，取到的消息开新一轮。
///
/// 不变量：`nextStep` 的消息总排在 `afterTurn` 之前，各自内部保持提交顺序。所以
/// 「整轮结束时取队首」天然先送「立即发送」的那几条。
public struct AgentMessageQueue: Equatable, Sendable {
    public private(set) var items: [AgentQueuedMessage] = []

    public init() {}

    public var isEmpty: Bool { items.isEmpty }

    /// 入队。首尾空白去掉，只剩空白的不入队（返回 nil）。
    @discardableResult
    public mutating func enqueue(_ text: String,
                                 delivery: AgentQueuedMessage.Delivery = .afterTurn) -> AgentQueuedMessage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = AgentQueuedMessage(text: trimmed, delivery: delivery)
        switch delivery {
        case .afterTurn: items.append(item)
        case .nextStep: items.insert(item, at: nextStepCount)
        }
        return item
    }

    @discardableResult
    public mutating func remove(id: UUID) -> AgentQueuedMessage? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    public mutating func removeAll() {
        items.removeAll()
    }

    /// 把一条已排队的消息改成「下一步送达」，挪到同类消息的末尾。已经是的不动。
    /// - Returns: 队列是否变了。
    @discardableResult
    public mutating func sendAtNextStep(id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].delivery != .nextStep else { return false }
        var item = items.remove(at: index)
        item.delivery = .nextStep
        items.insert(item, at: nextStepCount)
        return true
    }

    /// 一步结束时取：全部「下一步送达」的消息，按提交顺序。没有则空。
    public mutating func takeNextStep() -> [AgentQueuedMessage] {
        let count = nextStepCount
        guard count > 0 else { return [] }
        let taken = Array(items.prefix(count))
        items.removeFirst(count)
        return taken
    }

    /// 整轮结束时取下一轮要发的消息：有「下一步送达」的就一次取完（它们本该更早送到，
    /// 不该再一条一轮地排），否则只取队首一条。
    public mutating func takeNextTurn() -> [AgentQueuedMessage] {
        let urgent = takeNextStep()
        if !urgent.isEmpty { return urgent }
        return items.isEmpty ? [] : [items.removeFirst()]
    }

    private var nextStepCount: Int {
        items.prefix(while: { $0.delivery == .nextStep }).count
    }
}
