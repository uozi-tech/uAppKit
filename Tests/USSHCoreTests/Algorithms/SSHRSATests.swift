import Crypto
import Foundation
import NIOCore
import Security
import XCTest

@testable import USSHCore

final class SSHRSATests: XCTestCase {
    private func components(_ key: RSAFixtures.Key, crt: Bool = true, coefficientOnly: Bool = false) -> SSHRSAPrivateKeyComponents {
        SSHRSAPrivateKeyComponents(
            modulus: [UInt8](hex: key.modulus),
            publicExponent: [UInt8](hex: key.publicExponent),
            privateExponent: [UInt8](hex: key.privateExponent),
            prime1: [UInt8](hex: key.prime1),
            prime2: [UInt8](hex: key.prime2),
            exponent1: crt && !coefficientOnly ? [UInt8](hex: key.exponent1) : nil,
            exponent2: crt && !coefficientOnly ? [UInt8](hex: key.exponent2) : nil,
            coefficient: crt || coefficientOnly ? [UInt8](hex: key.coefficient) : nil
        )
    }

    // MARK: 公钥 blob（ssh-keygen 产出）

    func testParsesAndReencodesOpenSSHPublicKeyBlobs() throws {
        for fixture in RSAFixtures.keys {
            let blob = [UInt8](hex: fixture.publicKeyBlob)
            let key = try SSHRSAPublicKey(sshBlob: blob)
            XCTAssertEqual(key.modulus, [UInt8](hex: fixture.modulus))
            XCTAssertEqual(key.publicExponent, [UInt8](hex: fixture.publicExponent))
            XCTAssertEqual(key.modulusBitCount, fixture.bits)
            XCTAssertEqual(key.isWeak, fixture.bits < 2048)
            XCTAssertEqual(key.sshBlob, blob, "重新编码必须与 OpenSSH 逐字节一致")

            // 只读主体（NIOSSH 扩展接口那条路）。
            var buffer = ByteBuffer(bytes: blob)
            _ = try buffer.readSSHWireIdentifier()
            XCTAssertEqual(try SSHRSAPublicKey(readingBodyFrom: &buffer), key)
            XCTAssertEqual(buffer.readableBytes, 0)
        }
    }

    // MARK: 私钥的各种来源

    func testPrivateKeyConstructionFromImporterForms() throws {
        for fixture in RSAFixtures.keys {
            let expected = try SSHRSAPublicKey(sshBlob: [UInt8](hex: fixture.publicKeyBlob))
            // PKCS#1 九项齐全。
            XCTAssertEqual(try SSHRSAPrivateKey(components: self.components(fixture)).publicKey, expected)
            // OpenSSH 私钥段：有 iqmp，没有 dP / dQ。
            XCTAssertEqual(try SSHRSAPrivateKey(components: self.components(fixture, coefficientOnly: true)).publicKey, expected)
            // 今天 USSHKit 的 RSAKeyComponents：只有 n, e, d, p, q。
            XCTAssertEqual(try SSHRSAPrivateKey(components: self.components(fixture, crt: false)).publicKey, expected)
            // 分量带前导零也行。
            var padded = self.components(fixture)
            padded.modulus = [0, 0] + padded.modulus
            padded.prime1 = [0] + padded.prime1
            XCTAssertEqual(try SSHRSAPrivateKey(components: padded).publicKey, expected)
            // PEM。
            XCTAssertEqual(try SSHRSAPrivateKey(pemRepresentation: fixture.pkcs1PEM).publicKey, expected)
            // DER。
            XCTAssertEqual(try SSHRSAPrivateKey(derRepresentation: Self.pemBody(fixture.pkcs1PEM)).publicKey, expected)
        }
    }

