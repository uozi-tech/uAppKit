import Foundation
import XCTest
@testable import AgentKit

final class LLMThinkingBlockTests: XCTestCase {
    func testAccumulatesThinkingAndSignatureDeltas() {
        var acc = LLMThinkingBlockAccumulator()
        XCTAssertTrue(acc.start(index: 0, block: ["type": "thinking", "thinking": "", "signature": ""]))
        XCTAssertTrue(acc.delta(index: 0, delta: ["type": "thinking_delta", "thinking": "let me "]))
        XCTAssertTrue(acc.delta(index: 0, delta: ["type": "thinking_delta", "thinking": "check"]))
        XCTAssertTrue(acc.delta(index: 0, delta: ["type": "signature_delta", "signature": "sig=="]))
        // 别的块的 delta / stop 不归它管。
        XCTAssertFalse(acc.start(index: 1, block: ["type": "tool_use", "id": "t1"]))
        XCTAssertFalse(acc.delta(index: 1, delta: ["type": "input_json_delta", "partial_json": "{}"]))
        XCTAssertNil(acc.stop(index: 1))

        let block = acc.stop(index: 0)
        XCTAssertEqual(block, LLMThinkingBlock(thinking: "let me check", signature: "sig=="))
        XCTAssertNil(acc.stop(index: 0))
    }

    func testRedactedBlockRoundTripsVerbatim() {
        var acc = LLMThinkingBlockAccumulator()
        acc.start(index: 2, block: ["type": "redacted_thinking", "data": "opaque"])
        let block = acc.stop(index: 2)
        XCTAssertEqual(block?.anthropicJSON["type"] as? String, "redacted_thinking")
        XCTAssertEqual(block?.anthropicJSON["data"] as? String, "opaque")
    }

    func testEmptyThinkingTextIsKept() {
        // 新模型默认 display: omitted —— 文本为空，签名才是内容；空串也要原样回传。
        let json = LLMThinkingBlock(thinking: "", signature: "abc").anthropicJSON
        XCTAssertEqual(json["type"] as? String, "thinking")
        XCTAssertEqual(json["thinking"] as? String, "")
        XCTAssertEqual(json["signature"] as? String, "abc")
    }

    func testCollectorKeepsThinkingBlocks() async throws {
        let block = LLMThinkingBlock(thinking: "", signature: "s")
        let stream = AsyncThrowingStream<LLMEvent, Error> { c in
            c.yield(.thinking(block))
            c.yield(.text("hi"))
            c.finish()
        }
        let collected = try await CollectingLLMClient.collect(stream)
        XCTAssertEqual(collected.thinking, [block])
        XCTAssertEqual(collected.text, "hi")
    }
}
