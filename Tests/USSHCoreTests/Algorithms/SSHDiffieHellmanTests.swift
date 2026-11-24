import BigInt
import NIOCore
import XCTest

@testable import USSHCore

final class SSHDiffieHellmanTests: XCTestCase {
    private var fixtureInputs: SSHExchangeHashInputs {
        SSHExchangeHashInputs(
            clientVersion: [UInt8](hex: DHFixtures.clientVersion),
            serverVersion: [UInt8](hex: DHFixtures.serverVersion),
            clientKeyExchangeInit: [UInt8](hex: DHFixtures.clientKexInit),
            serverKeyExchangeInit: [UInt8](hex: DHFixtures.serverKexInit),
            serverHostKey: [UInt8](hex: DHFixtures.serverHostKey)
        )
    }

    // MARK: 群参数

    /// RFC 3526 给的定义：p = 2^n − 2^(n−64) − 1 + 2^64 × (⌊2^(n−130) π⌋ + c)。
    /// 用 Machin 公式现算 π，与源码里抄的十六进制常量对照（常量本身取自 OpenSSL 的 modp_2048 / modp_4096）。
    func testGroupPrimesMatchRFC3526Definition() {
        let cases: [(SSHDiffieHellmanGroup, Int, Int, BigUInt)] = [
            (.group14, 2048, 1918, 124476),
            (.group16, 4096, 3966, 240904),
        ]
        for (group, bits, piBits, offset) in cases {
            let one = BigUInt(1)
            let expected = (one << bits) - (one << (bits - 64)) - 1 + (one << 64) * (Self.floorPiTimesPowerOfTwo(piBits) + offset)
            XCTAssertEqual(group.prime, expected, group.name)
            XCTAssertEqual(group.primeBitCount, bits)
            XCTAssertEqual(group.generator, 2)
            XCTAssertEqual(Array(group.primeBytes.prefix(8)), [UInt8](repeating: 0xFF, count: 8))
            XCTAssertEqual(Array(group.primeBytes.suffix(8)), [UInt8](repeating: 0xFF, count: 8))
        }
    }

    /// ⌊2^bits × π⌋，π = 16 arctan(1/5) − 4 arctan(1/239)，定点运算多留 64 位保护位。
    private static func floorPiTimesPowerOfTwo(_ bits: Int) -> BigUInt {
        let guardBits = 64
        let one = BigUInt(1) << (bits + guardBits)
        func arctanInverse(_ x: BigUInt) -> BigInt {
            var sum = BigInt(0)
            var term = one / x
            let xSquared = x * x
            var n = BigUInt(1)
            var positive = true
            while term > 0 {
                let piece = BigInt(term / n)
                sum += positive ? piece : -piece
                term /= xSquared
                n += 2
                positive.toggle()
            }
            return sum
        }
        let pi = 16 * arctanInverse(5) - 4 * arctanInverse(239)
        return pi.magnitude >> guardBits
    }

    // MARK: 已知答案（python3 独立实现，见 generate-fixtures.sh）

    func testFrozenVectorsFromIndependentImplementation() throws {
        for vector in DHFixtures.vectors {
            let algorithm = try XCTUnwrap(SSHDiffieHellmanAlgorithm(name: vector.algorithm))
            var client = try SSHDiffieHellmanKeyExchange(
                algorithm: algorithm,
                role: .client,
                privateExponent: [UInt8](hex: vector.clientExponent)
            )
            var server = try SSHDiffieHellmanKeyExchange(
                algorithm: algorithm,
                role: .server,
                privateExponent: [UInt8](hex: vector.serverExponent)
            )
            XCTAssertEqual(client.localPublicValue, [UInt8](hex: vector.e), vector.algorithm)
            XCTAssertEqual(server.localPublicValue, [UInt8](hex: vector.f), vector.algorithm)

            let clientResult = try client.complete(peerPublicValue: server.localPublicValue, inputs: self.fixtureInputs)
            let serverResult = try server.complete(peerPublicValue: client.localPublicValue, inputs: self.fixtureInputs)
            for result in [clientResult, serverResult] {
                XCTAssertEqual(result.sharedSecretMPInt, [UInt8](hex: vector.sharedSecretMPInt), vector.algorithm)
                XCTAssertEqual(result.exchangeHash, [UInt8](hex: vector.exchangeHash), vector.algorithm)
                XCTAssertEqual(result.clientPublicValue, [UInt8](hex: vector.e))
                XCTAssertEqual(result.serverPublicValue, [UInt8](hex: vector.f))
                XCTAssertEqual(result.exchangeHash.count, algorithm.hashFunction.digestByteCount)
                XCTAssertEqual(
                    result.deriveKey(letter: UInt8(ascii: "C"), sessionID: result.exchangeHash, length: 64),
                    [UInt8](hex: vector.derivedKeyC64),
                    vector.algorithm
                )
            }
        }
    }