    func testInconsistentComponentsAreRejected() throws {
        let fixture = RSAFixtures.keys[1]
        var wrongD = self.components(fixture, crt: false)
        wrongD.privateExponent[wrongD.privateExponent.count - 1] ^= 0x02
        XCTAssertThrowsError(try SSHRSAPrivateKey(components: wrongD))

        var wrongP = self.components(fixture, crt: false)
        swap(&wrongP.prime1, &wrongP.privateExponent)
        XCTAssertThrowsError(try SSHRSAPrivateKey(components: wrongP))

        var wrongCoefficient = self.components(fixture)
        wrongCoefficient.coefficient![0] ^= 0x01
        XCTAssertThrowsError(try SSHRSAPrivateKey(components: wrongCoefficient)) {
            XCTAssertEqual($0 as? SSHRSAError, .invalidPrivateKey)
        }

        var wrongModulus = self.components(fixture)
        wrongModulus.modulus = [UInt8](hex: RSAFixtures.keys[2].modulus)
        XCTAssertThrowsError(try SSHRSAPrivateKey(components: wrongModulus))

        var zeroPrime = self.components(fixture, crt: false)
        zeroPrime.prime2 = [0]
        XCTAssertThrowsError(try SSHRSAPrivateKey(components: zeroPrime)) {
            XCTAssertEqual($0 as? SSHRSAError, .invalidPrivateKey)
        }
        XCTAssertThrowsError(try SSHRSAPrivateKey(derRepresentation: [0x30, 0x03, 0x02, 0x01, 0x00]))
        XCTAssertThrowsError(try SSHRSAPrivateKey(pemRepresentation: "not a key"))
    }

    // MARK: 与 OpenSSH / OpenSSL 产出的签名对照

    /// ssh-keygen -Y sign 的 SSHSIG：里面的签名 blob 是 OpenSSH 自己编码的 rsa-sha2-512。
    /// 解析、校验，并且我们对同一段数据的签名与 OpenSSH 逐字节相同（PKCS#1 v1.5 是确定性的）。
    func testOpenSSHSSHSIGSignaturesVerifyAndMatchOurs() throws {
        for fixture in RSAFixtures.keys {
            let sig = try Self.parseSSHSIG([UInt8](hex: fixture.sshsig))
            XCTAssertEqual(sig.publicKey, [UInt8](hex: fixture.publicKeyBlob))
            let publicKey = try SSHRSAPublicKey(sshBlob: sig.publicKey)
            let signature = try SSHRSASignature(sshBlob: sig.signatureBlob)
            XCTAssertEqual(signature.algorithm, .rsaSHA2_512)
            XCTAssertEqual(signature.sshBlob, sig.signatureBlob)
            XCTAssertTrue(publicKey.isValidSignature(signature, for: sig.signedData, algorithm: .rsaSHA2_512), "\(fixture.bits)")
            XCTAssertFalse(publicKey.isValidSignature(signature, for: sig.signedData + [0], algorithm: .rsaSHA2_512))

            let ours = try SSHRSAPrivateKey(components: self.components(fixture)).signature(
                for: sig.signedData,
                algorithm: .rsaSHA2_512
            )
            XCTAssertEqual(ours.sshBlob, sig.signatureBlob, "\(fixture.bits)")
        }
    }

    /// openssl dgst -sha1 / -sha256 / -sha512 -sign 的 PKCS#1 v1.5 签名。
    func testOpenSSLSignaturesForEachAlgorithm() throws {
        let message = [UInt8](hex: RSAFixtures.message)
        for fixture in RSAFixtures.keys {
            let privateKey = try SSHRSAPrivateKey(components: self.components(fixture, coefficientOnly: true))
            let cases: [(SSHRSASignatureAlgorithm, String)] = [
                (.rsaSHA2_512, fixture.sha512Signature),
                (.rsaSHA2_256, fixture.sha256Signature),
                (.sshRSA, fixture.sha1Signature),
            ]
            for (algorithm, hex) in cases {
                let expected = [UInt8](hex: hex)
                let ours = try privateKey.signature(for: message, algorithm: algorithm)
                XCTAssertEqual(ours.bytes, expected, "\(fixture.bits) \(algorithm)")
                XCTAssertEqual(ours.bytes.count, fixture.bits / 8)
                let theirs = SSHRSASignature(algorithm: algorithm, bytes: expected)
                XCTAssertTrue(privateKey.publicKey.isValidSignature(theirs, for: message, algorithm: algorithm))
                // 期望的算法与签名 blob 的算法不同：判假（防降级）。
                for other in SSHRSASignatureAlgorithm.allCases where other != algorithm {
                    XCTAssertFalse(privateKey.publicKey.isValidSignature(theirs, for: message, algorithm: other))
                    let relabelled = SSHRSASignature(algorithm: other, bytes: expected)
                    XCTAssertFalse(privateKey.publicKey.isValidSignature(relabelled, for: message, algorithm: other))
                }
            }
        }
    }

