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
            guard case .plaintext(let keyType, _, _) =
                    try OpenSSHContainer.openPrivateSection(text: pem) else {
                return XCTFail("\(expected) 应为明文容器")
            }
            XCTAssertEqual(keyType, expected)
        }
    }

    /// 给了口令就地解密，私钥段照常读出声明的算法。
    func testEncryptedContainerOpensWithPassphrase() throws {
        guard case .plaintext(let keyType, _, _) = try OpenSSHContainer.openPrivateSection(
            text: KeyImportFixtures.rsaOpenSSHEnc,
            passphrase: KeyImportFixtures.passphrase) else {
            return XCTFail("给了口令应解开为明文私钥段")
        }
        XCTAssertEqual(keyType, "ssh-rsa")
    }

    /// 不给口令时不解密，只把 ciphername 报出去（调用方据此决定报错措辞）。
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

/// OpenSSH 容器的公钥段必须和私钥段是同一把钥匙：否则界面显示的指纹（以前取自公钥段）和真正用来认证的钥匙
/// 可以不是同一把。拼接两份容器（公钥段取 A、私钥段取 B）的文件一律「私钥结构损坏」。
final class OpenSSHContainerSpliceTests: XCTestCase {

    /// 明文容器的（公钥段, 私钥段）。
    private func sections(_ pem: String) throws -> (public: [UInt8], private: [UInt8]) {
        let der = try PEMDocument.parse(pem).der
        var reader = SSHWireReader(Array(der.dropFirst(Array("openssh-key-v1\u{0}".utf8).count)))
        _ = try reader.readString()
        _ = try reader.readString()
        _ = try reader.readString()
        _ = try reader.readUInt32()
        return (try reader.readString(), try reader.readString())
    }

    private func splice(publicFrom a: String, privateFrom b: String) throws -> String {
        var out = SSHWireWriter()
        out.writeRawBytes(Array("openssh-key-v1\u{0}".utf8))
        out.writeString("none")
        out.writeString("none")
        out.writeString([UInt8]())
        out.writeUInt32(1)
        out.writeString(try sections(a).public)
        out.writeString(try sections(b).private)
        return OpenSSHTestContainers.armor(out.bytes)
    }

    private func assertMalformed(_ pem: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PrivateKeyImporter.resolve(pem: pem, passphrase: nil), file: file, line: line) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .malformedKey(reason: ""), "\($0)", file: file, line: line)
        }
    }

    func testSplicedEd25519IsRejected() throws {
        let a = SSHKeyGenerator.generateEd25519(comment: "a").privateKeyText
        let b = SSHKeyGenerator.generateEd25519(comment: "b").privateKeyText
        assertMalformed(try splice(publicFrom: a, privateFrom: b))
        XCTAssertNoThrow(try PrivateKeyImporter.resolve(pem: try splice(publicFrom: b, privateFrom: b), passphrase: nil))
    }

    func testSplicedECDSAIsRejected() throws {
        for kind in [SSHPrivateKeyKind.ecdsaP256, .ecdsaP384, .ecdsaP521] {
            let a = try SSHKeyGenerator.generateECDSA(type: kind, comment: "a").privateKeyText
            let b = try SSHKeyGenerator.generateECDSA(type: kind, comment: "b").privateKeyText
            assertMalformed(try splice(publicFrom: a, privateFrom: b))
            XCTAssertNoThrow(try PrivateKeyImporter.resolve(pem: try splice(publicFrom: b, privateFrom: b), passphrase: nil))
        }
    }

    func testSplicedRSAIsRejected() throws {
        let c = try OpenSSHRSADecoder.decodeComponents(openSSHText: KeyImportFixtures.rsaOpenSSH)
        var otherN = c.modulus
        otherN[otherN.count / 2] ^= 0x40
        let wrongPublic = SSHPublicMaterial.rsaBlob(e: c.publicExponent, n: otherN)
        assertMalformed(OpenSSHTestContainers.rsa(n: c.modulus, e: c.publicExponent, d: c.privateExponent,
                                                  iqmp: c.coefficient ?? [1], p: c.prime1, q: c.prime2,
                                                  publicBlob: wrongPublic))
        // 同样的数值、公钥段里多一个前导零：值相同，照收。
        var padded = SSHWireWriter()
        padded.writeString("ssh-rsa")
        padded.writeString([0x00, 0x00] + c.publicExponent)
        padded.writeString([0x00] + c.modulus)
        XCTAssertNoThrow(try PrivateKeyImporter.resolve(
            pem: OpenSSHTestContainers.rsa(n: c.modulus, e: c.publicExponent, d: c.privateExponent, iqmp: [1],
                                           p: c.prime1, q: c.prime2, publicBlob: padded.bytes), passphrase: nil))
        // 公钥段后面多出字节、或类型名不对：拒绝。
        assertMalformed(OpenSSHTestContainers.rsa(n: c.modulus, e: c.publicExponent, d: c.privateExponent, iqmp: [1],
                                                  p: c.prime1, q: c.prime2,
                                                  publicBlob: SSHPublicMaterial.rsaBlob(e: c.publicExponent, n: c.modulus) + [0]))
        var wrongType = SSHWireWriter()
        wrongType.writeString("ssh-dss")
        wrongType.writeMPInt(c.publicExponent)
        wrongType.writeMPInt(c.modulus)
        // 公钥段说是 DSA：按公钥段的类型分发，先被当成 DSA 拒绝——反正不会用私钥段里的 RSA 去认证。
        XCTAssertThrowsError(try PrivateKeyImporter.resolve(
            pem: OpenSSHTestContainers.rsa(n: c.modulus, e: c.publicExponent, d: c.privateExponent, iqmp: [1],
                                           p: c.prime1, q: c.prime2, publicBlob: wrongType.bytes), passphrase: nil))
    }

    /// 指纹取自真正用来认证的那把钥匙（与同一把钥匙的 PEM 一致）。
    func testInspectorFingerprintComesFromThePrivateKey() throws {
        let generated = SSHKeyGenerator.generateEd25519(comment: "c")
        let parsed = try SSHPrivateKeyParser.parse(pem: generated.privateKeyText)
        let material = try KeyImportInspector.inspect(rawText: generated.privateKeyText, parsed: parsed, comment: "c")
        XCTAssertEqual(material.fingerprint, generated.fingerprint)
    }
}
