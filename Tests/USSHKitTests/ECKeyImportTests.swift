import Crypto
import Foundation
import XCTest
@testable import USSHKit

/// SEC1 / PKCS#8 的 EC 私钥：命名曲线，或逐项等于 NIST 曲线的显式参数；别的显式参数不猜（以前按标量长度猜成 NIST
/// 曲线）；带了公钥就必须与私钥推出来的一致。
final class ECKeyImportTests: XCTestCase {
    /// `openssl ecparam -name secp256k1 -param_enc explicit -genkey -noout`：32 字节的标量，不是 P-256。
    static let secp256k1Explicit = """
-----BEGIN EC PRIVATE KEY-----
MIIBUQIBAQQgBCunt6Ze5f2YVqY/89J5BS9Nn2YJ2lTcttrkJGM+cUuggeMwgeAC
AQEwLAYHKoZIzj0BAQIhAP////////////////////////////////////7///wv
MEQEIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABCAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAABwRBBHm+Zn753LusVaBilc6HCwcCm/zbLc4o
2VnygVsW+BeYSDradyajxGVdpPv8DhEIqP0XtEimhVQZnEfQj/sQ1LgCIQD/////
///////////////+uq7c5q9IoDu/0l6M0DZBQQIBAaFEA0IABDqZaFrdxN2cOoJ2
5skRzMmEfnhIs/ONIAm2KMmyngwlGgQKy6MWOWfgfdCPIl63cKrK84lQmtLAq/vJ
p1gHkc0=
-----END EC PRIVATE KEY-----
"""

    /// 同一把，`openssl pkcs8 -topk8 -nocrypt`：曲线参数在外层的 AlgorithmIdentifier 里。
    static let secp256k1ExplicitPKCS8 = """
-----BEGIN PRIVATE KEY-----
MIIBYQIBADCB7AYHKoZIzj0CATCB4AIBATAsBgcqhkjOPQEBAiEA////////////
/////////////////////////v///C8wRAQgAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAEIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHBEEE
eb5mfvncu6xVoGKVzocLBwKb/NstzijZWfKBWxb4F5hIOtp3JqPEZV2k+/wOEQio
/Re0SKaFVBmcR9CP+xDUuAIhAP////////////////////66rtzmr0igO7/SXozQ
NkFBAgEBBG0wawIBAQQgBCunt6Ze5f2YVqY/89J5BS9Nn2YJ2lTcttrkJGM+cUuh
RANCAAQ6mWha3cTdnDqCdubJEczJhH54SLPzjSAJtijJsp4MJRoECsujFjln4H3Q
jyJet3CqyvOJUJrSwKv7yadYB5HN
-----END PRIVATE KEY-----
"""

    /// 真的 P-256，只是曲线写成显式参数：逐项核对是 P-256，照常导入。
    static let p256Explicit = """
-----BEGIN EC PRIVATE KEY-----
MIIBaAIBAQQgKWCQ9vq5O4PWR/yQQuPLr7OtOAyw9QSZkv+Vlh5wIbCggfowgfcC
AQEwLAYHKoZIzj0BAQIhAP////8AAAABAAAAAAAAAAAAAAAA////////////////
MFsEIP////8AAAABAAAAAAAAAAAAAAAA///////////////8BCBaxjXYqjqT57Pr
vVV2mIa8ZR0GsMxTsPY7zjw+J9JgSwMVAMSdNgiG5wSTamZ44ROdJreBn36QBEEE
axfR8uEsQkf4vOblY6RA8ncDfYEt6zOg9KE5RdiYwpZP40Li/hp/m47n60p8D54W
K84zV2sxXs7LtkBoN79R9QIhAP////8AAAAA//////////+85vqtpxeehPO5ysL8
YyVRAgEBoUQDQgAE4Jn1Cm9ZnDi+50GxBlKaICMkoW6ah3ONrKM91rpqmlB5EPtr
Qo51895sIp2ChCCr+dCYfje/C88SZqYt1zK0LQ==
-----END EC PRIVATE KEY-----
"""

    private func importing(_ pem: String) throws -> ParsedPrivateKey {
        try PrivateKeyImporter.resolve(pem: pem, passphrase: nil)
    }

