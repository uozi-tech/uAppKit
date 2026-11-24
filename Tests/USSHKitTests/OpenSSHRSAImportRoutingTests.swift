import XCTest
@testable import USSHKit

/// `PrivateKeyImporter` 对 OpenSSH 容器里 RSA 的分流：一律解成 `.rsa`（USSHCore 的 `SSHRSAPrivateKey`，
/// 以 rsa-sha2-512 / -256 认证）。迁移前解不动的容器会回退到 Citadel 的 SHA-1 老路，那条路已经删了。
final class OpenSSHRSAImportRoutingTests: XCTestCase {

    /// 未加密容器 → `.rsa`。
    func testUnencryptedOpenSSHRSATakesSHA2Path() throws {
        let key = try PrivateKeyImporter.resolve(
            pem: KeyImportFixtures.rsaOpenSSH, passphrase: nil)
        guard case .rsa = key else {
            return XCTFail("应为 .rsa（rsa-sha2-512），得 \(key)")
        }
    }

    /// 带口令的容器 → 同样是 `.rsa`。容器在 USSHKit 里就解开了（bcrypt_pbkdf 在本包的 CBcryptPBKDF）。
    func testEncryptedOpenSSHRSATakesSHA2Path() throws {
        let key = try PrivateKeyImporter.resolve(
            pem: KeyImportFixtures.rsaOpenSSHEnc,
            passphrase: KeyImportFixtures.passphrase)
        guard case .rsa = key else {
            return XCTFail("应为 .rsa（rsa-sha2-512），得 \(key)")
        }
    }

    /// 口令错报口令错，不是「私钥结构损坏」。
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