    // MARK: 与 Security.framework 双向交叉校验（测试时现算）

    func testCrossVerificationWithSecurityFramework() throws {
        let message = Array("cross-check \(UUID())".utf8)
        let pairs: [(SSHRSASignatureAlgorithm, SecKeyAlgorithm)] = [
            (.rsaSHA2_512, .rsaSignatureMessagePKCS1v15SHA512),
            (.rsaSHA2_256, .rsaSignatureMessagePKCS1v15SHA256),
            (.sshRSA, .rsaSignatureMessagePKCS1v15SHA1),
        ]
        var keys: [(SSHRSAPrivateKey, [UInt8])] = []
        for fixture in RSAFixtures.keys where fixture.bits >= 2048 {
            keys.append((try SSHRSAPrivateKey(components: self.components(fixture)), Self.pemBody(fixture.pkcs1PEM)))
        }
        let generated = try SSHRSAPrivateKey(generatingModulusBits: 3072)
        keys.append((generated, Array(generated.backing.derRepresentation)))

        for (privateKey, privateDER) in keys {
            let secPrivate = try Self.secKey(privateDER, private: true)
            let publicDER = RSADEREncoding.pkcs1PublicKey(
                modulus: privateKey.publicKey.modulus,
                publicExponent: privateKey.publicKey.publicExponent
            )
            let secPublic = try Self.secKey(publicDER, private: false)
            for (algorithm, secAlgorithm) in pairs {
                // 我们签、Security 验。
                let ours = try privateKey.signature(for: message, algorithm: algorithm)
                var error: Unmanaged<CFError>?
                XCTAssertTrue(
                    SecKeyVerifySignature(secPublic, secAlgorithm, Data(message) as CFData, Data(ours.bytes) as CFData, &error),
                    "\(algorithm) \(String(describing: error?.takeRetainedValue()))"
                )
                // Security 签、我们验；且两边逐字节相同。
                guard let theirs = SecKeyCreateSignature(secPrivate, secAlgorithm, Data(message) as CFData, &error) as Data? else {
                    XCTFail("Security 签名失败 \(String(describing: error?.takeRetainedValue()))")
                    continue
                }
                XCTAssertEqual(Array(theirs), ours.bytes)
                XCTAssertTrue(
                    privateKey.publicKey.isValidSignature(
                        SSHRSASignature(algorithm: algorithm, bytes: Array(theirs)),
                        for: message,
                        algorithm: algorithm
                    )
                )
            }
        }
    }

    // MARK: 长度宽松规则与篡改

    /// RFC 8332 §3：签名比模数短（前导零被省掉）时校验方应左侧补零；比模数长则拒绝。
    func testShortSignaturesAreLeftPaddedLongOnesRejected() throws {
        let fixture = RSAFixtures.keys[0]
        let privateKey = try SSHRSAPrivateKey(components: self.components(fixture))
        var found: ([UInt8], SSHRSASignature)?
        for attempt in 0..<4096 {
            let data = Array("leading zero \(attempt)".utf8)
            let signature = try privateKey.signature(for: data, algorithm: .rsaSHA2_256)
            if signature.bytes.first == 0 {
                found = (data, signature)
                break
            }
        }
        let (data, signature) = try XCTUnwrap(found, "4096 次签名里没有遇到首字节为 0 的签名")
        XCTAssertEqual(signature.bytes.count, privateKey.publicKey.modulusByteCount, "我们签出的总是等长")
        let stripped = SSHRSASignature(algorithm: .rsaSHA2_256, bytes: Array(signature.bytes.dropFirst()))
        XCTAssertTrue(privateKey.publicKey.isValidSignature(stripped, for: data, algorithm: .rsaSHA2_256))
        let lengthened = SSHRSASignature(algorithm: .rsaSHA2_256, bytes: [0] + signature.bytes)
        XCTAssertFalse(privateKey.publicKey.isValidSignature(lengthened, for: data, algorithm: .rsaSHA2_256))
    }