    private func assertUnsupported(_ pem: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try importing(pem), file: file, line: line) { error in
            guard case PrivateKeyImportError.unsupportedFormat = error else {
                return XCTFail("\(error)", file: file, line: line)
            }
        }
    }

    private func assertMalformed(_ pem: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try importing(pem), file: file, line: line) { error in
            guard case PrivateKeyImportError.malformedKey = error else {
                return XCTFail("\(error)", file: file, line: line)
            }
        }
    }

    /// secp256k1 的标量也是 32 字节：以前被当成 P-256 的钥匙。现在按不支持拒绝（SEC1 与 PKCS#8 两种包装）。
    func testNonNISTExplicitCurveIsRejectedNotGuessed() {
        assertUnsupported(Self.secp256k1Explicit)
        assertUnsupported(Self.secp256k1ExplicitPKCS8)
    }

    func testExplicitNISTParametersImportAsThatCurve() throws {
        guard case .p256 = try importing(Self.p256Explicit) else { return XCTFail("not P-256") }
    }

    /// 显式参数里改掉一个字节（b 不再是 P-256 的）：不是 NIST 曲线，拒绝。
    func testTamperedExplicitParametersAreRejected() throws {
        let body = Self.p256Explicit.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        var der = Array(Data(base64Encoded: body)!)
        let b: [UInt8] = [0x5A, 0xC6, 0x35, 0xD8, 0xAA, 0x3A, 0x93, 0xE7]
        let at = try XCTUnwrap((0...(der.count - b.count)).first { Array(der[$0..<$0 + b.count]) == b })
        der[at + 3] ^= 0x01
        let base64 = Data(der).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        assertUnsupported("-----BEGIN EC PRIVATE KEY-----\n\(base64)\n-----END EC PRIVATE KEY-----\n")
    }

    // MARK: - 手拼的 SEC1

    private func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var length: [UInt8]
        if content.count < 0x80 {
            length = [UInt8(content.count)]
        } else {
            var n = content.count
            var bytes: [UInt8] = []
            while n > 0 { bytes.insert(UInt8(n & 0xFF), at: 0); n >>= 8 }
            length = [0x80 | UInt8(bytes.count)] + bytes
        }
        return [tag] + length + content
    }

    private static let p256OID: [UInt8] = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]

    /// SEQUENCE { 1, d, [0] { OID p256 }?, [1] { BIT STRING 00‖point }? }
    private func sec1(scalar: [UInt8], named: Bool, publicPoint: [UInt8]?) -> String {
        var body = der(0x02, [0x01]) + der(0x04, scalar)
        if named { body += der(0xA0, Self.p256OID) }
        if let publicPoint { body += der(0xA1, der(0x03, [0x00] + publicPoint)) }
        let bytes = der(0x30, body)
        let base64 = Data(bytes).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN EC PRIVATE KEY-----\n\(base64)\n-----END EC PRIVATE KEY-----\n"
    }

    /// 带的公钥是另一把钥匙的：拒绝（不然显示的指纹与认证用的钥匙不是同一把）。
    func testMismatchedEmbeddedPublicKeyIsRejected() {
        let key = P256.Signing.PrivateKey()
        let other = P256.Signing.PrivateKey()
        assertMalformed(sec1(scalar: Array(key.rawRepresentation), named: true,
                             publicPoint: Array(other.publicKey.x963Representation)))
        assertMalformed(sec1(scalar: Array(key.rawRepresentation), named: true,
                             publicPoint: Array(other.publicKey.compressedRepresentation)))
    }

    /// 带的公钥一致（非压缩、压缩两种写法）：照常导入，就是那把钥匙。
    func testMatchingEmbeddedPublicKeyImports() throws {
        let key = P256.Signing.PrivateKey()
        for point in [Array(key.publicKey.x963Representation), Array(key.publicKey.compressedRepresentation)] {
            guard case .p256(let parsed) = try importing(sec1(scalar: Array(key.rawRepresentation), named: true,
                                                              publicPoint: point)) else { return XCTFail("not P-256") }
            XCTAssertEqual(parsed.rawRepresentation, key.rawRepresentation)
        }
    }

    /// 没有曲线信息：只在带了一致的公钥时才按标量长度认成 P-256；什么都没带就拒绝。
    func testMissingCurveNeedsAMatchingPublicKey() throws {
        let key = P256.Signing.PrivateKey()
        guard case .p256 = try importing(sec1(scalar: Array(key.rawRepresentation), named: false,
                                              publicPoint: Array(key.publicKey.x963Representation))) else {
            return XCTFail("not P-256")
        }
        assertMalformed(sec1(scalar: Array(key.rawRepresentation), named: false, publicPoint: nil))
        assertMalformed(sec1(scalar: Array(key.rawRepresentation), named: false,
                             publicPoint: Array(P256.Signing.PrivateKey().publicKey.x963Representation)))
    }

    /// 命名曲线、不带公钥（最常见的 PKCS#8 写法也是这样）：照常导入。
    func testNamedCurveWithoutPublicKeyImports() throws {
        let key = P256.Signing.PrivateKey()
        guard case .p256(let parsed) = try importing(sec1(scalar: Array(key.rawRepresentation), named: true,
                                                          publicPoint: nil)) else { return XCTFail("not P-256") }
        XCTAssertEqual(parsed.rawRepresentation, key.rawRepresentation)
        guard case .p256 = try importing(key.pemRepresentation) else { return XCTFail("PKCS#8 P-256") }
    }
}
