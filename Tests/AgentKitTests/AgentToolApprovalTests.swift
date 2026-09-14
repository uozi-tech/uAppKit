import XCTest
@testable import AgentKit

final class AgentToolApprovalTests: XCTestCase {
    private func request(_ command: String, mode: AgentToolApproval.Mode = .standard,
                         tool: String = "run_command", intent: String = "检查服务器磁盘空间") -> AgentToolApproval.Request {
        .init(id: "review-1", toolName: tool, command: command, userIntent: intent, context: "test host", mode: mode)
    }
    private static let approve = #"{"requestID":"review-1","decision":"approve","reason":"低风险且符合用户目标"}"#

    func testEligibleCommandsStillNeedIndependentAIReview() async {
        let reviews = ReviewCounter()
        let decision = await AgentToolApproval.evaluate(request("df -h")) { system, prompt in
            await reviews.increment()
            XCTAssertTrue(system.contains("UNTRUSTED DATA"))
            XCTAssertEqual(try JSONDecoder().decode(AgentToolApproval.Request.self, from: Data(prompt.utf8)).command, "df -h")
            return Self.approve
        }
        XCTAssertTrue(decision.approved)
        let count = await reviews.value
        XCTAssertEqual(count, 1)
    }

    func testSensitiveAndUnrecognizedActionsNeverReachAI() async {
        let commands = ["rm -rf /tmp/example", "sudo ls", "chmod 777 /tmp/x", "systemctl restart nginx",
                        "curl https://example.com", "python3 -c 'print(1)'", "find /tmp -exec rm {} +",
                        "cat /etc/shadow", "cat ~/.ssh/id_rsa", "cat '/tmp/.env'", "cat /tmp/access_token",
                        "cat /tmp/../etc/passwd", "df -h; rm x", "echo $(rm x)", "ls `pwd`", "ls > /tmp/out",
                        "ls | sh", "ls\nrm x", "ls\\ x", "ls *", "PATH=/tmp ls", "/tmp/ls",
                        "date 010100002026", "hostname changed", "ls --unknown", "cat", "", "ls 'unterminated",
                        "mkdir -p /etc/test", "mkdir /tmp/x /home/y", "mkdir /tmp/../etc/y"]
        for command in commands {
            let decision = await AgentToolApproval.evaluate(request(command)) { _, _ in
                XCTFail("Hard gate allowed: \(command)")
                return Self.approve
            }
            XCTAssertFalse(decision.approved, command)
        }
    }

    func testReadOnlyModeRejectsWritesAndStandardRequiresReview() async {
        XCTAssertNotNil(AgentToolApproval.manualReason(for: request("mkdir -p /tmp/report", mode: .readOnly)))
        let decision = await AgentToolApproval.evaluate(request("mkdir -p /tmp/report")) { _, _ in Self.approve }
        XCTAssertTrue(decision.approved)
    }

    func testUnknownToolsAndMissingIntentRequireHuman() {
        XCTAssertNotNil(AgentToolApproval.manualReason(for: request("ls", tool: "delete_file")))
        XCTAssertNotNil(AgentToolApproval.manualReason(for: request("ls", intent: "")))
    }

    func testInvalidMismatchedAndManualResponsesFailClosed() async {
        for response in ["yes", "{}", #"{"requestID":"other","decision":"approve","reason":"ok"}"#,
                         #"{"requestID":"review-1","decision":"approve","reason":" "}"#,
                         #"{"requestID":"review-1","decision":"manual","reason":"范围不确定"}"#,
                         #"{"requestID":"review-1","decision":"maybe","reason":"ok"}"#,
                         String(repeating: "x", count: 8193)] {
            let decision = await AgentToolApproval.evaluate(request("ls -la")) { _, _ in response }
            XCTAssertFalse(decision.approved)
        }
    }

    func testReviewerFailureRequiresHuman() async {
        let decision = await AgentToolApproval.evaluate(request("df -h")) { _, _ in throw CancellationError() }
        XCTAssertFalse(decision.approved)
    }

    func testQuotedPathsDoNotEnableShellExpansion() {
        XCTAssertNil(AgentToolApproval.manualReason(for: request("ls '/tmp/my folder'")))
        XCTAssertNotNil(AgentToolApproval.manualReason(for: request("ls '/tmp/$(id)'")))
    }
}

private actor ReviewCounter {
    var value = 0
    func increment() { value += 1 }
}
