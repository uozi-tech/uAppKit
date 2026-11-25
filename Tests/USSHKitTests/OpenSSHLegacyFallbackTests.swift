import XCTest
@_spi(uTermIntegration) @testable import USSHKit

/// 对本机真实 sshd 的自动退级：只开 SHA-1 主机签名 / 只开 group14-sha1 / 只开 hmac-sha1 的服务器默认连得上
/// （第二次成，只问一次信任，报出用上的旧算法）；关掉自动退级时报没有共同算法；现代配置的 sshd 只连一次。
/// sshd 起不来时跳过。
final class OpenSSHLegacyFallbackTests: XCTestCase {

    private func start(_ config: [String], rsaHostKey: Bool = false) async throws -> LocalSSHD {
        let sshd = try await LocalSSHD.start(extraConfig: config, rsaHostKey: rsaHostKey)
        addTeardownBlock { sshd.stop() }
        return sshd
    }

    private func connect(
        _ sshd: LocalSSHD, probe: ApproverProbe, legacyFallback: Bool = true,
        legacyFallbackApproval: (@Sendable (SSHLegacyFallbackRequest) async -> Bool)? = nil
    ) async throws -> ConnectedClient {
        try await SSHClientFactory.connect(
            endpoint: SSHEndpoint(host: "127.0.0.1", port: sshd.port, username: sshd.username),
            credential: .privateKey(pem: sshd.userKeyPEM, passphrase: nil),
            hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: .ask,
            connectTimeout: .seconds(30), approvalTimeout: .seconds(30), approver: probe.approver,
            legacyFallback: legacyFallback, legacyFallbackApproval: legacyFallbackApproval,
            legacyMemory: SSHLegacyEndpointMemory())
    }

    /// 问 app（`legacyFallbackApproval`）：不同意时只连一次、不问信任、抛带着卡在哪一类的 `legacyFallbackDeclined`；
    /// 同意时与不问一样（两次连接、一次信任）。
    func testApprovalHookAgainstRealSSHD() async throws {
        let sshd = try await start(["HostKeyAlgorithms ssh-rsa"], rsaHostKey: true)
        let refused = ApproverProbe(.approve)
        do {
            _ = try await connect(sshd, probe: refused, legacyFallbackApproval: { _ in false })
            XCTFail("应当失败")
        } catch SSHConnectionError.legacyFallbackDeclined(let request) {
            XCTAssertEqual(request.hop, .target)
            XCTAssertEqual(request.trigger, .noCommonAlgorithm)
            XCTAssertEqual(request.category, .hostKey)
            XCTAssertEqual(request.serverOffer, ["ssh-rsa"])
        }
        await sshd.waitForConnections(1)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sshd.connections, 1, sshd.log)
        XCTAssertTrue(refused.challenges.isEmpty)

