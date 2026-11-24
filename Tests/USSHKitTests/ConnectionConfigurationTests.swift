import XCTest
@_spi(uTermIntegration) @testable import USSHKit

/// 每一跳的 USSHCore 配置（`makeConfiguration`）。迁移前的 `ProtocolOptionsTests` 盯的是「跳板机内层 hop 也带上
/// `maximumPacketSize`」——漏了它内层子通道的窗口就还是默认值；现在两跳走同一个函数，这里钉住它填的每个字段。
final class ConnectionConfigurationTests: XCTestCase {

    private func configuration(
        policy: SSHHostKeyPolicy = .acceptNew,
        maximumPacketSize: Int = SSHClient.defaultMaximumPacketSize,
        credential: SSHCredential = .password("secret")
    ) throws -> SSHClient.Configuration {
        try USSHKitIntegration.makeConfiguration(
            host: "db.example.com", port: 2222, username: "database", credential: credential,
            hostKeyStore: MemoryHostKeyStore(), hostKeyPolicy: policy,
            connectTimeout: .seconds(15), approvalTimeout: .seconds(180),
            approver: { _ in true }, maximumPacketSize: maximumPacketSize)
    }

    func testCarriesMaximumPacketSize() throws {
        let configuration = try configuration(maximumPacketSize: 1 << 20)
        XCTAssertEqual(configuration.maximumPacketSize, 1 << 20)
        XCTAssertEqual(configuration.channelWindowSize, 64 << 20)
    }

    /// 越界值不用调用方自己夹：USSHCore 夹进区间（NIOSSH 对越界值是 precondition，进程 abort）。
    func testOutOfRangePacketSizeIsClampedByCore() throws {
        XCTAssertEqual(try configuration(maximumPacketSize: 0).effectiveMaximumPacketSize,
                       SSHClient.maximumPacketSizeRange.lowerBound)
        XCTAssertEqual(try configuration(maximumPacketSize: .max).effectiveMaximumPacketSize,
                       SSHClient.maximumPacketSizeRange.upperBound)
    }

    func testDefaultsToTodaysAlgorithmsAndPacketSize() throws {
        let configuration = try configuration()
        XCTAssertEqual(configuration.maximumPacketSize, SSHClient.defaultMaximumPacketSize)
        XCTAssertEqual(configuration.algorithms.transportProtectionSchemes.map { $0.cipherName },
                       SSHAlgorithms().transportProtectionSchemes.map { $0.cipherName },
                       "默认只用 NIOSSH 自带的算法")
    }

    /// TCP 建连与握手各给 connectTimeout；等主机密钥只有 `.ask` 给审批时限。
    func testTimeouts() throws {
        let ask = try configuration(policy: .ask)
        XCTAssertEqual(ask.connectTimeout, .seconds(15))
        XCTAssertEqual(ask.handshakeTimeout, .seconds(15))
        XCTAssertEqual(ask.hostKeyValidationTimeout, .seconds(180))

        let strict = try configuration(policy: .strict)
        XCTAssertEqual(strict.hostKeyValidationTimeout, .seconds(15))
    }

    func testAuthenticationComesFromCredential() throws {
        let password = try configuration().authentication
        XCTAssertEqual(password.username, "database")
        XCTAssertEqual(password.methods.map(\.kind), [.password])

        let rsa = try configuration(credential: .privateKey(pem: KeyImportFixtures.rsaPKCS1, passphrase: nil))
            .authentication
        XCTAssertEqual(rsa.methods.map(\.kind), [.publicKey, .publicKey], "rsa-sha2-512，再 rsa-sha2-256")

        let ed25519 = try configuration(credential: .privateKey(pem: KeyImportFixtures.ed25519OpenSSH, passphrase: nil))
            .authentication
        XCTAssertEqual(ed25519.methods.map(\.kind), [.publicKey])
    }

    func testBadCredentialFailsBeforeConnecting() {
        XCTAssertThrowsError(try configuration(credential: .privateKey(pem: "not a key", passphrase: nil))) {
            guard case SSHConnectionError.authenticationFailed = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try configuration(credential: .agent)) {
            guard case SSHConnectionError.unsupportedAgentAuthentication = $0 else { return XCTFail("\($0)") }
        }
    }
}