    // MARK: 双方协商

    func testClientAndServerAgreeForEveryAlgorithm() throws {
        for algorithm in SSHDiffieHellmanAlgorithm.allCases {
            var client = SSHDiffieHellmanKeyExchange(algorithm: algorithm, role: .client)
            var server = SSHDiffieHellmanKeyExchange(algorithm: algorithm, role: .server)
            XCTAssertNotEqual(client.localPublicValue, server.localPublicValue)
            let a = try client.complete(peerPublicValue: server.localPublicValue, inputs: self.fixtureInputs)
            let b = try server.complete(peerPublicValue: client.localPublicValue, inputs: self.fixtureInputs)
            XCTAssertEqual(a.sharedSecretMPInt, b.sharedSecretMPInt, algorithm.name)
            XCTAssertEqual(a.exchangeHash, b.exchangeHash, algorithm.name)
            XCTAssertEqual(a.clientPublicValue, client.localPublicValue)
            XCTAssertEqual(b.serverPublicValue, server.localPublicValue)
            // K 的 mpint 编码：长度前缀 + 最短内容，能被严格读法读回。
            var k = ByteBuffer(bytes: a.sharedSecretMPInt)
            let magnitude = try k.readSSHWireUnsignedMPInt()
            XCTAssertEqual(k.readableBytes, 0)
            XCTAssertLessThan(BigUInt(sshMagnitude: magnitude), algorithm.group.prime)

            // 任何一项输入不同，H 都不同。
            var changed = self.fixtureInputs
            changed.serverHostKey[changed.serverHostKey.count - 1] ^= 1
            var other = SSHDiffieHellmanKeyExchange(algorithm: algorithm, role: .client)
            let c = try other.complete(peerPublicValue: server.localPublicValue, inputs: changed)
            XCTAssertNotEqual(c.exchangeHash, a.exchangeHash)
        }
    }

    func testEphemeralExponentIsFreshAndSingleUse() throws {
        let algorithm = SSHDiffieHellmanAlgorithm.group14SHA256
        var seen = Set<[UInt8]>()
        for _ in 0..<5 {
            XCTAssertTrue(seen.insert(SSHDiffieHellmanKeyExchange(algorithm: algorithm, role: .client).localPublicValue).inserted)
        }
        var client = SSHDiffieHellmanKeyExchange(algorithm: algorithm, role: .client)
        let server = SSHDiffieHellmanKeyExchange(algorithm: algorithm, role: .server)
        _ = try client.complete(peerPublicValue: server.localPublicValue, inputs: self.fixtureInputs)
        XCTAssertThrowsError(try client.complete(peerPublicValue: server.localPublicValue, inputs: self.fixtureInputs)) {
            XCTAssertEqual($0 as? SSHDiffieHellmanError, .alreadyCompleted)
        }
    }

    // MARK: 对端公开值的校验

    func testRejectsOutOfRangePeerValues() throws {
        for algorithm in [SSHDiffieHellmanAlgorithm.group14SHA256, .group16SHA512] {
            let p = algorithm.group.prime
            let bad: [BigUInt] = [0, 1, p - 1, p, p + 1, p * 2, BigUInt(1) << (p.bitWidth + 8)]
            var client = SSHDiffieHellmanKeyExchange(algorithm: algorithm, role: .client)
            for value in bad {
                XCTAssertThrowsError(try client.complete(peerPublicValue: value.sshMagnitudeBytes, inputs: self.fixtureInputs)) {
                    XCTAssertEqual($0 as? SSHDiffieHellmanError, .invalidPeerPublicValue, "\(value)")
                }
            }
            // 校验失败不消耗私钥；合法的边界值 2 与 p − 2 可以通过。
            XCTAssertNoThrow(try client.complete(peerPublicValue: [2], inputs: self.fixtureInputs))
            var again = SSHDiffieHellmanKeyExchange(algorithm: algorithm, role: .server)
            XCTAssertNoThrow(try again.complete(peerPublicValue: (p - 2).sshMagnitudeBytes, inputs: self.fixtureInputs))
            // 带前导零的合法值也能接受。
            var padded = SSHDiffieHellmanKeyExchange(algorithm: algorithm, role: .client)
            XCTAssertNoThrow(try padded.complete(peerPublicValue: [0, 0, 5], inputs: self.fixtureInputs))
        }
        // 线上的负数 mpint 在读的时候就被拒绝。
        var negative = ByteBuffer()
        negative.writeSSHWireString([0x80, 0x01])
        XCTAssertThrowsError(try negative.readSSHWireUnsignedMPInt())
    }

