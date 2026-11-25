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
        XCTAssertNil(request?.failure, "记录是直接写的，没有当初的失败")
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

    /// 文案说清楚是哪台、为什么，四种语言都有。
    func testDeclinedErrorDescriptionIsLocalized() throws {
        let request = SSHLegacyFallbackRequest(hop: .target, host: "old.example", port: 2222, trigger: .noCommonAlgorithm,
                                               failure: .init(category: .hostKey, clientOffer: [], serverOffer: ["ssh-rsa"]))
        let target = try XCTUnwrap(SSHConnectionError.legacyFallbackDeclined(request).errorDescription)
        XCTAssertTrue(target.contains("old.example:2222"), target)
        XCTAssertTrue(target.contains("SHA-1"), target)
        var jump = request
        jump.hop = .jumpHost
        XCTAssertNotEqual(SSHConnectionError.legacyFallbackDeclined(jump).errorDescription, target)

        for language in ["en", "zh-Hant", "ja", "ko"] {
            let bundle = try XCTUnwrap(
                ModuleBundle.bundle.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            for key in ["没有连接 %@：这台主机这次只提供较旧、安全性较低的加密方式（SHA-1），所以没有继续连接。",
                        "没有连接跳板机 %@：这台跳板机这次只提供较旧、安全性较低的加密方式（SHA-1），所以没有继续连接。"] {
                let translated = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
                XCTAssertNotEqual(translated, "MISSING", "\(language)：\(key)")
                XCTAssertNotEqual(translated, key, "\(language)：\(key)")
                XCTAssertTrue(translated.contains("%@"), "\(language)：\(translated)")
            }
        }
    }
}
