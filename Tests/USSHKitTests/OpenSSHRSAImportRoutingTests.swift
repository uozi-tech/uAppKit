import XCTest
@testable import USSHKit

/// `PrivateKeyImporter` 对 OpenSSH 容器里 RSA 的分流。
/// 这里判的不是"能不能导入"（一直都能），而是**导入后用哪种签名算法认证**。
final class OpenSSHRSAImportRoutingTests: XCTestCase {

    /// 未加密容器 → rsa-sha2-512（`.rsa`），不再是 SHA-1 的 `.legacyOpenSSHRSA`。
    func testUnencryptedOpenSSHRSATakesSHA2Path() throws {
        let key = try PrivateKeyImporter.resolve(
            pem: KeyImportFixtures.rsaOpenSSH, passphrase: nil)
        guard case .rsa = key else {
            return XCTFail("应为 .rsa（rsa-sha2-512），得 \(key)")
        }
    }

    /// 带口令的容器仍回退 Citadel —— 解密要 bcrypt_pbkdf，包外够不着。
    /// 行为与修复前一致；此断言是这条已知缺口的备忘。
    func testEncryptedOpenSSHRSAStillFallsBackToCitadel() throws {
        let key = try PrivateKeyImporter.resolve(
            pem: KeyImportFixtures.rsaOpenSSHEnc,
            passphrase: KeyImportFixtures.passphrase)
        guard case .legacyOpenSSHRSA = key else {
            return XCTFail("应为 .legacyOpenSSHRSA，得 \(key)")
        }
    }

    func testEncryptedOpenSSHRSAWithoutPassphraseStillReportsNeedsPassphrase() {
        XCTAssertThrowsError(try PrivateKeyImporter.resolve(
            pem: KeyImportFixtures.rsaOpenSSHEnc, passphrase: nil)) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .encryptedKeyNeedsPassphrase)
        }
    }

    /// PEM 那条路不受影响。
    func testPKCS1StillTakesSHA2Path() throws {
        let key = try PrivateKeyImporter.resolve(
            pem: KeyImportFixtures.rsaPKCS1, passphrase: nil)
        guard case .rsa = key else { return XCTFail("应为 .rsa，得 \(key)") }
    }
}
