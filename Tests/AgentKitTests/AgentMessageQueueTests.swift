import XCTest
@testable import AgentKit

final class AgentMessageQueueTests: XCTestCase {
    private func texts(_ queue: AgentMessageQueue) -> [String] { queue.items.map(\.text) }

    func testEnqueueTrimsAndIgnoresBlank() {
        var queue = AgentMessageQueue()
        XCTAssertEqual(queue.enqueue("  hi \n")?.text, "hi")
        XCTAssertNil(queue.enqueue("  \n "))
        XCTAssertEqual(texts(queue), ["hi"])
        XCTAssertEqual(queue.items.first?.delivery, .afterTurn)
    }

    func testNextStepMessagesStayAheadInSubmissionOrder() {
        var queue = AgentMessageQueue()
        queue.enqueue("a")
        queue.enqueue("now-1", delivery: .nextStep)
        queue.enqueue("b")
        queue.enqueue("now-2", delivery: .nextStep)
        XCTAssertEqual(texts(queue), ["now-1", "now-2", "a", "b"])
    }

    func testSendAtNextStepMovesBehindOtherUrgentOnes() {
        var queue = AgentMessageQueue()
        queue.enqueue("a")
        queue.enqueue("b")
        queue.enqueue("c")
        let b = queue.items[1].id
        let c = queue.items[2].id

        XCTAssertTrue(queue.sendAtNextStep(id: c))
        XCTAssertTrue(queue.sendAtNextStep(id: b))
        XCTAssertEqual(texts(queue), ["c", "b", "a"])
        XCTAssertEqual(queue.items.map(\.delivery), [.nextStep, .nextStep, .afterTurn])

        XCTAssertFalse(queue.sendAtNextStep(id: c), "已经是下一步送达的不再挪动")
        XCTAssertFalse(queue.sendAtNextStep(id: UUID()))
        XCTAssertEqual(texts(queue), ["c", "b", "a"])
    }

    func testTakeNextStepTakesOnlyUrgentOnes() {
        var queue = AgentMessageQueue()
        queue.enqueue("a")
        XCTAssertTrue(queue.takeNextStep().isEmpty)
        XCTAssertEqual(texts(queue), ["a"], "普通排队消息不在一步结束时送出")

        queue.enqueue("now-1", delivery: .nextStep)
        queue.enqueue("now-2", delivery: .nextStep)
        XCTAssertEqual(queue.takeNextStep().map(\.text), ["now-1", "now-2"])
        XCTAssertEqual(texts(queue), ["a"])
    }

    func testTakeNextTurnDrainsUrgentBatchThenOneAtATime() {
        var queue = AgentMessageQueue()
        queue.enqueue("a")
        queue.enqueue("b")
        queue.enqueue("now-1", delivery: .nextStep)
        queue.enqueue("now-2", delivery: .nextStep)

        XCTAssertEqual(queue.takeNextTurn().map(\.text), ["now-1", "now-2"])
        XCTAssertEqual(queue.takeNextTurn().map(\.text), ["a"])
        XCTAssertEqual(queue.takeNextTurn().map(\.text), ["b"])
        XCTAssertTrue(queue.takeNextTurn().isEmpty)
        XCTAssertTrue(queue.isEmpty)
    }

    func testRemove() {
        var queue = AgentMessageQueue()
        queue.enqueue("a")
        queue.enqueue("b")
        let a = queue.items[0].id
        XCTAssertEqual(queue.remove(id: a)?.text, "a")
        XCTAssertNil(queue.remove(id: a))
        XCTAssertEqual(texts(queue), ["b"])
        queue.removeAll()
        XCTAssertTrue(queue.isEmpty)
    }
}
