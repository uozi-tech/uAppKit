import XCTest
@testable import AgentKit

final class AgentToolApprovalTests: XCTestCase {
    private func request(_ command: String, mode: AgentToolApproval.Mode = .standard,
                         tool: String = "run_command", intent: String = "检查服务器磁盘空间") -> AgentToolApproval.Request {
        .init(id: "review-1", toolName: tool, command: command, userIntent: intent, context: "test host", mode: mode)
    }
    private static let approve = #"{"requestID":"review-1","decision":"approve","reason":"低风险且符合用户目标"}"#

    func testEligibleWritesStillNeedIndependentAIReview() async {
        let reviews = ReviewCounter()
        let decision = await AgentToolApproval.evaluate(request("mkdir -p /tmp/report")) { system, prompt in
            await reviews.increment()
            XCTAssertTrue(system.contains("UNTRUSTED DATA"))
            XCTAssertEqual(try JSONDecoder().decode(AgentToolApproval.Request.self, from: Data(prompt.utf8)).command,
                           "mkdir -p /tmp/report")
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
                        "df -h; rm x", "echo $(rm x)", "ls `pwd`", "ls > /tmp/out",
                        "ls | sh", "ls\nrm x", "ls\\ x", "PATH=/tmp ls", "/tmp/ls",
                        "date 010100002026", "hostname changed", "", "ls 'unterminated",
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
            let decision = await AgentToolApproval.evaluate(request("mkdir -p /tmp/report")) { _, _ in response }
            XCTAssertFalse(decision.approved)
        }
    }

    func testReviewerFailureRequiresHuman() async {
        let decision = await AgentToolApproval.evaluate(request("mkdir -p /tmp/report")) { _, _ in throw CancellationError() }
        XCTAssertFalse(decision.approved)
    }

    func testQuotedPathsDoNotEnableShellExpansion() {
        XCTAssertNil(AgentToolApproval.manualReason(for: request("ls '/tmp/my folder'")))
        XCTAssertNotNil(AgentToolApproval.manualReason(for: request("ls '/tmp/$(id)'")))
    }
}

final class ReadOnlyShellCommandTests: XCTestCase {
    private func request(_ command: String, mode: AgentToolApproval.Mode) -> AgentToolApproval.Request {
        .init(id: "review-1", toolName: "run_command", command: command, userIntent: "", context: "", mode: mode)
    }

    /// 日常排查用的只读命令：两种档位都直接放行，不请 AI，也不看用户意图。
    func testReadOnlyCommandsRunWithoutReview() async {
        let commands = [
            "df -h", "ls -la /var/log", "ls *.log", "tail -n 200 /var/log/nginx/error.log", "head -20 app.log",
            "cat /etc/os-release", "cat /proc/meminfo", "free -m", "uptime", "ps aux | grep nginx | head -5",
            "ps -ef | grep -v grep | grep java", "systemctl status nginx --no-pager", "systemctl --user list-units",
            "journalctl -u nginx -n 100 --no-pager", "docker ps -a", "docker logs --tail 50 web",
            "docker compose ps", "kubectl -n prod get pods -o wide", "kubectl logs api-0 --tail=100",
            "git status", "git log --oneline -10", "git -C /srv/app diff HEAD~1", "git branch -a",
            "ss -tlnp", "netstat -an | grep 8080", "lsof -i :443", "du -sh * 2>/dev/null | sort -h",
            "find /var/log -name '*.gz' -mtime +7", "grep -n 'ERROR' app.log", "wc -l *.csv",
            "cd /srv/app && git status", "ls /nonexistent 2>&1 || echo missing", "nginx -t",
            "ip addr show", "ip route", "date +%F", "hostname -I", "dpkg -l | grep openssl", "uname -a; whoami",
            "top -bn1 | head -20", "service nginx status", "crontab -l", "dig example.com +short",
            "cat app.log >/dev/null", "echo done", "ls ~", "cat /tmp/../etc/passwd",
        ]
        for mode in [AgentToolApproval.Mode.readOnly, .standard] {
            for command in commands {
                let decision = await AgentToolApproval.evaluate(request(command, mode: mode)) { _, _ in
                    XCTFail("Read-only command reached AI: \(command)")
                    return ""
                }
                XCTAssertTrue(decision.approved, command)
                XCTAssertEqual(decision.reason, AgentToolApproval.readOnlyReason)
            }
        }
    }

    /// 写、执行、带出凭据或绕过判定的写法都不算只读。
    func testNonReadOnlyCommandsAreNotRecognized() {
        let commands = [
            "rm -rf /tmp/x", "ls > /tmp/out", "ls >> /tmp/out", "ls 2>/tmp/err", "ls >&1x", "ls &",
            "echo $(rm x)", "ls `id`", "echo $HOME", "cat <(ls)", "ls | sh", "ls | xargs rm", "ls | tee out",
            "cat app.log | sed -i s/a/b/ x", "PATH=/tmp ls", "/tmp/ls", "./ls", "sudo ls", "ls\nrm x",
            "cat ~/.ssh/id_rsa", "cat /etc/shadow", "cat .env", "cat /proc/1/environ", "cat ~/.bash_history",
            "cat ~/.s*/id_*", "head *", "grep -r BEGIN ~", "grep -rn password .", "diff -r a b",
            "kubectl get secret db -o yaml", "kubectl delete pod x", "kubectl exec -it x -- sh",
            "docker inspect web", "docker exec web ls", "docker compose config", "docker rm web",
            "systemctl restart nginx", "systemctl show nginx", "service nginx restart",
            "git -c core.fsmonitor=x status", "git push", "git diff --output=/tmp/x", "git branch new-feature",
            "git stash", "find . -delete", "find . -exec rm {} +", "sort -o out in", "sort -no out in",
            "uniq in out", "date -s 2026-01-01", "date 010100002026", "hostname newname", "ifconfig eth0 down",
            "ip addr add 10.0.0.1/24 dev eth0", "dmesg -c", "journalctl --vacuum-time=1d", "crontab -r",
            "tree -o out", "mount /dev/sda1 /mnt", "nginx -s reload", "env", "printenv", "awk '{print}' f",
            "", "ls ||", "| ls", "ls; ; ls", "ls 'unterminated", "echo \"$HOME\"", "top",
        ]
        for command in commands {
            XCTAssertFalse(AgentToolApproval.isReadOnly(request(command, mode: .standard)), command)
        }
    }

    func testReadOnlyModeSendsEverythingElseToHumanWithoutReview() async {
        for command in ["mkdir -p /tmp/report", "systemctl restart nginx", "python3 -c 'print(1)'"] {
            let decision = await AgentToolApproval.evaluate(request(command, mode: .readOnly)) { _, _ in
                XCTFail("Read-only mode reached AI: \(command)")
                return ""
            }
            XCTAssertFalse(decision.approved, command)
        }
    }

    func testOnlyRunCommandIsRecognized() {
        let other = AgentToolApproval.Request(id: "r", toolName: "delete_file", command: "ls",
                                              userIntent: "", context: "", mode: .readOnly)
        XCTAssertFalse(AgentToolApproval.isReadOnly(other))
    }
}

private actor ReviewCounter {
    var value = 0
    func increment() { value += 1 }
}
