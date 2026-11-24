import Crypto
import XCTest
@testable import USSHKit

/// 私钥导入的格式矩阵（迁移前 uTerm 的 `PrivateKeyImporterTests` 那一套，改到 USSHKit 自己的测试里）。
/// 登录这一步在 `ConnectIntegrationTests.testEveryImportableKeyAuthenticates`。
final class KeyImportMatrixTests: XCTestCase {

    func testCommonKeyImportMatrixResolvesSupportedFormats() throws {
        let pass = KeyImportFixtures.passphrase
        let cases: [(String, String, String?, SSHPrivateKeyKind)] = [
            ("rsa openssh", KeyImportFixtures.rsaOpenSSH, nil, .rsa),
            ("rsa openssh encrypted", KeyImportFixtures.rsaOpenSSHEnc, pass, .rsa),
            ("rsa pkcs1", KeyImportFixtures.rsaPKCS1, nil, .rsa),
            ("rsa pkcs1 encrypted", KeyImportFixtures.rsaPKCS1Enc, pass, .rsa),
            ("rsa pkcs8", KeyImportFixtures.rsaPKCS8, nil, .rsa),
            ("rsa pkcs8 encrypted", KeyImportFixtures.rsaPKCS8Enc, pass, .rsa),
            ("ed25519 openssh", KeyImportFixtures.ed25519OpenSSH, nil, .ed25519),
            ("ed25519 openssh encrypted", KeyImportFixtures.ed25519OpenSSHEnc, pass, .ed25519),
            ("ed25519 pkcs8", KeyImportFixtures.ed25519PKCS8, nil, .ed25519),
            ("ed25519 pkcs8 encrypted", KeyImportFixtures.ed25519PKCS8Enc, pass, .ed25519),
            ("ecdsa p256 openssh", KeyImportFixtures.ecP256OpenSSH, nil, .ecdsaP256),
            ("ecdsa p384 openssh", KeyImportFixtures.ecP384OpenSSH, nil, .ecdsaP384),
            ("ecdsa p521 openssh", KeyImportFixtures.ecP521OpenSSH, nil, .ecdsaP521),
            ("ecdsa p256 sec1", KeyImportFixtures.ecP256SEC1, nil, .ecdsaP256),
            ("ecdsa p384 sec1", KeyImportFixtures.ecP384SEC1, nil, .ecdsaP384),
            ("ecdsa p521 sec1", KeyImportFixtures.ecP521SEC1, nil, .ecdsaP521),
            ("ecdsa p256 sec1 encrypted", KeyImportFixtures.ecP256SEC1Enc, pass, .ecdsaP256),
            ("ecdsa p256 sec1 named", KeyImportFixtures.ecP256SEC1Named, nil, .ecdsaP256),
            ("ecdsa p256 pkcs8", KeyImportFixtures.ecP256PKCS8, nil, .ecdsaP256),
        ]
        for (name, pem, passphrase, expected) in cases {
            let key = try PrivateKeyImporter.resolve(pem: pem, passphrase: passphrase)
            XCTAssertEqual(key.kind, expected, name)
        }
    }

    func testPassphraseErrors() {
        for pem in [KeyImportFixtures.rsaPKCS8Enc, KeyImportFixtures.rsaOpenSSHEnc, KeyImportFixtures.ed25519OpenSSHEnc] {
            XCTAssertThrowsError(try PrivateKeyImporter.resolve(pem: pem, passphrase: nil)) {
                XCTAssertEqual($0 as? PrivateKeyImportError, .encryptedKeyNeedsPassphrase)
            }
            XCTAssertThrowsError(try PrivateKeyImporter.resolve(pem: pem, passphrase: "wrong")) {
                XCTAssertEqual($0 as? PrivateKeyImportError, .incorrectPassphrase)
            }
        }
    }

