import Crypto
import XCTest
@testable import USSHKit

/// OpenSSH 容器里的 RSA 私钥。修的是这条路：容器格式的 RSA 原先一律交给 Citadel，
/// 只能以 `ssh-rsa`（SHA-1）签名，而 OpenSSH 8.8+ 服务端默认拒收 SHA-1 公钥签名 ——
/// 同一把密钥 `ssh` 连得上、uTerm 却报 `allAuthenticationOptionsFailed`。
final class OpenSSHRSADecoderTests: XCTestCase {

    /// 同一把密钥的两种落盘格式必须解出同一组分量 —— PKCS#1 那条路已被
    /// `RSASHA512Signer` 长期使用，拿它当基准。
    func testOpenSSHComponentsMatchSameKeyInPKCS1() throws {
        let fromContainer = try XCTUnwrap(
            try OpenSSHRSADecoder.decodeComponents(openSSHText: KeyImportFixtures.rsaOpenSSH))
        let fromPEM = try RSAKeyComponents.fromPKCS1DER(
            PEMDocument.parse(KeyImportFixtures.rsaPKCS1).der)

        XCTAssertEqual(fromContainer.modulus, fromPEM.modulus)
        XCTAssertEqual(fromContainer.publicExponent, fromPEM.publicExponent)
        XCTAssertEqual(fromContainer.privateExponent, fromPEM.privateExponent)
        // p/q 只在私钥段里，读错位（分量顺序是 n,e,d,iqmp,p,q）就会在这里露出来。
        XCTAssertEqual(fromContainer.prime1, fromPEM.prime1)
        XCTAssertEqual(fromContainer.prime2, fromPEM.prime2)
        XCTAssertEqual(fromContainer.modulus.count, 256, "2048 位模数应为 256 字节")
    }

    /// 端到端：容器解出的分量能造出可用的 rsa-sha2-512 签名并被自身公钥验过。
    /// p/q 错了的话 `_RSA.Signing.PrivateKey` 要么构造失败、要么签出的名验不过。
    func testComponentsFromContainerProduceVerifiableRSASHA512Signature() throws {
        let components = try XCTUnwrap(
            try OpenSSHRSADecoder.decodeComponents(openSSHText: KeyImportFixtures.rsaOpenSSH))
        let signer = try RSASHA512Signer(components: components)
        let message = Array("uterm rsa-sha2-512 round trip".utf8)

        let signature = try signer.sign(message)

        XCTAssertTrue(RSASHA512Signer.isValidSignature(
            signature, for: message,
            modulus: components.modulus, publicExponent: components.publicExponent))
        XCTAssertFalse(RSASHA512Signer.isValidSignature(
            signature, for: Array("tampered".utf8),
            modulus: components.modulus, publicExponent: components.publicExponent))
    }

    /// 加密容器返回 nil（而不是抛错）—— 调用方据此回退 Citadel 老路。
    func testEncryptedContainerReturnsNilForFallback() throws {
        XCTAssertNil(try OpenSSHRSADecoder.decodeComponents(
            openSSHText: KeyImportFixtures.rsaOpenSSHEnc))
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