    func testTamperedSignaturesFail() throws {
        let fixture = RSAFixtures.keys[1]
        let privateKey = try SSHRSAPrivateKey(components: self.components(fixture))
        let data = Array("tamper".utf8)
        let signature = try privateKey.signature(for: data, algorithm: .rsaSHA2_512)
        for index in [0, 1, signature.bytes.count / 2, signature.bytes.count - 1] {
            var bytes = signature.bytes
            bytes[index] ^= 0x01
            XCTAssertFalse(
                privateKey.publicKey.isValidSignature(SSHRSASignature(algorithm: .rsaSHA2_512, bytes: bytes), for: data, algorithm: .rsaSHA2_512)
            )
        }
        XCTAssertFalse(
            privateKey.publicKey.isValidSignature(SSHRSASignature(algorithm: .rsaSHA2_512, bytes: []), for: data, algorithm: .rsaSHA2_512)
        )
        // 别的密钥的公钥验不过。
        let other = try SSHRSAPublicKey(sshBlob: [UInt8](hex: RSAFixtures.keys[2].publicKeyBlob))
        XCTAssertFalse(other.isValidSignature(signature, for: data, algorithm: .rsaSHA2_512))
    }

    // MARK: 畸形 blob

    func testMalformedPublicKeyBlobs() throws {
        let good = try SSHRSAPublicKey(sshBlob: [UInt8](hex: RSAFixtures.keys[1].publicKeyBlob))
        func blob(type: String = "ssh-rsa", e: [UInt8]? = nil, n: [UInt8]? = nil, rawE: [UInt8]? = nil, trailing: [UInt8] = []) -> [UInt8] {
            var buffer = ByteBuffer()
            buffer.writeSSHWireString(type)
            if let rawE {
                buffer.writeSSHWireString(rawE)
            } else {
                buffer.writeSSHWireUnsignedMPInt(magnitude: e ?? good.publicExponent)
            }
            buffer.writeSSHWireUnsignedMPInt(magnitude: n ?? good.modulus)
            buffer.writeBytes(trailing)
            return Array(buffer.readableBytesView)
        }
        XCTAssertNoThrow(try SSHRSAPublicKey(sshBlob: blob()))

        // 类型名：签名算法名不是公钥类型（RFC 8332 §3）。
        for type in ["rsa-sha2-512", "ssh-dss", "ssh-ed25519"] {
            XCTAssertThrowsError(try SSHRSAPublicKey(sshBlob: blob(type: type))) {
                XCTAssertEqual($0 as? SSHRSAError, .unexpectedKeyType, type)
            }
        }
        XCTAssertThrowsError(try SSHRSAPublicKey(sshBlob: blob(trailing: [0]))) {
            XCTAssertEqual($0 as? SSHWireFormatError, .trailingBytes(count: 1))
        }
        let full = blob()
        for cut in [1, 10, full.count - 12] {
            XCTAssertThrowsError(try SSHRSAPublicKey(sshBlob: full.dropLast(cut)))
        }
        // 负的 e、非最短的 e。
        XCTAssertThrowsError(try SSHRSAPublicKey(sshBlob: blob(rawE: [0x81, 0x00, 0x01]))) {
            XCTAssertEqual($0 as? SSHWireFormatError, .negativeMPInt)
        }
        XCTAssertThrowsError(try SSHRSAPublicKey(sshBlob: blob(rawE: [0x00, 0x01, 0x00, 0x01]))) {
            XCTAssertEqual($0 as? SSHWireFormatError, .nonMinimalMPInt)
        }
        // e = 1、e 偶数、n 偶数。
        for e in [[UInt8]([1]), [0x01, 0x00, 0x00], []] {
            XCTAssertThrowsError(try SSHRSAPublicKey(sshBlob: blob(e: e))) {
                XCTAssertEqual($0 as? SSHRSAError, .invalidPublicKey)
            }
        }
        var evenN = good.modulus
        evenN[evenN.count - 1] &= 0xFE
        XCTAssertThrowsError(try SSHRSAPublicKey(sshBlob: blob(n: evenN))) {
            XCTAssertEqual($0 as? SSHRSAError, .invalidPublicKey)
        }
        // 模数太短 / 太长。
        XCTAssertThrowsError(try SSHRSAPublicKey(sshBlob: blob(n: Array(good.modulus.prefix(64)) + [0x01]))) {
            XCTAssertEqual($0 as? SSHRSAError, .unsupportedModulusSize(bits: 65 * 8))
        }
        XCTAssertThrowsError(try SSHRSAPublicKey(modulus: [0x01] + [UInt8](repeating: 0xFF, count: 2048), publicExponent: [3])) {
            XCTAssertEqual($0 as? SSHRSAError, .unsupportedModulusSize(bits: 16385))
        }
        // 1023 位：刚好低于下限。
        XCTAssertThrowsError(try SSHRSAPublicKey(modulus: [0x7F] + [UInt8](repeating: 0xFF, count: 127), publicExponent: [3])) {
            XCTAssertEqual($0 as? SSHRSAError, .unsupportedModulusSize(bits: 1023))
        }
    }

