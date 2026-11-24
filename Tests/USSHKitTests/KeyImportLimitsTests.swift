import Foundation
import XCTest
@_spi(uTermIntegration) @testable import USSHKit

/// 不可信的私钥文件不能拖住 CPU：RSA 分量在任何大数运算之前先卡尺寸与范围，线格式的字段有长度上限，
/// 素因子还原的代价有上限。
final class KeyImportLimitsTests: XCTestCase {

    private func assertMalformed(_ body: @autoclosure () throws -> Any?, within seconds: Double = 0.5,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let start = ContinuousClock.now
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .malformedKey(reason: ""), "\($0)", file: file, line: line)
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(Int(seconds * 1000)), "拒绝得太慢：\(elapsed)", file: file, line: line)
    }

    /// 奇数、最高位为 1 的 `bytes` 字节大数。
    private func odd(_ bytes: Int, fill: UInt8 = 0xA5) -> [UInt8] {
        var value = [UInt8](repeating: fill, count: bytes)
        value[0] |= 0x80
        value[bytes - 1] |= 1
        return value
    }

    private var realComponents: SSHRSAPrivateKeyComponents {
        get throws { try OpenSSHRSADecoder.decodeComponents(openSSHText: KeyImportFixtures.rsaOpenSSH) }
    }

    // MARK: 尺寸

    /// 几兆位的 n / d、素因子留空：以前 `recoverPrimes` 会在这里做模幂做到天荒地老。现在立刻拒绝。
    func testMultiMegabitModulusAndExponentAreRejectedBeforeArithmetic() throws {
        let huge = odd(512 * 1024)                       // 4 Mi 位
        assertMalformed(try RSAKeyMaterial.recoverPrimes(modulus: huge, publicExponent: [1, 0, 1], privateExponent: huge))
        let c = try realComponents
        assertMalformed(try RSAKeyMaterial.recoverPrimes(modulus: c.modulus, publicExponent: c.publicExponent,
                                                         privateExponent: huge))
        // 同样的东西装进容器：线格式的整数长度上限先拦下。
        let pem = OpenSSHTestContainers.rsa(n: huge, e: [1, 0, 1], d: huge, iqmp: [1], p: [], q: [])
        assertMalformed(try PrivateKeyImporter.resolve(pem: pem, passphrase: nil))
    }

    /// 比支持的上限（8192 位）大一点的模数：报「RSA 密钥长度 … 位不受支持」那一种结构损坏。
    func testModulusAboveTheSupportedRangeIsRejected() throws {
        let n = odd(1024 + 1)                            // 8200 位
        assertMalformed(try RSAKeyMaterial.recoverPrimes(modulus: n, publicExponent: [1, 0, 1], privateExponent: odd(1000)))
        let pem = OpenSSHTestContainers.rsa(n: n, e: [1, 0, 1], d: odd(1000), iqmp: [1], p: [], q: [])
        assertMalformed(try PrivateKeyImporter.resolve(pem: pem, passphrase: nil))
    }

    func testPublicExponentBounds() throws {
        let c = try realComponents
        for e in [[UInt8](), [0], [1], odd(5) /* 40 位 */, c.modulus /* e = n */] {
            assertMalformed(try RSAKeyMaterial.recoverPrimes(modulus: c.modulus, publicExponent: e,
                                                             privateExponent: c.privateExponent))
        }
    }

    func testPrivateExponentBounds() throws {
        let c = try realComponents
        var aboveN = c.modulus
        aboveN.insert(1, at: 0)
        for d in [[UInt8](), [0], [1], c.modulus, aboveN] {
            assertMalformed(try RSAKeyMaterial.recoverPrimes(modulus: c.modulus, publicExponent: c.publicExponent,
                                                             privateExponent: d))
        }
    }

    /// 给了素因子但对不上：p·q ≠ n、p 是 0 / 1、p 比 n 还长，都在构造之前拒绝。
    func testPrimesInconsistentWithTheModulus() throws {
        let c = try realComponents
        var wrong = c
        wrong.prime1[wrong.prime1.count - 1] ^= 0x02
        assertMalformed(try RSAKeyMaterial.makeKey(wrong))
        for p in [[UInt8]([0]), [1], odd(c.modulus.count + 8)] {
            var bad = c
            bad.prime1 = p
            assertMalformed(try RSAKeyMaterial.makeKey(bad))
        }
    }

    /// 线格式：声明的 string 超过上限就是结构损坏（不论后面有没有那么多字节）。
    func testWireStringAndIntegerLengthCaps() {
        var writer = SSHWireWriter()
        writer.writeUInt32(UInt32(SSHWireReader.maximumStringLength + 1))
        writer.writeRawBytes([UInt8](repeating: 0, count: SSHWireReader.maximumStringLength + 1))
        var reader = SSHWireReader(writer.bytes)
        XCTAssertThrowsError(try reader.readString())

        var mpint = SSHWireWriter()
        mpint.writeMPInt(odd(SSHWireReader.maximumMPIntLength + 1))
        var mpintReader = SSHWireReader(mpint.bytes)
        XCTAssertThrowsError(try mpintReader.readMPInt())

        var largest = SSHWireWriter()
        largest.writeMPInt(odd(SSHWireReader.maximumMPIntLength))
        var largestReader = SSHWireReader(largest.bytes)
        XCTAssertEqual(try largestReader.readMPInt().count, SSHWireReader.maximumMPIntLength)
    }

    // MARK: 合法的最大钥匙

    /// 8192 位、素因子留空的合法容器：还原得出来，而且有时间上限（Debug 构建；只做乘除与一次开方）。
    func testLegitimate8192BitKeyWithEmptyPrimesRecoversWithinBudget() throws {
        let pkcs8 = try PEMDocument.parse(LargeRSAFixture.modulus8192PEM).der
        let fields = try DERKeyDecoder.children(DERKeyDecoder.parse(pkcs8))
        let c = try RSAKeyMaterial.componentsFromPKCS1DER(DERKeyDecoder.primitiveBytes(fields[2]))
        let pem = OpenSSHTestContainers.rsa(n: c.modulus, e: c.publicExponent, d: c.privateExponent,
                                            iqmp: [1], p: [], q: [])
        let start = ContinuousClock.now
        guard case .rsa(let key) = try PrivateKeyImporter.resolve(pem: pem, passphrase: nil) else {
            return XCTFail("应为 .rsa")
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertEqual(key.publicKey.modulusBitCount, 8192)
        XCTAssertLessThan(elapsed, Self.recoveryBudget, "8192 位还原用了 \(elapsed)")
        print("8192 位素因子还原耗时 \(elapsed)")
    }

    /// 尺寸合法、内容是垃圾的 8192 位分量：枚举完 `maximumTotientCofactor` 个候选就放弃，同样有时间上限。
    func testValidSizedGarbageGivesUpWithinBudget() throws {
        let n = odd(1024, fill: 0xC3)
        var d = odd(1023, fill: 0x5A)
        d[0] = 0x7F
        let start = ContinuousClock.now
        XCTAssertNil(try RSAKeyMaterial.recoverPrimes(modulus: n, publicExponent: [1, 0, 1], privateExponent: d))
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, Self.recoveryBudget, "垃圾分量用了 \(elapsed)")
        print("8192 位垃圾分量放弃耗时 \(elapsed)")
        // 装进容器：「分量为空」那一种结构损坏。
        let pem = OpenSSHTestContainers.rsa(n: n, e: [1, 0, 1], d: d, iqmp: [1], p: [], q: [])
        XCTAssertThrowsError(try PrivateKeyImporter.resolve(pem: pem, passphrase: nil)) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .malformedKey(reason: ""))
        }
    }

    /// Debug 构建的上限（Release 快一个数量级）。迁移前的概率算法在这里要两三分钟。
    static let recoveryBudget: Duration = .seconds(5)
}
