import NIOSSH
import USSHTestServer
import XCTest
@_spi(uTermIntegration) @testable import USSHKit

/// 主机密钥策略接到真连接上（进程内的 `SSHTestServer`）：库里的记录、审批超时、审批期间握手不计时。
final class HostKeyTrustIntegrationTests: XCTestCase {

    func testAcceptNewRemembersThenTrusts() async throws {
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }
        let store = MemoryHostKeyStore()

        let first = try await TestSSH.connect(server, store: store, policy: .acceptNew)
        await first.close()
        XCTAssertEqual(store.remembered, [TestSSH.hostKey(of: server)])

        let second = try await TestSSH.connect(server, store: store, policy: .strict)
        await second.close()
        XCTAssertEqual(store.remembered.count, 1, "已信任的密钥不用再记")
    }

    func testStrictRejectsUnknownHost() async throws {
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }

        await assertConnectionError({
            _ = try await TestSSH.connect(server, policy: .strict)
        }) { if case .hostKeyRejected(let message) = $0 { return message } else { return nil } }
        let events = server.events
        XCTAssertTrue(events.authAttempts.isEmpty, "主机密钥没过就不该认证")
    }

    func testChangedKeyIsRejectedUnderAcceptNew() async throws {
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }
        let stale = HostKeySerialization.serialize(
            NIOSSHPrivateKey(ed25519Key: .init()).publicKey, host: server.host, port: server.port)

        await assertConnectionError({
            _ = try await TestSSH.connect(server, store: MemoryHostKeyStore(known: [stale]), policy: .acceptNew)
        }) { if case .hostKeyRejected(let message) = $0 { return message } else { return nil } }
    }

    func testAskApprovedChangedKeyReplacesStoredKey() async throws {
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }
        let stale = HostKeySerialization.serialize(
            NIOSSHPrivateKey(ed25519Key: .init()).publicKey, host: server.host, port: server.port)
        let store = MemoryHostKeyStore(known: [stale])
        let probe = ApproverProbe(.approve)

        let client = try await TestSSH.connect(server, store: store, policy: .ask, approver: probe.approver)
        await client.close()
        XCTAssertEqual(probe.challenges.map(\.kind), [.mismatch])
        XCTAssertEqual(probe.challenges.first?.previousFingerprint, stale.fingerprint)
        XCTAssertEqual(store.remembered, [TestSSH.hostKey(of: server)])
    }

    /// 审批超时：按拒绝算（`hostKeyRejected`），确认框所在的任务被取消，库里不记。
    func testApprovalTimeoutRejectsAndCancelsApprover() async throws {
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }
        let store = MemoryHostKeyStore()
        let probe = ApproverProbe(.never)

        let started = ContinuousClock.now
        let message = await assertConnectionError({
            _ = try await TestSSH.connect(server, store: store, policy: .ask,
                                          approvalTimeout: .milliseconds(300), approver: probe.approver)
        }) { if case .hostKeyRejected(let message) = $0 { return message } else { return nil } }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        XCTAssertEqual(message, SSHClientError.hostKeyValidationTimeout(.milliseconds(300)).errorDescription)

        // 取消是异步送达的，给一点时间。
        for _ in 0..<100 where !probe.wasCancelled { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(probe.wasCancelled, "审批超时后要取消确认框所在的任务")
        XCTAssertTrue(store.remembered.isEmpty)
    }

    /// 用户对着确认框想的时间比握手时限还长：握手在等确认时不计时，确认之后照常连上。
    /// （迁移前 Citadel 的 login timer 覆盖全程，确认框停超过它就以 `ChannelError.connectTimeout` 失败。）
    func testSlowApprovalDoesNotTripHandshakeTimeout() async throws {
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }
        let probe = ApproverProbe(.approveAfter(.milliseconds(1500)))

        let client = try await TestSSH.connect(server, policy: .ask, connectTimeout: .milliseconds(700),
                                               approver: probe.approver)
        defer { Task { await client.close() } }
        XCTAssertEqual(probe.challenges.count, 1)
        let echoed = try await client.exec("echo hello")
        XCTAssertEqual(echoed, "hello\n")
    }

    func testStoreFailureIsReportedAsHostKeyRejected() async throws {
        struct Broken: Error {}
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }

        await assertConnectionError({
            _ = try await TestSSH.connect(server, store: MemoryHostKeyStore(verifyError: Broken()))
        }) { if case .hostKeyRejected(let message) = $0 { return message } else { return nil } }
    }

    /// 跳板机两跳各核对一次，各记自己的主机名与端口。
    func testJumpHostVerifiesBothHops() async throws {
        let target = try await TestSSH.startServer()
        let bastion = try await TestSSH.startServer()
        defer { Task { await target.stop(); await bastion.stop() } }
        let store = MemoryHostKeyStore()
        let probe = ApproverProbe(.approve)

        let client = try await TestSSH.connect(
            target, store: store, policy: .ask, approver: probe.approver,
            jumpHost: SSHJumpHost(host: bastion.host, port: bastion.port, username: TestSSH.username,
                                  credential: .password(TestSSH.password)))
        await client.close()
        XCTAssertEqual(probe.challenges.map(\.hostKey), [TestSSH.hostKey(of: bastion), TestSSH.hostKey(of: target)])
        XCTAssertEqual(Set(store.remembered.map(\.port)), [bastion.port, target.port])
    }
}