    func testRejectedFormats() {
        XCTAssertThrowsError(try PrivateKeyImporter.resolve(pem: KeyImportFixtures.dsaPEM, passphrase: nil)) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .dsaUnsupported)
        }
        XCTAssertThrowsError(try PrivateKeyImporter.resolve(pem: "not a key", passphrase: nil)) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .malformedPEM(reason: ""))
        }
        // 加密的 OpenSSH ECDSA 容器迁移前就是故意拒绝的（放开是产品决定）。
        XCTAssertThrowsError(try PrivateKeyImporter.resolve(
            pem: KeyImportFixtures.ecP256OpenSSHEnc, passphrase: KeyImportFixtures.passphrase)) {
            guard case PrivateKeyImportError.unsupportedFormat = $0 else { return XCTFail("\($0)") }
        }
    }

    /// OpenSSH 容器的 Ed25519 自己解（迁移前交给 Citadel）：种子推出的公钥要与容器里记的一致。
    func testOpenSSHEd25519MatchesEmbeddedPublicKey() throws {
        for (pem, passphrase) in [(KeyImportFixtures.ed25519OpenSSH, nil),
                                  (KeyImportFixtures.ed25519OpenSSHEnc, KeyImportFixtures.passphrase)] {
            guard case .ed25519(let key) = try PrivateKeyImporter.resolve(pem: pem, passphrase: passphrase) else {
                return XCTFail("应为 ed25519")
            }
            let parsed = try SSHPrivateKeyParser.parse(pem: pem, passphrase: passphrase)
            let material = try KeyImportInspector.inspect(rawText: pem, parsed: parsed, comment: "c")
            let blob = SSHPublicMaterial.ed25519Blob(pub: [UInt8](key.publicKey.rawRepresentation))
            XCTAssertEqual(material.fingerprint, SSHPublicMaterial.fingerprint(of: blob))
        }
    }

    /// 迁移前只有 n / e / d 的 OpenSSH RSA 容器靠 Citadel 的 SHA-1 老路导入；现在还原出 p / q，
    /// 和别的 RSA 私钥一样以 SHA-2 签名，而且就是同一把密钥。
    func testOpenSSHRSAWithoutPrimesIsRecovered() throws {
        let pem = OpenSSHTestContainers.rsaWithoutPrimes(KeyImportFixtures.rsaOpenSSH)
        guard case .rsa(let recovered) = try PrivateKeyImporter.resolve(pem: pem, passphrase: nil),
              case .rsa(let original) = try PrivateKeyImporter.resolve(pem: KeyImportFixtures.rsaOpenSSH, passphrase: nil)
        else { return XCTFail("应为 .rsa") }
        XCTAssertEqual(recovered.publicKey, original.publicKey)

        let message = Array("prime recovery".utf8)
        let signature = try recovered.signature(for: message, algorithm: .rsaSHA2_512)
        XCTAssertTrue(original.publicKey.isValidSignature(signature, for: message, algorithm: .rsaSHA2_512))
    }

    func testPrimeRecoveryMatchesTheRealFactors() throws {
        let components = try OpenSSHRSADecoder.decodeComponents(openSSHText: KeyImportFixtures.rsaOpenSSH)
        let primes = try XCTUnwrap(RSAKeyMaterial.recoverPrimes(
            modulus: components.modulus, publicExponent: components.publicExponent,
            privateExponent: components.privateExponent))
        XCTAssertEqual(Set([primes.p, primes.q]), Set([components.prime1, components.prime2]))
    }

    func testPrimeRecoveryRejectsInconsistentComponents() throws {
        let components = try OpenSSHRSADecoder.decodeComponents(openSSHText: KeyImportFixtures.rsaOpenSSH)
        var wrongD = components.privateExponent
        wrongD[wrongD.count - 1] ^= 0x02
        XCTAssertNil(RSAKeyMaterial.recoverPrimes(
            modulus: components.modulus, publicExponent: components.publicExponent, privateExponent: wrongD))
    }

    /// 分量互相不一致的 PKCS#1：导入时就报「私钥结构损坏」（迁移前要等到建连时才失败）。
    func testInconsistentRSAComponentsFailAtImport() throws {
        var components = try RSAKeyMaterial.componentsFromPKCS1DER(PEMDocument.parse(KeyImportFixtures.rsaPKCS1).der)
        components.prime1[components.prime1.count - 1] ^= 0x02
        XCTAssertThrowsError(try RSAKeyMaterial.makeKey(components)) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .malformedKey(reason: ""))
        }
    }

    func testInspectorReportsRSAPublicMaterialForPEM() throws {
        let parsed = try SSHPrivateKeyParser.parse(pem: KeyImportFixtures.rsaPKCS1)
        let fromPEM = try KeyImportInspector.inspect(rawText: KeyImportFixtures.rsaPKCS1, parsed: parsed, comment: "c")
        let container = try SSHPrivateKeyParser.parse(pem: KeyImportFixtures.rsaOpenSSH)
        let fromContainer = try KeyImportInspector.inspect(rawText: KeyImportFixtures.rsaOpenSSH, parsed: container, comment: "c")
        XCTAssertEqual(fromPEM.type, .rsa)
        XCTAssertEqual(fromPEM.bits, 2048)
        XCTAssertEqual(fromPEM.fingerprint, fromContainer.fingerprint, "同一把密钥的两种格式")
    }
}
