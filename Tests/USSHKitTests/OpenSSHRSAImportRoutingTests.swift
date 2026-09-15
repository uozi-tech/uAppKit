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

    /// 带口令的容器 → 同样是 rsa-sha2-512。容器在 USSHKit 里就解开了
    /// （bcrypt_pbkdf 由 Citadel fork 导出的 CCitadelBcrypt 提供），不再回退 Citadel
    /// 的 SHA-1 老路 —— 回退的话在 OpenSSH 8.8+ 服务端上一样连不上。
    func testEncryptedOpenSSHRSATakesSHA2Path() throws {
        let key = try PrivateKeyImporter.resolve(
            pem: KeyImportFixtures.rsaOpenSSHEnc,
            passphrase: KeyImportFixtures.passphrase)
        guard case .rsa = key else {
            return XCTFail("应为 .rsa（rsa-sha2-512），得 \(key)")
        }
    }

    /// 口令错不再被回退路径改写成"私钥结构损坏"。
    func testEncryptedOpenSSHRSAWrongPassphraseReportsIncorrectPassphrase() {
        XCTAssertThrowsError(try PrivateKeyImporter.resolve(
            pem: KeyImportFixtures.rsaOpenSSHEnc, passphrase: "wrong")) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .incorrectPassphrase)
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
