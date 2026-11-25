import Foundation
import NIOCore
import NIOSSH
import USSHTestServer
import XCTest
@_spi(uTermIntegration) @testable import USSHKit

/// 用旧算法连之前问 app（`legacyFallbackApproval`）：没有共同算法要再试、进程内记着需要旧算法要第一次就带上，
/// 两处都问；不同意时不再连、不写进程内记录、抛类型化的 `legacyFallbackDeclined`；不给闭包时与以前一样。
/// 服务端那边数 TCP 连接（`acceptedConnections`）来确认连了几次。
final class LegacyFallbackApprovalTests: XCTestCase {

    /// 记下被问到的请求，按设定回答。
    final class ApprovalProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [SSHLegacyFallbackRequest] = []
        private let answer: @Sendable (SSHLegacyFallbackRequest) -> Bool

        init(_ answer: @escaping @Sendable (SSHLegacyFallbackRequest) -> Bool) { self.answer = answer }
        convenience init(_ approve: Bool) { self.init { _ in approve } }

        var requests: [SSHLegacyFallbackRequest] { lock.withLock { recorded } }

        var approval: @Sendable (SSHLegacyFallbackRequest) async -> Bool {
            { [self] request in
                lock.withLock { recorded.append(request) }
                return answer(request)
            }
        }
    }

    private static let rsaHostKey = try! SSHRSAPrivateKey(pemRepresentation: KeyImportFixtures.rsaPKCS1)

    private func sha1HostKeyServer() async throws -> SSHTestServer {
        try await TestSSH.startServer { $0.useRSAHostKey(Self.rsaHostKey, algorithms: [.sshRSA]) }
    }

    private func group14SHA1Server() async throws -> SSHTestServer {
        try await TestSSH.startServer { $0.keyExchangeAlgorithms = [SSHDiffieHellmanAlgorithm.group14SHA1.name] }
    }

    private func attempts(_ server: SSHTestServer) -> Int { server.events.acceptedConnections }

    private func jumpHost(_ bastion: SSHTestServer) -> SSHJumpHost {
        SSHJumpHost(host: bastion.host, port: bastion.port, username: TestSSH.username,
                    credential: .password(TestSSH.password))
    }

    /// 抛的是 `legacyFallbackDeclined`，返回它带的请求。
    private func declinedRequest(
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async -> SSHLegacyFallbackRequest? {
        do {
            try await body()
            XCTFail("应当失败", file: file, line: line)
        } catch SSHConnectionError.legacyFallbackDeclined(let request) {
            return request
        } catch {
            XCTFail("应抛 legacyFallbackDeclined，实际 \(String(reflecting: error))", file: file, line: line)
        }
        return nil
    }

    // MARK: - 没有共同算法、要再试

    /// 同意：问一次（哪一跳、哪台、卡在主机密钥、服务器只报了 ssh-rsa），之后与不问时一样——两次连接、记成需要旧算法。
    func testApprovedRetryBehavesAsBefore() async throws {
        let server = try await sha1HostKeyServer()
        defer { Task { await server.stop() } }
        let probe = ApprovalProbe(true)
        let memory = SSHLegacyEndpointMemory()
        let client = try await TestSSH.connect(server, legacyFallbackApproval: probe.approval, legacyMemory: memory)
        XCTAssertEqual(client.legacyAlgorithmsInUse, [SSHLegacyAlgorithm(role: .hostKey, name: "ssh-rsa")])
        await client.close()

        XCTAssertEqual(attempts(server), 2)
        XCTAssertEqual(probe.requests.count, 1)
        let request = try XCTUnwrap(probe.requests.first)
        XCTAssertEqual(request.hop, .target)
        XCTAssertEqual(request.host, server.host)
        XCTAssertEqual(request.port, server.port)
        XCTAssertEqual(request.trigger, .noCommonAlgorithm)
        XCTAssertEqual(request.category, .hostKey)
        XCTAssertEqual(request.serverOffer, ["ssh-rsa"])
        XCTAssertTrue(memory.needsLegacy(host: server.host, port: server.port))
        XCTAssertEqual(memory.failure(host: server.host, port: server.port), request.failure,
                       "记下当初卡在哪，下次问的时候交给 app")
    }

    /// 不同意：只连了一次，抛类型化的错误（带被拒的那一问），不问主机密钥，不写进程内记录，记一条日志。
    func testDeclinedRetryConnectsOnceAndRemembersNothing() async throws {
        let server = try await group14SHA1Server()
        defer { Task { await server.stop() } }
        let probe = ApprovalProbe(false)
        let hostKeyProbe = ApproverProbe(.approve)
        let memory = SSHLegacyEndpointMemory()
        let log = LegacyFallbackTests.LogProbe()
        let request = await declinedRequest {
            _ = try await TestSSH.connect(server, policy: .ask, approver: hostKeyProbe.approver,
                                          legacyFallbackApproval: probe.approval, legacyMemory: memory, logger: log)
        }
        XCTAssertEqual(request, probe.requests.first)
        XCTAssertEqual(request?.trigger, .noCommonAlgorithm)
        XCTAssertEqual(request?.category, .keyExchange)
        XCTAssertEqual(request?.serverOffer, ["diffie-hellman-group14-sha1"])
        XCTAssertEqual(probe.requests.count, 1)
        XCTAssertEqual(attempts(server), 1)
        XCTAssertEqual(hostKeyProbe.challenges.count, 0, "第一次在密钥交换里就失败了，没走到主机密钥")
        XCTAssertFalse(memory.needsLegacy(host: server.host, port: server.port))
        XCTAssertEqual(log.warnings.count, 0)
    }

    /// 不给闭包：与以前一样，两次连接、记成需要旧算法。
    func testNilApprovalBehavesAsBefore() async throws {
        let server = try await sha1HostKeyServer()
        defer { Task { await server.stop() } }
        let memory = SSHLegacyEndpointMemory()
        let client = try await TestSSH.connect(server, legacyFallbackApproval: nil, legacyMemory: memory)
        XCTAssertEqual(client.legacyAlgorithmsInUse, [SSHLegacyAlgorithm(role: .hostKey, name: "ssh-rsa")])
        await client.close()
        XCTAssertEqual(attempts(server), 2)
        XCTAssertTrue(memory.needsLegacy(host: server.host, port: server.port))
    }

    /// 现代服务器、关掉自动退级：都不问。
    func testNotAskedWhenNoLegacyAlgorithmIsNeededOrAllowed() async throws {
        let modern = try await TestSSH.startServer()
        defer { Task { await modern.stop() } }
        let probe = ApprovalProbe(false)
        let client = try await TestSSH.connect(modern, legacyFallbackApproval: probe.approval)
        await client.close()
        XCTAssertEqual(attempts(modern), 1)

        let old = try await sha1HostKeyServer()
        defer { Task { await old.stop() } }
        await assertConnectionError({
            _ = try await TestSSH.connect(old, legacyFallback: false, legacyFallbackApproval: probe.approval)
        }) { if case .handshakeFailed(let message) = $0 { return message } else { return nil } }
        XCTAssertEqual(attempts(old), 1)

        // 调用方自己就要旧算法（`.legacyCompatible`）：不是退级，不问。
        let explicit = try await TestSSH.connect(old, algorithms: .legacyCompatible, legacyFallbackApproval: probe.approval)
        await explicit.close()
        XCTAssertEqual(attempts(old), 2)
        XCTAssertTrue(probe.requests.isEmpty)
    }

    // MARK: - 进程内记着需要旧算法、第一次就要带上

    /// 同意：问一次（`.remembered`，带着当初记下的那份失败），只连一次。
    func testRememberedEndpointAsksBeforeTheFirstAttempt() async throws {
        let server = try await sha1HostKeyServer()
        defer { Task { await server.stop() } }
        let memory = SSHLegacyEndpointMemory()
        let first = try await TestSSH.connect(server, legacyMemory: memory)
        await first.close()
        XCTAssertEqual(attempts(server), 2)

        let probe = ApprovalProbe(true)
        let second = try await TestSSH.connect(server, legacyFallbackApproval: probe.approval, legacyMemory: memory)
        XCTAssertEqual(second.legacyAlgorithmsInUse, [SSHLegacyAlgorithm(role: .hostKey, name: "ssh-rsa")])
        await second.close()
        XCTAssertEqual(attempts(server), 3, "同意之后与以前一样：直接带上旧算法，只连一次")
        XCTAssertEqual(probe.requests.count, 1)
        let request = try XCTUnwrap(probe.requests.first)
        XCTAssertEqual(request.trigger, .remembered)
        XCTAssertEqual(request.hop, .target)
        XCTAssertEqual(request.category, .hostKey)
        XCTAssertEqual(request.serverOffer, ["ssh-rsa"])
        XCTAssertTrue(memory.needsLegacy(host: server.host, port: server.port))
    }

    /// 不同意：这次不带旧算法连一次（仍然没有共同算法），不再问、不再连，抛被拒的那一问；进程内的记录不动。
    func testDeclinedRememberedEndpointConnectsOnceWithoutLegacy() async throws {
        let server = try await sha1HostKeyServer()
        defer { Task { await server.stop() } }
        let memory = SSHLegacyEndpointMemory()
        memory.record(host: server.host, port: server.port, needsLegacy: true)
        let probe = ApprovalProbe(false)
        let request = await declinedRequest {
            _ = try await TestSSH.connect(server, legacyFallbackApproval: probe.approval, legacyMemory: memory)
        }
        XCTAssertEqual(request?.trigger, .remembered)
        XCTAssertEqual(request?.category, .hostKey, "记录是直接写的、没有当初的失败；抛出的是这次实测的那一份")
        XCTAssertEqual(request?.serverOffer, ["ssh-rsa"])
        XCTAssertEqual(probe.requests.count, 1, "同一跳只问一次")
        XCTAssertEqual(attempts(server), 1)
        XCTAssertTrue(memory.needsLegacy(host: server.host, port: server.port))
    }

    /// 不同意、而主机已经升级了：不带旧算法照样连上，进程内的记录随之忘掉。
    func testDeclinedRememberedEndpointThatUpgradedStillConnects() async throws {
        let server = try await TestSSH.startServer()
        defer { Task { await server.stop() } }
        let memory = SSHLegacyEndpointMemory()
        memory.record(host: server.host, port: server.port, needsLegacy: true)
        let probe = ApprovalProbe(false)
        let client = try await TestSSH.connect(server, legacyFallbackApproval: probe.approval, legacyMemory: memory)
        XCTAssertEqual(client.legacyAlgorithmsInUse, [])
        await client.close()
        XCTAssertEqual(probe.requests.map(\.trigger), [.remembered])
        XCTAssertEqual(attempts(server), 1)
        XCTAssertFalse(memory.needsLegacy(host: server.host, port: server.port))
    }

    // MARK: - 跳板机

    /// 跳板机那一跳也问（`hop == .jumpHost`）；不同意时包在 `jumpHostFailed(_, cause:)` 里，没有去开目标那一跳。
    func testJumpHostHopIsAskedAndDeclineIsWrapped() async throws {
        let target = try await TestSSH.startServer()
        let bastion = try await sha1HostKeyServer()
        defer { Task { await target.stop(); await bastion.stop() } }
        let probe = ApprovalProbe(false)
        let memory = SSHLegacyEndpointMemory()
        var cause: SSHConnectionError?
        var message: String?
        do {
            _ = try await TestSSH.connect(target, jumpHost: jumpHost(bastion),
                                          legacyFallbackApproval: probe.approval, legacyMemory: memory)
            XCTFail("应当失败")
        } catch SSHConnectionError.jumpHostFailed(let text, let inner) {
            cause = inner
            message = text
        }
        guard case .legacyFallbackDeclined(let request)? = cause else {
            return XCTFail("cause 应是 legacyFallbackDeclined，实际 \(String(describing: cause))")
        }
        XCTAssertEqual(request.hop, .jumpHost)
        XCTAssertEqual(request.host, bastion.host)
        XCTAssertEqual(request.port, bastion.port)
        XCTAssertEqual(probe.requests, [request])
        XCTAssertEqual(message, SSHErrorText.describe(SSHConnectionError.legacyFallbackDeclined(request)),
                       "文案自己说了是哪台跳板机，不再套一层")
        XCTAssertEqual(attempts(bastion), 1)
        XCTAssertEqual(bastion.events.directTCPIPTargets.count, 0)
        XCTAssertEqual(attempts(target), 0)
        XCTAssertFalse(memory.needsLegacy(host: bastion.host, port: bastion.port))
    }

    /// 目标那一跳经跳板机也问（`hop == .target`）：只问目标，同意后经跳板机再开一次 direct-tcpip。
    func testTargetBehindJumpHostIsAsked() async throws {
        let target = try await group14SHA1Server()
        let bastion = try await TestSSH.startServer()
        defer { Task { await target.stop(); await bastion.stop() } }
        let probe = ApprovalProbe(true)
        let client = try await TestSSH.connect(target, jumpHost: jumpHost(bastion), legacyFallbackApproval: probe.approval)
        await client.close()
        XCTAssertEqual(probe.requests.map(\.hop), [.target])
        XCTAssertEqual(probe.requests.first?.host, target.host)
        XCTAssertEqual(bastion.events.directTCPIPTargets.count, 2)
    }

    /// 目标经跳板机、不同意：包在 `jumpHostFailed(_, cause:)` 里，目标只开了一次。
    func testDeclinedTargetBehindJumpHostIsWrapped() async throws {
        let target = try await group14SHA1Server()
        let bastion = try await TestSSH.startServer()
        defer { Task { await target.stop(); await bastion.stop() } }
        let probe = ApprovalProbe(false)
        do {
            _ = try await TestSSH.connect(target, jumpHost: jumpHost(bastion), legacyFallbackApproval: probe.approval)
            XCTFail("应当失败")
        } catch SSHConnectionError.jumpHostFailed(_, let cause) {
            guard case .legacyFallbackDeclined(let request)? = cause else {
                return XCTFail("cause 应是 legacyFallbackDeclined，实际 \(String(describing: cause))")
            }
            XCTAssertEqual(request.hop, .target)
        }
        XCTAssertEqual(bastion.events.directTCPIPTargets.count, 1)
    }

    // MARK: - 其它入口：本地转发隧道、SFTP 会话

    /// `SSHLocalForwardingTunnel`：不同意 → 只连一次、抛 `legacyFallbackDeclined`，没有开始监听。
    func testForwardingTunnelDeclineConnectsOnce() async throws {
        let server = try await sha1HostKeyServer()
        defer { Task { await server.stop() } }
        let probe = ApprovalProbe(false)
        let tunnel = SSHLocalForwardingTunnel(
            request: SSHForwardingRequest(endpoint: TestSSH.endpoint(server), credential: .password(TestSSH.password),
                                          targetHost: "127.0.0.1", targetPort: 9),
            hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: .insecureAcceptAll,
            legacyFallbackApproval: probe.approval)
        let request = await declinedRequest { _ = try await tunnel.open() }
        XCTAssertEqual(request?.hop, .target)
        XCTAssertEqual(request?.trigger, .noCommonAlgorithm)
        XCTAssertEqual(request?.serverOffer, ["ssh-rsa"])
        XCTAssertEqual(probe.requests.count, 1)
        XCTAssertEqual(attempts(server), 1)
        let connected = await tunnel.isConnected
        XCTAssertFalse(connected)
        await tunnel.close()
    }

    /// `SSHLocalForwardingTunnel`：同意 → 与不问一样（两次连接，隧道通了）。
    func testForwardingTunnelApproveBehavesAsBefore() async throws {
        let server = try await sha1HostKeyServer()
        defer { Task { await server.stop() } }
        let probe = ApprovalProbe(true)
        let tunnel = SSHLocalForwardingTunnel(
            request: SSHForwardingRequest(endpoint: TestSSH.endpoint(server), credential: .password(TestSSH.password),
                                          targetHost: "127.0.0.1", targetPort: 9),
            hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: .insecureAcceptAll,
            legacyFallbackApproval: probe.approval)
        _ = try await tunnel.open()
        let connected = await tunnel.isConnected
        XCTAssertTrue(connected)
        await tunnel.close()
        XCTAssertEqual(probe.requests.map(\.trigger), [.noCommonAlgorithm])
        XCTAssertEqual(attempts(server), 2)
    }

    /// `SSHLocalForwardingTunnel` 经跳板机：跳板机那一跳被拒，包在 `jumpHostFailed` 的 `cause` 里，跳板机只连一次。
    func testForwardingTunnelJumpHostDeclineIsWrapped() async throws {
        let target = try await TestSSH.startServer()
        let bastion = try await sha1HostKeyServer()
        defer { Task { await target.stop(); await bastion.stop() } }
        let probe = ApprovalProbe(false)
        let tunnel = SSHLocalForwardingTunnel(
            request: SSHForwardingRequest(endpoint: TestSSH.endpoint(target, jumpHost: jumpHost(bastion)),
                                          credential: .password(TestSSH.password),
                                          targetHost: "127.0.0.1", targetPort: 9),
            hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: .insecureAcceptAll,
            legacyFallbackApproval: probe.approval)
        do {
            _ = try await tunnel.open()
            XCTFail("应当失败")
        } catch SSHConnectionError.jumpHostFailed(_, let cause) {
            guard case .legacyFallbackDeclined(let request)? = cause else {
                return XCTFail("cause 应是 legacyFallbackDeclined，实际 \(String(describing: cause))")
            }
            XCTAssertEqual(request.hop, .jumpHost)
        }
        XCTAssertEqual(attempts(bastion), 1)
        XCTAssertEqual(attempts(target), 0)
        await tunnel.close()
    }

    /// `SSHFileTransferSession.open`：不同意 → 只连一次、抛 `legacyFallbackDeclined`。
    func testFileTransferSessionDeclineConnectsOnce() async throws {
        let fileSystem = try SFTPLocalFileSystem.makeTemporary(prefix: "usshkit-legacy-approval")
        defer { try? fileSystem.removeRoot() }
        let server = try await TestSSH.startServer {
            $0.useRSAHostKey(Self.rsaHostKey, algorithms: [.sshRSA])
            $0.serveSFTP(fileSystem: fileSystem)
        }
        defer { Task { await server.stop() } }
        let probe = ApprovalProbe(false)
        let request = await declinedRequest {
            _ = try await SSHFileTransferSession.open(
                endpoint: TestSSH.endpoint(server), credential: .password(TestSSH.password),
                hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: .insecureAcceptAll, approver: { _ in true },
                legacyFallbackApproval: probe.approval)
        }
        XCTAssertEqual(request?.hop, .target)
        XCTAssertEqual(request?.category, .hostKey)
        XCTAssertEqual(probe.requests.count, 1)
        XCTAssertEqual(attempts(server), 1)
    }

    /// `SSHFileTransferSession.open`：同意 → 与不问一样，会话开得起来。
    func testFileTransferSessionApproveBehavesAsBefore() async throws {
        let fileSystem = try SFTPLocalFileSystem.makeTemporary(prefix: "usshkit-legacy-approval")
        defer { try? fileSystem.removeRoot() }
        let server = try await TestSSH.startServer {
            $0.useRSAHostKey(Self.rsaHostKey, algorithms: [.sshRSA])
            $0.serveSFTP(fileSystem: fileSystem)
        }
        defer { Task { await server.stop() } }
        let probe = ApprovalProbe(true)
        let session = try await SSHFileTransferSession.open(
            endpoint: TestSSH.endpoint(server), credential: .password(TestSSH.password),
            hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: .insecureAcceptAll, approver: { _ in true },
            legacyFallbackApproval: probe.approval)
        XCTAssertTrue(session.isConnected)
        await session.close()
        XCTAssertEqual(probe.requests.count, 1)
        XCTAssertEqual(attempts(server), 2)
    }

    // MARK: - 别的

    /// 等回答的时候建连任务被取消：闭包返回之后抛 `CancellationError`，不再连。
    func testCancellationWhileWaitingForTheAnswer() async throws {
        let server = try await sha1HostKeyServer()
        defer { Task { await server.stop() } }
        let asked = expectation(description: "asked")
        let approval: @Sendable (SSHLegacyFallbackRequest) async -> Bool = { _ in
            asked.fulfill()
            try? await Task.sleep(for: .seconds(30))
            return true
        }
        let task = Task { try await TestSSH.connect(server, legacyFallbackApproval: approval) }
        await fulfillment(of: [asked], timeout: 10)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("应当被取消")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(attempts(server), 1)
    }

    /// 一个永远不回答、也不响应取消的询问（例如交给了没人接的通道）。用例结束时 `release()` 放掉。
    final class NeverAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Bool, Never>] = []
        private var cancelledFlag = false
        private var askedCount = 0
        var asked: Int { lock.withLock { askedCount } }
        var cancelled: Bool { lock.withLock { cancelledFlag } }

        var approval: @Sendable (SSHLegacyFallbackRequest) async -> Bool {
            { [self] _ in
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        lock.withLock {
                            askedCount += 1
                            waiting.append(continuation)
                        }
                    }
                } onCancel: {
                    lock.withLock { cancelledFlag = true }
                }
            }
        }

        func release() {
            let all = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
                defer { waiting = [] }
                return waiting
            }
            for continuation in all { continuation.resume(returning: false) }
        }
    }

    /// 永远不回答：到 `approvalTimeout` 按不同意处理（抛 `legacyFallbackDeclined`、只连一次、日志写明超时），
    /// 不会一直停在「连接中」；闭包所在的任务被取消。
    func testUnansweredApprovalTimesOutAsDeclined() async throws {
        let server = try await sha1HostKeyServer()
        defer { Task { await server.stop() } }
        let never = NeverAnswer()
        defer { never.release() }
        let log = LegacyFallbackTests.LogProbe()
        let memory = SSHLegacyEndpointMemory()
        let started = ContinuousClock.now
        let request = await declinedRequest {
            _ = try await TestSSH.connect(server, approvalTimeout: .milliseconds(300),
                                          legacyFallbackApproval: never.approval, legacyMemory: memory, logger: log)
        }
        let elapsed = ContinuousClock.now - started
        XCTAssertEqual(request?.trigger, .noCommonAlgorithm)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(300))
        XCTAssertLessThan(elapsed, .seconds(5))
        XCTAssertEqual(attempts(server), 1)
        XCTAssertFalse(memory.needsLegacy(host: server.host, port: server.port))
        XCTAssertEqual(log.events.last?.metadata["timedOut"], "true")
        XCTAssertTrue(never.cancelled, "到点之后取消闭包所在的任务")
    }

    /// 等回答时取消建连任务：立刻抛 `CancellationError`，不等闭包（它不响应取消）返回，也不等 `approvalTimeout`。
    func testCancellationDoesNotWaitForAnUnresponsiveApproval() async throws {
        let server = try await sha1HostKeyServer()
        defer { Task { await server.stop() } }
        let never = NeverAnswer()
        defer { never.release() }
        let task = Task {
            try await TestSSH.connect(server, approvalTimeout: .seconds(180), legacyFallbackApproval: never.approval)
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while never.asked == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(never.asked, 1)
        let cancelledAt = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("应当被取消")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - cancelledAt, .seconds(2))
        XCTAssertEqual(attempts(server), 1)
        XCTAssertTrue(never.cancelled)
    }

    /// RSA 用户私钥在同一条连接里退到 `ssh-rsa` 签名不经过它（那不是降低服务器那一端的安全性）。
    func testRSAUserSignatureFallbackIsNotAsked() async throws {
        var authentication = SSHTestAuthentication(
            authorizedKeys: [TestSSH.username: [try TestSSH.publicKey(ofPrivateKey: KeyImportFixtures.rsaPKCS1)]])
        authentication.acceptedRSASignatureAlgorithms = [.sshRSA]
        let server = try await TestSSH.startServer(authentication: authentication) {
            $0.serverSignatureAlgorithms = nil
            $0.acceptsLegacyAlgorithms = true
        }
        defer { Task { await server.stop() } }
        let probe = ApprovalProbe(false)
        let client = try await TestSSH.connect(
            server, credential: .privateKey(pem: KeyImportFixtures.rsaPKCS1, passphrase: nil),
            legacyFallbackApproval: probe.approval)
        XCTAssertEqual(client.legacyAlgorithmsInUse, [SSHLegacyAlgorithm(role: .userAuthentication, name: "ssh-rsa")])
        await client.close()
        XCTAssertTrue(probe.requests.isEmpty)
        XCTAssertEqual(attempts(server), 1)
    }

    /// 文案：头一句说哪台、要改用较旧的连接方式、没有得到同意；知道类别时附一句服务器只提供什么；四种语言都有。
    func testDeclinedErrorDescriptionIsLocalized() throws {
        let request = SSHLegacyFallbackRequest(hop: .target, host: "old.example", port: 2222, trigger: .noCommonAlgorithm,
                                               failure: .init(category: .hostKey, clientOffer: [], serverOffer: ["ssh-rsa"]))
        let target = try XCTUnwrap(SSHConnectionError.legacyFallbackDeclined(request).errorDescription)
        XCTAssertTrue(target.contains(SSHPeerText.isolated("old.example:2222")), target)
        XCTAssertTrue(target.contains("SHA-1"), target)
        XCTAssertTrue(target.contains("主机密钥签名"), target)
        XCTAssertTrue(target.contains(SSHPeerText.isolated("ssh-rsa")), target)
        XCTAssertFalse(target.contains("这次"), target)
        XCTAssertFalse(target.contains("加密方式"), target)
        var jump = request
        jump.hop = .jumpHost
        XCTAssertTrue(try XCTUnwrap(SSHConnectionError.legacyFallbackDeclined(jump).errorDescription).hasPrefix("没有连接跳板机"))
        var unknown = request
        unknown.failure = nil
        XCTAssertFalse(try XCTUnwrap(SSHConnectionError.legacyFallbackDeclined(unknown).errorDescription).contains("服务器的"),
                       "说不出卡在哪一类时只有头一句")
        // IPv6 字面量加方括号。
        XCTAssertEqual(SSHErrorText.address(host: "::1", port: 22), SSHPeerText.isolated("[::1]:22"))
        XCTAssertEqual(SSHErrorText.address(host: "fe80::1%en0", port: 2222), SSHPeerText.isolated("[fe80::1%en0]:2222"))
        XCTAssertEqual(SSHErrorText.address(host: "host.example", port: 22), SSHPeerText.isolated("host.example:22"))

        let keys = [
            "没有连接 %@：这台主机要改用较旧、安全性较低的连接方式（SHA-1）才能连上，没有得到同意。",
            "没有连接跳板机 %@：这台跳板机要改用较旧、安全性较低的连接方式（SHA-1）才能连上，没有得到同意。",
            "经跳板机 %@ 没有连接 %@：这台主机要改用较旧、安全性较低的连接方式（SHA-1）才能连上，没有得到同意。",
            "服务器的密钥交换只提供：%@。",
            "服务器的主机密钥签名只提供：%@。",
            "服务器的消息校验只提供：%@。",
            "服务器在这一类只提供：%@。",
        ]
        for language in ["en", "zh-Hant", "ja", "ko"] {
            let bundle = try XCTUnwrap(
                ModuleBundle.bundle.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            for key in keys {
                let translated = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
                XCTAssertNotEqual(translated, "MISSING", "\(language)：\(key)")
                XCTAssertNotEqual(translated, key, "\(language)：\(key)")
                XCTAssertTrue(translated.contains("%@") || translated.contains("%1$@"), "\(language)：\(translated)")
            }
        }
    }

    // MARK: - 算法集比 .standard 窄：先只补现代算法，不问

    /// `.builtInOnly` 对只有 SHA-2 的 RSA 主机密钥（`rsa-sha2-512` / `rsa-sha2-256`）的服务器、以及同时还报 `ssh-rsa` 的服务器：
    /// 先只补 `.standard` 的现代算法再试，不问、不开旧算法，协商到 SHA-2。
    func testNarrowAlgorithmsRetryWithModernAdditionsWithoutAsking() async throws {
        for alsoSHA1 in [false, true] {
            let server = try await TestSSH.startServer {
                $0.useRSAHostKey(Self.rsaHostKey, algorithms: SSHRSASignatureAlgorithm.modern + (alsoSHA1 ? [.sshRSA] : []))
            }
            let probe = ApprovalProbe(false)
            let client = try await TestSSH.connect(server, algorithms: .builtInOnly, legacyFallbackApproval: probe.approval)
            XCTAssertEqual(client.target.negotiatedAlgorithms?.hostKey, "rsa-sha2-512")
            XCTAssertEqual(client.targetNeededLegacyTransport, false)
            XCTAssertEqual(client.legacyAlgorithmsInUse, [])
            await client.close()
            XCTAssertTrue(probe.requests.isEmpty, "alsoSHA1: \(alsoSHA1)")
            XCTAssertEqual(attempts(server), 2)
            await server.stop()
        }
    }

    /// 补了现代算法仍要旧算法：现代那一次不问，旧算法那一次才问（问的是第二次的失败：卡在 MAC，服务器只报 hmac-sha1）；
    /// 不同意时共连两次。
    func testNarrowAlgorithmsAskOnlyWhenLegacyIsStillNeeded() async throws {
        let server = try await TestSSH.startServer {
            $0.transportProtectionSchemes = [SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA1>.self]
        }
        defer { Task { await server.stop() } }
        var gcmOnly = SSHAlgorithms.standard
        gcmOnly.transportProtectionSchemes = Constants.bundledTransportProtectionSchemes
        let probe = ApprovalProbe(false)
        let request = await declinedRequest {
            _ = try await TestSSH.connect(server, algorithms: gcmOnly, legacyFallbackApproval: probe.approval)
        }
        XCTAssertEqual(request?.category, .mac)
        XCTAssertEqual(request?.serverOffer, ["hmac-sha1"])
        XCTAssertEqual(probe.requests.count, 1)
        XCTAssertEqual(attempts(server), 2)
    }

    // MARK: - 给 App 记录用的三态

    /// 只有 SHA-1 主机签名：需要（true）；现代服务器：不需要（false）；没有跳板机：跳板机那一跳为 nil。
    func testNeededLegacyTransportTriState() async throws {
        let old = try await sha1HostKeyServer()
        let modern = try await TestSSH.startServer()
        defer { Task { await old.stop(); await modern.stop() } }
        let legacy = try await TestSSH.connect(old)
        XCTAssertEqual(legacy.targetNeededLegacyTransport, true)
        XCTAssertNil(legacy.bastionNeededLegacyTransport)
        await legacy.close()
        let current = try await TestSSH.connect(modern)
        XCTAssertEqual(current.targetNeededLegacyTransport, false)
        await current.close()

        // 经跳板机：两跳各自报。
        let viaJump = try await TestSSH.connect(modern, jumpHost: jumpHost(old))
        XCTAssertEqual(viaJump.bastionNeededLegacyTransport, true)
        XCTAssertEqual(viaJump.targetNeededLegacyTransport, false)
        await viaJump.close()
    }

    /// RSA 用户私钥退到 `ssh-rsa` 签名：给人看的 `legacyAlgorithmsInUse` 里有它，三态（传输层）是「不需要」。
    func testRSAUserSignatureDoesNotCountAsLegacyTransport() async throws {
        var authentication = SSHTestAuthentication(
            authorizedKeys: [TestSSH.username: [try TestSSH.publicKey(ofPrivateKey: KeyImportFixtures.rsaPKCS1)]])
        authentication.acceptedRSASignatureAlgorithms = [.sshRSA]
        let server = try await TestSSH.startServer(authentication: authentication) {
            $0.serverSignatureAlgorithms = nil
            $0.acceptsLegacyAlgorithms = true
        }
        defer { Task { await server.stop() } }
        let client = try await TestSSH.connect(
            server, credential: .privateKey(pem: KeyImportFixtures.rsaPKCS1, passphrase: nil))
        XCTAssertEqual(client.legacyAlgorithmsInUse, [SSHLegacyAlgorithm(role: .userAuthentication, name: "ssh-rsa")])
        XCTAssertEqual(client.targetNeededLegacyTransport, false)
        await client.close()
    }

    /// 隧道与 SFTP 会话也报这个三态（隧道 `open()` 之前为 nil）。
    func testTunnelAndFileTransferSessionReportTheTriState() async throws {
        let fileSystem = try SFTPLocalFileSystem.makeTemporary(prefix: "usshkit-legacy-tristate")
        defer { try? fileSystem.removeRoot() }
        let server = try await TestSSH.startServer {
            $0.useRSAHostKey(Self.rsaHostKey, algorithms: [.sshRSA])
            $0.serveSFTP(fileSystem: fileSystem)
        }
        defer { Task { await server.stop() } }
        let tunnel = SSHLocalForwardingTunnel(
            request: SSHForwardingRequest(endpoint: TestSSH.endpoint(server), credential: .password(TestSSH.password),
                                          targetHost: "127.0.0.1", targetPort: 9),
            hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: .insecureAcceptAll)
        let before = await tunnel.targetNeededLegacyTransport
        XCTAssertNil(before)
        _ = try await tunnel.open()
        let afterOpen = await tunnel.targetNeededLegacyTransport
        let bastionNeeded = await tunnel.bastionNeededLegacyTransport
        XCTAssertEqual(afterOpen, true)
        XCTAssertNil(bastionNeeded)
        await tunnel.close()

        let session = try await SSHFileTransferSession.open(
            endpoint: TestSSH.endpoint(server), credential: .password(TestSSH.password),
            hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: .insecureAcceptAll, approver: { _ in true })
        XCTAssertEqual(session.targetNeededLegacyTransport, true)
        XCTAssertNil(session.bastionNeededLegacyTransport)
        await session.close()
    }

    /// 调用方自己给了带旧算法的集合（`.legacyCompatible`）：用上旧算法也不写进程内记录（不是退级）。
    func testExplicitLegacyAlgorithmsDoNotWriteTheMemory() async throws {
        let server = try await sha1HostKeyServer()
        defer { Task { await server.stop() } }
        let memory = SSHLegacyEndpointMemory()
        let client = try await TestSSH.connect(server, algorithms: .legacyCompatible, legacyMemory: memory)
        XCTAssertEqual(client.targetNeededLegacyTransport, true)
        await client.close()
        XCTAssertFalse(memory.needsLegacy(host: server.host, port: server.port))
    }

    // MARK: - 隧道：等询问时的重入

    /// 一个等着放行的询问：`ask` 被调用后挂起，直到 `answer(_:)`。
    final class GatedApproval: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: CheckedContinuation<Bool, Never>?
        private var askedFlag = false
        var asked: Bool { lock.withLock { askedFlag } }

        var approval: @Sendable (SSHLegacyFallbackRequest) async -> Bool {
            { [self] _ in
                await withCheckedContinuation { continuation in
                    lock.withLock {
                        askedFlag = true
                        waiting = continuation
                    }
                }
            }
        }

        func answer(_ approved: Bool) {
            let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                defer { waiting = nil }
                return waiting
            }
            continuation?.resume(returning: approved)
        }

        func waitUntilAsked() async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !asked, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(asked)
        }
    }

    /// 等询问时 `close()`、之后才同意：`open()` 自己收尾（关掉连上的连接、不绑端口），抛 `.closed`；
    /// 等询问时再 `open()` 一次：拒绝（`.alreadyOpen`），不建第二份。
    func testTunnelCloseWhileWaitingForTheAnswerLeavesNothingBehind() async throws {
        let server = try await sha1HostKeyServer()
        defer { Task { await server.stop() } }
        let gate = GatedApproval()
        let tunnel = SSHLocalForwardingTunnel(
            request: SSHForwardingRequest(endpoint: TestSSH.endpoint(server), credential: .password(TestSSH.password),
                                          targetHost: "127.0.0.1", targetPort: 9),
            hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: .insecureAcceptAll,
            legacyFallbackApproval: gate.approval)
        let opening = Task { try await tunnel.open() }
        try await gate.waitUntilAsked()

        do {
            _ = try await tunnel.open()
            XCTFail("第二次 open 应当被拒绝")
        } catch SSHConnectionError.alreadyOpen {}

        await tunnel.close()
        gate.answer(true)
        do {
            _ = try await opening.value
            XCTFail("关掉之后 open 不应成功")
        } catch SSHConnectionError.closed {}
        let connected = await tunnel.isConnected
        XCTAssertFalse(connected)
        XCTAssertEqual(attempts(server), 2, "同意之后照常连上了第二次")
        try await server.waitForEvents { $0.closedConnections == $0.acceptedConnections }
    }

    // MARK: - 取消

    /// 建连任务已经取消了：不弹询问，直接抛 `CancellationError`。
    func testCancelledTaskIsNotAsked() async throws {
        let probe = ApprovalProbe(true)
        let request = SSHLegacyFallbackRequest(hop: .target, host: "h", port: 22, trigger: .noCommonAlgorithm, failure: nil)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SSHLegacyApprovalWait.run(probe.approval, request: request, timeout: .seconds(5))
        }
        do {
            _ = try await task.value
            XCTFail("应当被取消")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(probe.requests.isEmpty)
    }

    /// 经跳板机、目标那一跳等询问时取消：立刻结束，已经连上的跳板机随之关掉。
    func testCancellationWhileTheTargetHopWaitsClosesTheBastion() async throws {
        let target = try await group14SHA1Server()
        let bastion = try await TestSSH.startServer()
        defer { Task { await target.stop(); await bastion.stop() } }
        let never = NeverAnswer()
        defer { never.release() }
        let task = Task {
            try await TestSSH.connect(target, jumpHost: jumpHost(bastion), legacyFallbackApproval: never.approval)
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while never.asked == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(never.asked, 1)
        let cancelledAt = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("应当被取消")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - cancelledAt, .seconds(3))
        try await bastion.waitForEvents { $0.closedConnections == 1 }
    }

    // MARK: - 可不可以重试

    func testIsRetryable() {
        typealias E = SSHConnectionError
        let request = SSHLegacyFallbackRequest(hop: .target, host: "h", port: 22, trigger: .noCommonAlgorithm, failure: nil)
        XCTAssertTrue(E.connectFailed("x").isRetryable)
        XCTAssertTrue(E.jumpHostFailed("x", cause: .connectFailed("y")).isRetryable)
        for permanent: E in [.legacyFallbackDeclined(request), .jumpHostFailed("x", cause: .legacyFallbackDeclined(request)),
                             .authenticationFailed("x"), .hostKeyRejected("x"), .handshakeFailed("x"),
                             .unsupportedAgentAuthentication, .bindFailed("x"), .alreadyOpen, .closed,
                             .jumpHostFailed("x", cause: nil),
                             .jumpHostFailed("x", cause: .jumpHostFailed("y", cause: .authenticationFailed("z")))] {
            XCTAssertFalse(permanent.isRetryable, "\(permanent)")
        }
    }

}