        let probe = ApproverProbe(.approve)
        let client = try await connect(sshd, probe: probe, legacyFallbackApproval: { _ in true })
        XCTAssertEqual(client.legacyAlgorithmsInUse, [SSHLegacyAlgorithm(role: .hostKey, name: "ssh-rsa")])
        await client.close()
        await sshd.waitForConnections(3)
        XCTAssertEqual(sshd.connections, 3, sshd.log)
        XCTAssertEqual(probe.challenges.count, 1)
    }

    /// 默认连上、两次连接、一次信任、报出旧算法；关掉退级时报没有共同算法且只连一次。
    private func assertFallback(_ sshd: LocalSSHD, expected: [SSHLegacyAlgorithm], refusal: SSHAlgorithmNegotiationFailure,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let probe = ApproverProbe(.approve)
        let client = try await connect(sshd, probe: probe)
        let echoed = try await client.exec("echo legacy-ok")
        XCTAssertEqual(echoed, "legacy-ok\n", file: file, line: line)
        XCTAssertEqual(client.legacyAlgorithmsInUse, expected, file: file, line: line)
        await client.close()
        await sshd.waitForConnections(2)
        XCTAssertEqual(sshd.connections, 2, sshd.log, file: file, line: line)
        XCTAssertEqual(probe.challenges.count, 1, file: file, line: line)

        let refused = ApproverProbe(.approve)
        let message = await assertConnectionError({
            _ = try await self.connect(sshd, probe: refused, legacyFallback: false)
        }) { if case .handshakeFailed(let message) = $0 { return message } else { return nil } }
        XCTAssertEqual(message, SSHErrorText.describe(SSHClientError.noCommonAlgorithm(refusal)), file: file, line: line)
        await sshd.waitForConnections(3)
        XCTAssertEqual(sshd.connections, 3, file: file, line: line)
        XCTAssertTrue(refused.challenges.isEmpty, file: file, line: line)
    }

    /// AES-GCM 加密（MAC 不用），但 sshd 只报了 `hmac-sha1`：要补上旧算法名字才协商得出来。给人看的
    /// `legacyAlgorithmsInUse` 为空（MAC 不在用），给 App 记录用的三态仍是「需要」（否则 App 会刚同意就把记录清掉）。
    func testAEADWithOnlySHA1MACNameCountsAsNeeded() async throws {
        let sshd = try await start(["Ciphers aes256-gcm@openssh.com", "MACs hmac-sha1"])
        let probe = ApproverProbe(.approve)
        let client = try await connect(sshd, probe: probe)
        XCTAssertEqual(client.target.negotiatedAlgorithms?.encryptionIsAEAD, true)
        XCTAssertEqual(client.legacyAlgorithmsInUse, [])
        XCTAssertEqual(client.targetNeededLegacyTransport, true)
        await client.close()
        await sshd.waitForConnections(2)
        XCTAssertEqual(sshd.connections, 2, sshd.log)
    }

    func testSHA1HostKeyOnly() async throws {
        let sshd = try await start(["HostKeyAlgorithms ssh-rsa"], rsaHostKey: true)
        try await assertFallback(sshd, expected: [SSHLegacyAlgorithm(role: .hostKey, name: "ssh-rsa")],
                                 refusal: .init(category: .hostKey, clientOffer: [], serverOffer: ["ssh-rsa"]))
    }

    func testGroup14SHA1Only() async throws {
        let sshd = try await start(["KexAlgorithms diffie-hellman-group14-sha1"])
        try await assertFallback(
            sshd, expected: [SSHLegacyAlgorithm(role: .keyExchange, name: "diffie-hellman-group14-sha1")],
            refusal: .init(category: .keyExchange, clientOffer: [], serverOffer: ["diffie-hellman-group14-sha1"]))
    }

    func testHMACSHA1Only() async throws {
        let sshd = try await start(["Ciphers aes128-ctr", "MACs hmac-sha1"])
        try await assertFallback(sshd, expected: [SSHLegacyAlgorithm(role: .mac, name: "hmac-sha1")],
                                 refusal: .init(category: .mac, clientOffer: [], serverOffer: ["hmac-sha1"]))
    }

    func testModernSSHDConnectsOnce() async throws {
        let sshd = try await start([])
        let probe = ApproverProbe(.approve)
        let client = try await connect(sshd, probe: probe)
        XCTAssertEqual(client.legacyAlgorithmsInUse, [])
        XCTAssertEqual(client.target.negotiatedAlgorithms?.keyExchange, "curve25519-sha256")
        await client.close()
        await sshd.waitForConnections(1)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sshd.connections, 1)
    }

    /// 补上旧算法也协商不出来：第一次卡在密钥交换（只有 group14-sha1，再试），第二次卡在加密（只有 CBC，我们不支持）。
    /// 恰好两次连接，报的是第二次的错。
    func testNoCommonAlgorithmEvenWithLegacyFailsAfterExactlyTwoAttempts() async throws {
        let sshd = try await start(["KexAlgorithms diffie-hellman-group14-sha1", "Ciphers aes128-cbc"])
        let probe = ApproverProbe(.approve)
        let message = await assertConnectionError({
            _ = try await self.connect(sshd, probe: probe)
        }) { if case .handshakeFailed(let message) = $0 { return message } else { return nil } }
        XCTAssertEqual(message, SSHErrorText.describe(SSHClientError.noCommonAlgorithm(
            .init(category: .encryption, clientOffer: [], serverOffer: ["aes128-cbc"]))))
        await sshd.waitForConnections(2)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sshd.connections, 2)
        XCTAssertTrue(probe.challenges.isEmpty)
    }
}