    func testSignatureBlobs() throws {
        let signature = SSHRSASignature(algorithm: .rsaSHA2_256, bytes: [1, 2, 3, 4])
        XCTAssertEqual(signature.sshBlob.hexString, "0000000c7273612d736861322d3235360000000401020304")
        XCTAssertEqual(try SSHRSASignature(sshBlob: signature.sshBlob), signature)

        func blob(_ name: String, _ body: [UInt8], trailing: [UInt8] = []) -> [UInt8] {
            var buffer = ByteBuffer()
            buffer.writeSSHWireString(name)
            buffer.writeSSHWireString(body)
            buffer.writeBytes(trailing)
            return Array(buffer.readableBytesView)
        }
        XCTAssertThrowsError(try SSHRSASignature(sshBlob: blob("ssh-dss", [1]))) {
            XCTAssertEqual($0 as? SSHRSAError, .unknownSignatureAlgorithm)
        }
        XCTAssertThrowsError(try SSHRSASignature(sshBlob: blob("rsa-sha2-512", []))) {
            XCTAssertEqual($0 as? SSHRSAError, .invalidSignatureLength)
        }
        XCTAssertThrowsError(try SSHRSASignature(sshBlob: blob("rsa-sha2-512", [UInt8](repeating: 1, count: 2049)))) {
            XCTAssertEqual($0 as? SSHRSAError, .invalidSignatureLength)
        }
        XCTAssertThrowsError(try SSHRSASignature(sshBlob: blob("rsa-sha2-512", [1], trailing: [9])))
        XCTAssertThrowsError(try SSHRSASignature(sshBlob: Array(blob("rsa-sha2-512", [1, 2, 3]).dropLast())))
        XCTAssertEqual(SSHRSASignatureAlgorithm(name: "ssh-rsa"), .sshRSA)
        XCTAssertTrue(SSHRSASignatureAlgorithm.sshRSA.isLegacy)
        XCTAssertEqual(SSHRSASignatureAlgorithm.modern, [.rsaSHA2_512, .rsaSHA2_256])
    }

    func testGenerationAndWeakKeyPolicy() throws {
        XCTAssertThrowsError(try SSHRSAPrivateKey(generatingModulusBits: 1024)) {
            XCTAssertEqual($0 as? SSHRSAError, .unsupportedModulusSize(bits: 1024))
        }
        let key = try SSHRSAPrivateKey(generatingModulusBits: 2048)
        XCTAssertEqual(key.publicKey.modulusBitCount, 2048)
        XCTAssertFalse(key.publicKey.isWeak)
        XCTAssertEqual(key.publicKey.publicExponent, [0x01, 0x00, 0x01])
        let weak = try SSHRSAPrivateKey(components: self.components(RSAFixtures.keys[0]))
        XCTAssertTrue(weak.publicKey.isWeak)
        XCTAssertEqual(SSHRSAPublicKey.minimumModulusBits, 1024)
    }

