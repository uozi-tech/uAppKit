import XCTest
@testable import USSHKit

/// `OpenSSHContainer` 是 RSA 与 ECDSA 两个解码器共用的外层解析；
/// 这里同时守住 ECDSA 那条路在抽取共用件后没走样。
final class OpenSSHContainerTests: XCTestCase {

    func testPlaintextContainerReportsDeclaredKeyType() throws {
        let cases = [
            (KeyImportFixtures.rsaOpenSSH, "ssh-rsa"),
            (KeyImportFixtures.ed25519OpenSSH, "ssh-ed25519"),
            (KeyImportFixtures.ecP256OpenSSH, "ecdsa-sha2-nistp256"),
        ]
        for (pem, expected) in cases {
            guard case .plaintext(let keyType, _) =
                    try OpenSSHContainer.openPrivateSection(text: pem) else {
                return XCTFail("\(expected) 应为明文容器")
            }
            XCTAssertEqual(keyType, expected)
        }
    }

    func testEncryptedContainerReportsCipherName() throws {
        guard case .encrypted(let cipherName) =
                try OpenSSHContainer.openPrivateSection(text: KeyImportFixtures.rsaOpenSSHEnc) else {
            return XCTFail("应识别为加密容器")
        }
        XCTAssertFalse(cipherName.isEmpty)
        XCTAssertNotEqual(cipherName, "none")
    }

    func testNonOpenSSHTextRejected() {
        XCTAssertThrowsError(try OpenSSHContainer.openPrivateSection(
            text: KeyImportFixtures.rsaPKCS1))
    }

    func testECDSADecoderStillDecodesPlaintextContainer() throws {
        let key = try OpenSSHECDSADecoder.decode(openSSHText: KeyImportFixtures.ecP256OpenSSH)
        guard case .p256 = key else { return XCTFail("应为 p256，得 \(key)") }
    }

    func testECDSADecoderStillRejectsEncryptedContainer() {
        XCTAssertThrowsError(try OpenSSHECDSADecoder.decode(
            openSSHText: KeyImportFixtures.ecP256OpenSSHEnc)) {
            guard case PrivateKeyImportError.unsupportedFormat = $0 else {
                return XCTFail("应抛 unsupportedFormat，实际 \($0)")
            }
        }
    }
}