    func testRejectsInvalidPrivateExponent() {
        let q = (SSHDiffieHellmanGroup.group14.prime - 1) >> 1
        for exponent in [BigUInt(0), 1, q, q + 1] {
            XCTAssertThrowsError(
                try SSHDiffieHellmanKeyExchange(algorithm: .group14SHA256, role: .client, privateExponent: exponent.sshMagnitudeBytes)
            ) {
                XCTAssertEqual($0 as? SSHDiffieHellmanError, .invalidPrivateExponent)
            }
        }
    }

    // MARK: 交换哈希的编码细节

    /// e 最高位为 1 时 mpint 要补 0x00；K 的编码直接拼进去（已含长度）。对照手拼的转录。
    func testExchangeHashEncodingWithHighBitValues() {
        let inputs = self.fixtureInputs
        let e: [UInt8] = [0x80] + [UInt8](repeating: 0x11, count: 31)
        let f: [UInt8] = [0x7F, 0x22]
        let k: [UInt8] = [0, 0, 0, 2, 0x00, 0x90]
        var manual: [UInt8] = []
        func string(_ bytes: [UInt8]) {
            manual += withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { Array($0) } + bytes
        }
        string(inputs.clientVersion)
        string(inputs.serverVersion)
        string(inputs.clientKeyExchangeInit)
        string(inputs.serverKeyExchangeInit)
        string(inputs.serverHostKey)
        string([0x00] + e)
        string(f)
        manual += k
        for hash in [SSHExchangeHashFunction.sha1, .sha256, .sha512] {
            XCTAssertEqual(
                SSHDiffieHellmanKeyExchange.exchangeHash(hash: hash, inputs: inputs, e: e, f: f, sharedSecretMPInt: k),
                hash.hash(manual)
            )
        }
    }

    func testKeyDerivationExtension() {
        let k: [UInt8] = [0, 0, 0, 1, 0x42]
        let h = [UInt8](repeating: 7, count: 32)
        let short = SSHKeyDerivation.derive(hash: .sha256, sharedSecretMPInt: k, exchangeHash: h, letter: 0x41, sessionID: h, length: 16)
        let long = SSHKeyDerivation.derive(hash: .sha256, sharedSecretMPInt: k, exchangeHash: h, letter: 0x41, sessionID: h, length: 80)
        XCTAssertEqual(short.count, 16)
        XCTAssertEqual(long.count, 80)
        XCTAssertEqual(Array(long.prefix(16)), short)
        let k1 = SSHExchangeHashFunction.sha256.hash(k + h + [0x41] + h)
        let k2 = SSHExchangeHashFunction.sha256.hash(k + h + k1)
        let k3 = SSHExchangeHashFunction.sha256.hash(k + h + k1 + k2)
        XCTAssertEqual(long, Array((k1 + k2 + k3).prefix(80)))
    }

    func testAlgorithmCatalogue() {
        XCTAssertEqual(SSHDiffieHellmanAlgorithm.modern.map(\.name), ["diffie-hellman-group16-sha512", "diffie-hellman-group14-sha256"])
        XCTAssertEqual(SSHDiffieHellmanAlgorithm.legacy.map(\.name), ["diffie-hellman-group14-sha1"])
        XCTAssertTrue(SSHDiffieHellmanAlgorithm.group14SHA1.isLegacy)
        XCTAssertEqual(SSHDiffieHellmanAlgorithm.group14SHA1.group, .group14)
        XCTAssertNil(SSHDiffieHellmanAlgorithm(name: "diffie-hellman-group1-sha1"))
    }
}
