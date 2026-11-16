import AgentKit
import AgentProviders
import XCTest
@testable import AgentRuntime

/// 审批的类型层：指纹、展示正文、shell 命令策略（git 只读白名单复用）、审批队列。
final class AgentApprovalTests: XCTestCase {
    func testFingerprintIsExactRequestAndIgnoresSurroundingWhitespace() {
        let a = AgentApprovalRequest(toolCallID: "1", toolName: "write", arguments: "{}", subject: " SELECT 1 ")
        let b = AgentApprovalRequest(toolCallID: "2", toolName: "write", arguments: #"{"x":1}"#, subject: "SELECT 1")
        let c = AgentApprovalRequest(toolCallID: "3", toolName: "write", arguments: "{}", subject: "SELECT 2")
        let d = AgentApprovalRequest(toolCallID: "4", toolName: "other", arguments: "{}", subject: "SELECT 1")
        XCTAssertEqual(a.fingerprint, b.fingerprint)
        XCTAssertNotEqual(a.fingerprint, c.fingerprint)
        XCTAssertNotEqual(a.fingerprint, d.fingerprint)
        XCTAssertEqual(a.fingerprint.count, 64)
    }

    func testDisplayTextPrefersSubjectThenPrettyArguments() {
        XCTAssertEqual(AgentApprovalRequest(toolCallID: "1", toolName: "t", arguments: "{}", subject: "git push").displayText,
                       "git push")
        let pretty = AgentApprovalRequest(toolCallID: "1", toolName: "t", arguments: #"{"b":1,"a":"x"}"#).displayText
        XCTAssertEqual(pretty, "{\n  \"a\" : \"x\",\n  \"b\" : 1\n}")
        XCTAssertEqual(AgentApprovalRequest(toolCallID: "1", toolName: "t", arguments: "not json").displayText, "not json")
        XCTAssertNil(AgentApprovalRequest(toolCallID: "1", toolName: "t", arguments: #"{"reason":"  "}"#).reason)
    }

    // MARK: - ShellCommandApprovalPolicy

    private func gitRequest(_ args: [String]) -> AgentApprovalRequest {
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: ["args": args]), as: UTF8.self)
        return AgentApprovalRequest(toolCallID: "c", toolName: "run_git", arguments: json)
    }

    private var gitPolicy: ShellCommandApprovalPolicy {
        ShellCommandApprovalPolicy(toolNames: ["run_git"], commandPrefix: "git ",
                                   command: ShellCommandApprovalPolicy.argumentArray("args"))
    }

    func testGitReadOnlyAllowlistIsReusedForRunGit() async {
        for args in [["status"], ["log", "--oneline", "-n", "20"], ["diff", "HEAD~1"], ["show", "HEAD:README.md"],
                     ["branch", "--list"], ["-C", "/tmp/repo with space", "status"]] {
            let verdict = await gitPolicy.evaluate(gitRequest(args))
            XCTAssertEqual(verdict, .allow(reason: AgentToolApproval.readOnlyReason), "\(args)")
        }
    }

    func testGitWritesAndEscapesGoToUser() async {
        for args in [["push"], ["commit", "-m", "x"], ["log", "--output=/tmp/x"], ["-c", "core.pager=sh", "log"],
                     ["branch", "-D", "main"], ["clean", "-fd"]] {
            let verdict = await gitPolicy.evaluate(gitRequest(args))
            if case .allow = verdict { XCTFail("\(args) 不该自动放行") }
        }
    }

    func testShellPolicyIgnoresOtherToolsAndMalformedArguments() async {
        let other = AgentApprovalRequest(toolCallID: "c", toolName: "write", arguments: #"{"args":["status"]}"#)
        let otherVerdict = await gitPolicy.evaluate(other)
        XCTAssertEqual(otherVerdict, .askUser(note: nil))
        let mixed = AgentApprovalRequest(toolCallID: "c", toolName: "run_git", arguments: #"{"args":["status",1]}"#)
        let mixedVerdict = await gitPolicy.evaluate(mixed)
        XCTAssertEqual(mixedVerdict, .askUser(note: nil))
    }

    func testShellPolicyAIReviewCanApproveButNotOverrideHardRules() async {
        let approving = ShellCommandApprovalPolicy(
            mode: .standard,
            intent: { _ in ("部署服务", "web-1") },
            review: { _, envelope in
                let id = (try JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any])?["id"] as? String
                return #"{"requestID":"\#(id ?? "")","decision":"approve","reason":"符合任务"}"#
            })
        let restart = AgentApprovalRequest(toolCallID: "c", toolName: "run_command",
                                           arguments: #"{"command":"systemctl restart nginx"}"#)
        let restartVerdict = await approving.evaluate(restart)
        XCTAssertEqual(restartVerdict, .allow(reason: "符合任务"))
        let destructive = AgentApprovalRequest(toolCallID: "c", toolName: "run_command",
                                               arguments: #"{"command":"rm -rf /var/lib/app"}"#)
        let destructiveVerdict = await approving.evaluate(destructive)
        if case .allow = destructiveVerdict { XCTFail("硬规则不能被 AI 放宽") }
    }

    func testShellJoinQuotesLikeSh() {
        XCTAssertEqual(ShellCommandApprovalPolicy.shellJoin(["log", "--format=%H", "a b", "it's", ""]),
                       #"log --format=%H 'a b' 'it'\''s' ''"#)
    }

    // MARK: - 审批队列

    @MainActor
    func testQueueCancellationResolvesAsDenied() async {
        let queue = AgentApprovalQueue()
        let request = AgentApprovalRequest(toolCallID: "c", toolName: "t", arguments: "{}")
        let task = Task { await queue.present(request) }
        while queue.pending == nil { await Task.yield() }
        task.cancel()
        let decision = await task.value
        XCTAssertEqual(decision, .denied)
        while queue.pending != nil { await Task.yield() }
    }

    @MainActor
    func testQueueIgnoresStaleDecisionIDs() async {
        let queue = AgentApprovalQueue()
        let task = Task { await queue.present(AgentApprovalRequest(toolCallID: "c", toolName: "t", arguments: "{}")) }
        while queue.pending == nil { await Task.yield() }
        queue.decide(.granted, for: UUID())
        XCTAssertNotNil(queue.pending)
        queue.decide(.grantedForSession, for: queue.pending!.id)
        let decision = await task.value
        XCTAssertEqual(decision, .grantedForSession)
    }

    func testAutoDenyGate() async {
        let decision = await AutoDenyApprovalGate().request(AgentApprovalRequest(toolCallID: "c", toolName: "t",
                                                                                  arguments: "{}"))
        XCTAssertEqual(decision, .denied)
    }

    // MARK: - 注册表

    func testRegistryKeepsRegistrationOrderAndOverridesByName() async {
        let log = RunLog()
        let registry = AgentToolRegistry<TestContext>(tools: [WriteTool(log: log), EchoTool(log: log)])
        await registry.register(DropTool(log: log))
        await registry.register(EchoTool(log: log))
        let names = await registry.allSchemas().map(\.name)
        XCTAssertEqual(names, ["write", "echo", "drop"])
        await registry.unregister(named: "write")
        let after = await registry.allSchemas().map(\.name)
        XCTAssertEqual(after, ["echo", "drop"])
        let missing = await registry.tool(named: "write")
        XCTAssertNil(missing)
    }
}
