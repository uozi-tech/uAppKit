import XCTest
@testable import USSHKit

/// OpenSSH 容器里的 RSA 私钥。容器格式的 RSA 自己解出分量，交给 USSHCore 的 `SSHRSAPrivateKey`
/// 以 rsa-sha2-512 / -256 签名（OpenSSH 8.8+ 服务端默认拒收 SHA-1 的 `ssh-rsa` 签名）。
final class OpenSSHRSADecoderTests: XCTestCase {

    /// 同一把密钥的两种落盘格式必须解出同一组分量 —— 拿 PKCS#1 那条路当基准。
    func testOpenSSHComponentsMatchSameKeyInPKCS1() throws {
        let fromContainer = try OpenSSHRSADecoder.decodeComponents(
            openSSHText: KeyImportFixtures.rsaOpenSSH)
        let fromPEM = try RSAKeyMaterial.componentsFromPKCS1DER(
            PEMDocument.parse(KeyImportFixtures.rsaPKCS1).der)

        XCTAssertEqual(fromContainer.modulus, fromPEM.modulus)
        XCTAssertEqual(fromContainer.publicExponent, fromPEM.publicExponent)
        XCTAssertEqual(fromContainer.privateExponent, fromPEM.privateExponent)
        // p/q 只在私钥段里，读错位（分量顺序是 n,e,d,iqmp,p,q）就会在这里露出来。
        XCTAssertEqual(fromContainer.prime1, fromPEM.prime1)
        XCTAssertEqual(fromContainer.prime2, fromPEM.prime2)
        XCTAssertEqual(fromContainer.modulus.count, 256, "2048 位模数应为 256 字节")
    }

    /// 端到端：容器解出的分量能造出可用的 rsa-sha2-512 / -256 签名并被自身公钥验过。
    /// p/q 错了的话 `SSHRSAPrivateKey` 要么构造失败、要么签出的名验不过。
    func testComponentsFromContainerProduceVerifiableRSASHA2Signatures() throws {
        let components = try OpenSSHRSADecoder.decodeComponents(
            openSSHText: KeyImportFixtures.rsaOpenSSH)
        let key = try RSAKeyMaterial.makeKey(components)
        let message = Array("uterm rsa-sha2 round trip".utf8)

        for algorithm in [SSHRSASignatureAlgorithm.rsaSHA2_512, .rsaSHA2_256] {
            let signature = try key.signature(for: message, algorithm: algorithm)
            XCTAssertTrue(key.publicKey.isValidSignature(signature, for: message, algorithm: algorithm))
            XCTAssertFalse(key.publicKey.isValidSignature(
                signature, for: Array("tampered".utf8), algorithm: algorithm))
        }
    }

    /// 带口令的容器：bcrypt_pbkdf + aes-ctr 就地解密，同样解出分量。
    /// 解错一个字节，下面的签名就验不过 —— 这比只断言"没抛错"扎实得多。
    func testEncryptedContainerDecryptsAndProducesVerifiableSignature() throws {
        let components = try OpenSSHRSADecoder.decodeComponents(
            openSSHText: KeyImportFixtures.rsaOpenSSHEnc,
            passphrase: KeyImportFixtures.passphrase)
        XCTAssertEqual(components.modulus.count, 256, "2048 位模数应为 256 字节")

        let key = try RSAKeyMaterial.makeKey(components)
        let message = Array("uterm encrypted container round trip".utf8)
        let signature = try key.signature(for: message, algorithm: .rsaSHA2_512)

        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: message, algorithm: .rsaSHA2_512))
    }

    func testEncryptedContainerWithoutPassphraseReportsNeedsPassphrase() {
        XCTAssertThrowsError(try OpenSSHRSADecoder.decodeComponents(
            openSSHText: KeyImportFixtures.rsaOpenSSHEnc)) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .encryptedKeyNeedsPassphrase)
        }
    }

    /// 口令错 → checkint 对不上 → `.incorrectPassphrase`（不是"结构损坏"）。
    func testEncryptedContainerWrongPassphraseReportsIncorrectPassphrase() {
        XCTAssertThrowsError(try OpenSSHRSADecoder.decodeComponents(
            openSSHText: KeyImportFixtures.rsaOpenSSHEnc, passphrase: "wrong")) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .incorrectPassphrase)
        }
    }

    func testNonRSAContainerRejected() {
        XCTAssertThrowsError(try OpenSSHRSADecoder.decodeComponents(
            openSSHText: KeyImportFixtures.ed25519OpenSSH)) {
            guard case PrivateKeyImportError.unsupportedFormat = $0 else {
                return XCTFail("应抛 unsupportedFormat，实际 \($0)")
            }
        }
    }

    func testGarbageRejected() {
        XCTAssertThrowsError(
            try OpenSSHRSADecoder.decodeComponents(openSSHText: "not a key"))
    }
}