    // MARK: 工具

    private struct SSHSIG {
        var publicKey: [UInt8]
        var signatureBlob: [UInt8]
        var signedData: [UInt8]
    }

    /// PROTOCOL.sshsig：`"SSHSIG" ‖ uint32 版本 ‖ string 公钥 ‖ string namespace ‖ string reserved ‖
    /// string hash_algorithm ‖ string 签名`；被签的是 `"SSHSIG" ‖ string namespace ‖ string reserved ‖
    /// string hash_algorithm ‖ string H(message)`。
    private static func parseSSHSIG(_ bytes: [UInt8]) throws -> SSHSIG {
        var buffer = ByteBuffer(bytes: bytes)
        XCTAssertEqual(buffer.readBytes(length: 6), Array("SSHSIG".utf8))
        XCTAssertEqual(try buffer.readSSHWireUInt32(), 1)
        let publicKey = Array(try buffer.readSSHWireString().readableBytesView)
        let namespace = Array(try buffer.readSSHWireString().readableBytesView)
        let reserved = Array(try buffer.readSSHWireString().readableBytesView)
        let hashAlgorithm = Array(try buffer.readSSHWireString().readableBytesView)
        let signatureBlob = Array(try buffer.readSSHWireString().readableBytesView)
        try buffer.requireFullyConsumed()
        XCTAssertEqual(String(decoding: hashAlgorithm, as: UTF8.self), "sha512")

        var signed = ByteBuffer()
        signed.writeBytes(Array("SSHSIG".utf8))
        signed.writeSSHWireString(namespace)
        signed.writeSSHWireString(reserved)
        signed.writeSSHWireString(hashAlgorithm)
        signed.writeSSHWireString(Array(SHA512.hash(data: [UInt8](hex: RSAFixtures.message))))
        return SSHSIG(publicKey: publicKey, signatureBlob: signatureBlob, signedData: Array(signed.readableBytesView))
    }

    private static func pemBody(_ pem: String) -> [UInt8] {
        let base64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Array(Data(base64Encoded: base64)!)
    }

    private static func secKey(_ pkcs1DER: [UInt8], private isPrivate: Bool) throws -> SecKey {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: isPrivate ? kSecAttrKeyClassPrivate : kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(pkcs1DER) as CFData, attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue()
        }
        return key
    }

    /// 上限是 BoringSSL 实际支持的 8192 位：8192 位的钥匙能签能验，16384 位（OpenSSH 允许）干净地拒绝。
    func testModulusLimitIsWhatBoringSSLSupports() throws {
        XCTAssertEqual(SSHRSAPublicKey.maximumModulusBits, 8192)
        let key = try SSHRSAPrivateKey(pemRepresentation: LargeRSAFixtures.modulus8192PEM)
        XCTAssertEqual(key.publicKey.modulusBitCount, 8192)
        let signature = try key.signature(for: Array("m".utf8), algorithm: .rsaSHA2_512)
        XCTAssertEqual(signature.bytes.count, 1024)
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Array("m".utf8), algorithm: .rsaSHA2_512))
        XCTAssertEqual(try SSHRSASignature(sshBlob: signature.sshBlob), signature)

        let line = LargeRSAFixtures.modulus16384OpenSSHPublicKey.split(separator: " ")
        let blob = try XCTUnwrap(Data(base64Encoded: String(line[1])))
        XCTAssertThrowsError(try SSHRSAPublicKey(sshBlob: Array(blob))) { error in
            XCTAssertEqual(error as? SSHRSAError, .unsupportedModulusSize(bits: 16384))
        }
        XCTAssertThrowsError(try SSHRSAPrivateKey(generatingModulusBits: 16384)) { error in
            XCTAssertEqual(error as? SSHRSAError, .unsupportedModulusSize(bits: 16384))
        }
    }
}
