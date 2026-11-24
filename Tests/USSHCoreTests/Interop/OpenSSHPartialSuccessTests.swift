import NIOSSH
@testable import USSHCore
import XCTest

/// 对本机真实 sshd 的多步认证。非 root 的 sshd 校验不了口令（`UsePAM no`），所以用 `AuthenticationMethods
/// publickey,publickey`：两把不同的钥匙各一步。第一步 RSA（sshd 宣告 server-sig-algs，第一次就用 rsa-sha2-512），
/// 部分成功后不再换算法重递 RSA，而是交出第二把钥匙；只配一把钥匙时失败详情是「部分成功、还要 publickey」。
/// sshd 起不来时跳过。
final class OpenSSHPartialSuccessTests: XCTestCase {
    private func start() async throws -> OpenSSHFixture {
        let fixture = try await OpenSSHFixture.start(extraConfig: "AuthenticationMethods publickey,publickey", logLevel: "DEBUG1")
        addTeardownBlock { fixture.stop() }
        return fixture
    }

    func testRSAThenEd25519() async throws {
        let fixture = try await start()
        let client = try await fixture.connect(
            methods: [.rsaPrivateKey(fixture.rsa2048Key), .privateKey(fixture.ed25519Key)], algorithms: .standard)
        XCTAssertEqual(client.rsaUserAuthenticationAlgorithm, .rsaSHA2_512)
        await client.close()
        XCTAssertTrue(fixture.sshdLog.contains("Partial publickey"), fixture.sshdLog.suffix(2000).description)
    }

    func testSecondStepMissing() async throws {
        let fixture = try await start()
        do {
            _ = try await fixture.connect(methods: [.rsaPrivateKey(fixture.rsa2048Key)], algorithms: .standard)
            XCTFail("应当失败")
        } catch SSHClientError.authenticationFailed(let failure) {
            XCTAssertEqual(failure.partiallyAcceptedMethods, [.publicKey])
            XCTAssertEqual(failure.attemptedMethods, [.publicKey], "部分通过之后不再拿同一把钥匙换 rsa-sha2-256 重递")
            XCTAssertTrue(failure.remainingMethods.contains(.publicKey))
        }
    }
}
