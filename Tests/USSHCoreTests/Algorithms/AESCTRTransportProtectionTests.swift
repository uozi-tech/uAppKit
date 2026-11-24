import Crypto
import NIOCore
import NIOSSH
import XCTest
import _CryptoExtras

@testable import USSHCore

final class AESCTRTransportProtectionTests: XCTestCase {
    // MARK: 已知答案

    /// NIST SP 800-38A F.5.1 / F.5.3 / F.5.5（CTR-AES128/192/256.Encrypt）。走被测代码同一条路：
    /// `SSHCTRCounter` 给出计数块，`AES._CTR` 生成密钥流，四块分两次加密，验证计数器在调用之间正确延续。
    func testNISTSP80038AKnownAnswers() throws {
        let plaintext = [UInt8](hex: """
            6bc1bee22e409f96e93d7e117393172a ae2d8a571e03ac9c9eb76fac45af8e51
            30c81c46a35ce411e5fbc1191a0a52ef f69f2445df4f9b17ad2b417be66c3710
            """)
        let counter = [UInt8](hex: "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let vectors: [(key: String, ciphertext: String)] = [
            (
                "2b7e151628aed2a6abf7158809cf4f3c",
                """
                874d6191b620e3261bef6864990db6ce 9806f66b7970fdff8617187bb9fffdff
                5ae4df3edbd5d35e5b4f09020db03eab 1e031dda2fbe03d1792170a0f3009cee
                """
            ),
            (
                "8e73b0f7da0e6452c810f32b809079e562f8ead2522c6b7b",
                """
                1abc932417521ca24f2b0459fe7e6e0b 090339ec0aa6faefd5ccc2c6f4ce8e94
                1e36b26bd1ebc670d1bd1d665620abf7 4f78a7f6d29809585a97daec58c6b050
                """
            ),
            (
                "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4",
                """
                601ec313775789a5b7a7f504bbf3d228 f443e3ca4d62b59aca84e990cacaf5c5
                2b0930daa23de94ce87017ba2d84988d dfc9c58db67aada613c2dd08457941a6
                """
            ),
        ]
        for vector in vectors {
            let key = SymmetricKey(data: [UInt8](hex: vector.key))
            var state = try SSHCTRCounter(iv: counter)
            var output: [UInt8] = []
            for chunk in [plaintext[0..<16], plaintext[16..<64]] {
                output += try AES._CTR.encrypt(chunk, using: key, nonce: AES._CTR.Nonce(nonceBytes: state.block))
                state.advance(byBlocks: UInt64(chunk.count / 16))
            }
            XCTAssertEqual(output.hexString, [UInt8](hex: vector.ciphertext).hexString, "key \(vector.key)")
            // 参考实现（逐块 AES）也得出同样的结果，说明参考实现本身可信。
            XCTAssertEqual(
                try ReferenceCTR.keystreamXOR(plaintext, key: [UInt8](hex: vector.key), counter: counter),
                [UInt8](hex: vector.ciphertext)
            )
        }
    }

    /// RFC 4231 测试用例 1、2（HMAC-SHA-256 / 512）与 RFC 2202 测试用例 1（HMAC-SHA-1）。
    func testHMACKnownAnswers() {
        let key1 = SymmetricKey(data: [UInt8](repeating: 0x0b, count: 20))
        let data1 = Array("Hi There".utf8)
        XCTAssertEqual(
            Array(HMAC<SHA256>.authenticationCode(for: data1, using: key1)).hexString,
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
        )
        XCTAssertEqual(
            Array(HMAC<SHA512>.authenticationCode(for: data1, using: key1)).hexString,
            "87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cde"
                + "daa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854"
        )
        XCTAssertEqual(
            Array(HMAC<Insecure.SHA1>.authenticationCode(for: data1, using: key1)).hexString,
            "b617318655057264e28bc0b6fb378c8ef146be00"
        )
        let key2 = SymmetricKey(data: Array("Jefe".utf8))
        let data2 = Array("what do ya want for nothing?".utf8)
        XCTAssertEqual(
            Array(HMAC<SHA256>.authenticationCode(for: data2, using: key2)).hexString,
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        )
        XCTAssertEqual(
            Array(HMAC<SHA512>.authenticationCode(for: data2, using: key2)).hexString,
            "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea250554"
                + "9758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737"
        )
    }

    // MARK: 元数据

    func testNamesAndKeySizes() {
        let expected: [String: (key: Int, mac: Int, macBytes: Int)] = [
            "aes128-ctr|hmac-sha2-256": (16, 32, 32),
            "aes256-ctr|hmac-sha2-512-etm@openssh.com": (32, 64, 64),
            "aes192-ctr|hmac-sha1": (24, 20, 20),
        ]
        var seen = Set<String>()
        for scheme in SchemeUnderTest.all {
            let id = "\(scheme.cipherName)|\(scheme.macName)"
            XCTAssertTrue(seen.insert(id).inserted, "重复的方案 \(id)")
            XCTAssertEqual(scheme.type.cipherBlockSize, 16)
            XCTAssertEqual(scheme.type.keySizes.ivSize, 16)
            if let sizes = expected[id] {
                XCTAssertEqual(scheme.type.keySizes.encryptionKeySize, sizes.key)
                XCTAssertEqual(scheme.type.keySizes.macKeySize, sizes.mac)
                let protection = try! scheme.type.init(initialKeys: TestKeys.Material.random(scheme.type.keySizes).client)
                XCTAssertEqual(protection.macBytes, sizes.macBytes)
                XCTAssertEqual(protection.lengthEncrypted, !scheme.encryptThenMAC)
            }
        }
        XCTAssertEqual(seen.count, 18)
        // 默认目录里没有 SHA-1，也没有需要密钥扩展的 SHA-512。
        for scheme in SSHTransportProtections.modern {
            XCTAssertEqual(scheme.macName.map { $0.contains("sha2-256") }, true)
        }
    }

    func testRejectsWrongKeyAndIVSizes() {
        let type = SSHAESCTRTransportProtection<SSHAES256CTR, SSHHMACSHA256>.self
        var material = TestKeys.Material.random(type.keySizes)
        material.encC2S = TestKeys.random(16)
        XCTAssertThrowsError(try type.init(initialKeys: material.client)) {
            XCTAssertEqual($0 as? SSHTransportProtectionError, .invalidKeySize)
        }
        material = TestKeys.Material.random(type.keySizes)
        material.macS2C = TestKeys.random(20)
        XCTAssertThrowsError(try type.init(initialKeys: material.client)) {
            XCTAssertEqual($0 as? SSHTransportProtectionError, .invalidKeySize)
        }
        material = TestKeys.Material.random(type.keySizes)
        material.ivC2S = TestKeys.random(12)
        XCTAssertThrowsError(try type.init(initialKeys: material.client)) {
            XCTAssertEqual($0 as? SSHTransportProtectionError, .invalidIVSize)
        }
        // NIOSSH 截短的 HMAC-SHA2-512 密钥（32 字节）必须被拒绝，而不是悄悄用错密钥。
        let sha512 = SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA512ETM>.self
        material = TestKeys.Material.random(sha512.keySizes)
        material.macC2S = TestKeys.random(32)
        material.macS2C = TestKeys.random(32)
        XCTAssertThrowsError(try sha512.init(initialKeys: material.client)) {
            XCTAssertEqual($0 as? SSHTransportProtectionError, .invalidKeySize)
        }
        let protection = try! type.init(initialKeys: TestKeys.Material.random(type.keySizes).client)
        XCTAssertThrowsError(try protection.updateKeys(TestKeys.Material.random(sha512.keySizes).client))
    }

    // MARK: 与独立参考实现逐字节比对

    /// 每个方案、多种包长、连续多个包（计数器跨包延续）、序号从 2^32−3 开始跨过回绕：
    /// 被测实现加密出的线上字节必须与 CommonCrypto 参考实现完全一致，参考实现加密的字节被测实现也要解得开。
    func testMatchesCommonCryptoReferenceAcrossPacketsAndSequenceWrap() throws {
        let payloadSizes = [0, 1, 3, 7, 10, 11, 12, 15, 16, 17, 31, 32, 33, 100, 255, 256, 1000, 4096, 32768, 35000]
        for scheme in SchemeUnderTest.all {
            let material = TestKeys.Material.random(scheme.type.keySizes)
            let client = try scheme.type.init(initialKeys: material.client)
            let server = try scheme.type.init(initialKeys: material.server)
            let reference = ReferenceSSHEncrypter(
                key: material.encC2S,
                iv: material.ivC2S,
                macKey: material.macC2S,
                macName: scheme.macName
            )
            var sequence = UInt32.max - 2
            for size in payloadSizes {
                let payload = TestKeys.random(size)
                let plaintext = TestPacket.plaintext(
                    payload: payload,
                    lengthEncrypted: client.lengthEncrypted,
                    blockSize: 16
                )
                let expectedWire = reference.seal(Array(plaintext.readableBytesView), sequenceNumber: sequence)

                var wire = plaintext
                try client.encryptPacket(&wire, sequenceNumber: sequence)
                XCTAssertEqual(Array(wire.readableBytesView), expectedWire, "\(scheme.label) size \(size)")
                XCTAssertEqual(wire.readableBytes, plaintext.readableBytes + client.macBytes)

                XCTAssertEqual(
                    TestPacket.parse(wire, protection: server, sequenceNumber: sequence),
                    .payload(payload),
                    "\(scheme.label) size \(size)"
                )
                sequence &+= 1
            }
            XCTAssertLessThan(sequence, 100, "序号应已回绕")
        }
    }

    /// 双向、多次换钥：换钥后两端都从新 IV 重新计数，旧密钥加密的包换钥后解不开。
    func testRoundTripBothDirectionsAcrossKeyUpdates() throws {
        for scheme in SchemeUnderTest.all {
            var material = TestKeys.Material.random(scheme.type.keySizes)
            let client = try scheme.type.init(initialKeys: material.client)
            let server = try scheme.type.init(initialKeys: material.server)
            var clientSeq: UInt32 = 0
            var serverSeq: UInt32 = 0
            for round in 0..<3 {
                for size in stride(from: 0, through: 300, by: 23) {
                    let up = TestKeys.random(size)
                    var wire = TestPacket.plaintext(payload: up, lengthEncrypted: client.lengthEncrypted, blockSize: 16)
                    try client.encryptPacket(&wire, sequenceNumber: clientSeq)
                    XCTAssertEqual(TestPacket.parse(wire, protection: server, sequenceNumber: clientSeq), .payload(up))
                    clientSeq &+= 1

                    let down = TestKeys.random(size + 1)
                    var reply = TestPacket.plaintext(
                        payload: down,
                        lengthEncrypted: server.lengthEncrypted,
                        blockSize: 16,
                        extraPaddingBlocks: size % 3
                    )
                    try server.encryptPacket(&reply, sequenceNumber: serverSeq)
                    XCTAssertEqual(TestPacket.parse(reply, protection: client, sequenceNumber: serverSeq), .payload(down))
                    serverSeq &+= 1
                }
                // 换钥前留一个旧密钥加密的包。
                var stale = TestPacket.plaintext(payload: [1, 2, 3], lengthEncrypted: client.lengthEncrypted, blockSize: 16)
                try client.encryptPacket(&stale, sequenceNumber: clientSeq)

                material = TestKeys.Material.random(scheme.type.keySizes)
                try client.updateKeys(material.client)
                try server.updateKeys(material.server)

                // 新密钥下旧包要么抛错，要么被当成更长的包等数据（长度字段被新密钥流解乱），绝不交出 payload。
                let probe = try scheme.type.init(initialKeys: material.server)
                XCTAssertFalse(
                    TestPacket.parse(stale, protection: probe, sequenceNumber: clientSeq).isPayload,
                    "\(scheme.label) 换钥 \(round) 后旧包不应被接受"
                )
            }
        }
    }

    // MARK: 篡改

    func testTamperedBodyOrMACIsRejected() throws {
        for scheme in SchemeUnderTest.all {
            let material = TestKeys.Material.random(scheme.type.keySizes)
            let client = try scheme.type.init(initialKeys: material.client)
            var wire = TestPacket.plaintext(payload: TestKeys.random(70), lengthEncrypted: client.lengthEncrypted, blockSize: 16)
            try client.encryptPacket(&wire, sequenceNumber: 7)
            let bytes = Array(wire.readableBytesView)

            // 包体（长度字段之后、MAC 之前）与 MAC 的若干位置各翻一位。
            let macStart = bytes.count - client.macBytes
            let positions = [4, 5, 16, 17, macStart - 1, macStart, macStart + 3, bytes.count - 1]
            for position in positions {
                for bit in [0, 3, 7] {
                    var tampered = bytes
                    tampered[position] ^= UInt8(1 << bit)
                    let server = try scheme.type.init(initialKeys: material.server)
                    let outcome = TestPacket.parse(ByteBuffer(bytes: tampered), protection: server, sequenceNumber: 7)
                    guard case .threw = outcome else {
                        XCTFail("\(scheme.label) 位置 \(position) 位 \(bit)：\(outcome)")
                        continue
                    }
                }
            }
            // 序号不对也必须失败（MAC 覆盖序号）。
            let server = try scheme.type.init(initialKeys: material.server)
            guard case .threw = TestPacket.parse(wire, protection: server, sequenceNumber: 8) else {
                XCTFail("\(scheme.label) 序号错位应失败")
                continue
            }
        }
    }

    /// 改长度字段：变短（仍是块的整数倍）必须抛错；变长时解析器只会等更多数据，绝不交出 payload；
    /// 改成不是块的整数倍立即抛错。
    func testTamperedLengthIsNeverAccepted() throws {
        for scheme in SchemeUnderTest.all {
            let material = TestKeys.Material.random(scheme.type.keySizes)
            let client = try scheme.type.init(initialKeys: material.client)
            // 选一个 packet_length 的 0x10 位为 1 的包长，翻这一位就得到 −16。
            var payloadSize = 40
            var wire: ByteBuffer
            repeat {
                payloadSize += 1
                wire = TestPacket.plaintext(payload: TestKeys.random(payloadSize), lengthEncrypted: client.lengthEncrypted, blockSize: 16)
            } while wire.getInteger(at: 0, as: UInt32.self)! & 0x10 == 0
            try client.encryptPacket(&wire, sequenceNumber: 1)
            let bytes = Array(wire.readableBytesView)

            for (mask, expectation) in [(UInt8(0x10), "shorter"), (UInt8(0x20), "either"), (UInt8(0x01), "misaligned"), (UInt8(0x80), "either")] {
                var tampered = bytes
                tampered[3] ^= mask
                let server = try scheme.type.init(initialKeys: material.server)
                let outcome = TestPacket.parse(ByteBuffer(bytes: tampered), protection: server, sequenceNumber: 1)
                switch (outcome, expectation) {
                case (.threw, _):
                    break
                case (.needMoreData, "either"):
                    break
                default:
                    XCTFail("\(scheme.label) 长度掩码 \(mask)：\(outcome)")
                }
            }
            // 高字节翻位让长度变得巨大：不会交出 payload。
            var huge = bytes
            huge[0] ^= 0x01
            let server = try scheme.type.init(initialKeys: material.server)
            XCTAssertFalse(TestPacket.parse(ByteBuffer(bytes: huge), protection: server, sequenceNumber: 1).isPayload)
        }
    }

    /// 截断（少几字节）的输入不会越界读或 trap。
    func testTruncatedPacketsDoNotTrap() throws {
        for scheme in SchemeUnderTest.all {
            let material = TestKeys.Material.random(scheme.type.keySizes)
            let client = try scheme.type.init(initialKeys: material.client)
            var wire = TestPacket.plaintext(payload: TestKeys.random(50), lengthEncrypted: client.lengthEncrypted, blockSize: 16)
            try client.encryptPacket(&wire, sequenceNumber: 0)
            let bytes = Array(wire.readableBytesView)
            for cut in [1, 5, client.macBytes, bytes.count - 16] {
                let server = try scheme.type.init(initialKeys: material.server)
                let outcome = TestPacket.parse(ByteBuffer(bytes: bytes.dropLast(cut)), protection: server, sequenceNumber: 0)
                XCTAssertEqual(outcome, .needMoreData, "\(scheme.label) cut \(cut)")
                // 直接把截短的包交给第二步（解析器不会这么做）：必须抛错而不是越界。
                var direct = ByteBuffer(bytes: bytes.dropLast(cut))
                let other = try scheme.type.init(initialKeys: material.server)
                try other.decryptFirstBlock(&direct)
                XCTAssertThrowsError(try other.decryptAndVerifyRemainingPacket(&direct, sequenceNumber: 0))
            }
        }
    }

    // MARK: 计数器进位

    func testCounterArithmetic() throws {
        var counter = try SSHCTRCounter(iv: [UInt8](hex: "00000000000000000000000000000000"))
        counter.advance(byBlocks: 1)
        XCTAssertEqual(counter.block.hexString, "00000000000000000000000000000001")
        counter = try SSHCTRCounter(iv: [UInt8](hex: "0000000000000000fffffffffffffffe"))
        counter.advance(byBlocks: 3)
        XCTAssertEqual(counter.block.hexString, "00000000000000010000000000000001")
        counter = try SSHCTRCounter(iv: [UInt8](hex: "ffffffffffffffffffffffffffffffff"))
        counter.advance(byBlocks: 2)
        XCTAssertEqual(counter.block.hexString, "00000000000000000000000000000001")
        counter = try SSHCTRCounter(iv: [UInt8](hex: "0102030405060708090a0b0cfffffffe"))
        counter.advance(byBlocks: 2)
        XCTAssertEqual(counter.block.hexString, "0102030405060708090a0b0d00000000")
        XCTAssertThrowsError(try SSHCTRCounter(iv: [UInt8](repeating: 0, count: 15)))
    }

    /// 计数器在包中间跨过 2^32、2^64、2^128 边界时，线上字节与「逐块 AES + 按字节进位」的参考实现一致。
    func testCounterCarryAcrossBoundariesInsideAndBetweenPackets() throws {
        let ivs = [
            "000102030405060708090a0bfffffffd",  // 低 32 位将回绕（BoringSSL 的 ctr32 路径要自己进位）
            "0001020304050607fffffffffffffffd",  // 低 64 位将回绕（我们的计数器要进位到高 64 位）
            "fffffffffffffffffffffffffffffffd",  // 整个 128 位将回绕
        ]
        for ivHex in ivs {
            let iv = [UInt8](hex: ivHex)
            for macName in ["hmac-sha2-256", "hmac-sha2-256-etm@openssh.com"] {
                let type: NIOSSHTransportProtection.Type =
                    macName.hasSuffix("etm@openssh.com")
                    ? SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA256ETM>.self
                    : SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA256>.self
                var material = TestKeys.Material.random(type.keySizes)
                material.ivC2S = iv
                let client = try type.init(initialKeys: material.client)
                let server = try type.init(initialKeys: material.server)

                var referenceCounter = iv
                var sequence: UInt32 = 0
                // 第一个包 3 块（跨边界），第二个包从回绕后的计数继续。
                for payloadSize in [27, 60, 5] {
                    let payload = TestKeys.random(payloadSize)
                    let plaintext = TestPacket.plaintext(payload: payload, lengthEncrypted: client.lengthEncrypted, blockSize: 16)
                    let plainBytes = Array(plaintext.readableBytesView)
                    let encryptedRange = client.lengthEncrypted ? 0..<plainBytes.count : 4..<plainBytes.count
                    let referenceCipher = try ReferenceCTR.keystreamXOR(
                        Array(plainBytes[encryptedRange]),
                        key: material.encC2S,
                        counter: referenceCounter
                    )
                    referenceCounter = Self.add(referenceCounter, blocks: encryptedRange.count / 16)

                    var wire = plaintext
                    try client.encryptPacket(&wire, sequenceNumber: sequence)
                    let wireBytes = Array(wire.readableBytesView)
                    XCTAssertEqual(
                        Array(wireBytes[encryptedRange]),
                        referenceCipher,
                        "iv \(ivHex) \(macName) size \(payloadSize)"
                    )
                    XCTAssertEqual(TestPacket.parse(wire, protection: server, sequenceNumber: sequence), .payload(payload))
                    sequence += 1
                }
            }
        }
    }

    private static func add(_ counter: [UInt8], blocks: Int) -> [UInt8] {
        var value = counter
        for _ in 0..<blocks {
            var i = 15
            while true {
                value[i] &+= 1
                if value[i] != 0 || i == 0 { break }
                i -= 1
            }
        }
        return value
    }

    // MARK: AES-CTR 的 updateKeys

    func testUpdateKeysRefusesKeystreamReuse() throws {
        for scheme in SchemeUnderTest.all {
            let material = TestKeys.Material.random(scheme.type.keySizes)
            let protection = try scheme.type.init(initialKeys: material.client)
            XCTAssertThrowsError(try protection.updateKeys(material.client), scheme.label) { error in
                XCTAssertEqual(error as? SSHTransportProtectionError, .keyReuse)
            }
            // 只有一个方向重复也拒绝。
            var halfFresh = TestKeys.Material.random(scheme.type.keySizes)
            halfFresh.encS2C = material.encS2C
            halfFresh.ivS2C = material.ivS2C
            XCTAssertThrowsError(try protection.updateKeys(halfFresh.client), scheme.label)
            // 拒绝之后状态没变：用原来的密钥还能和对端通。
            let server = try scheme.type.init(initialKeys: material.server)
            var wire = TestPacket.plaintext(payload: [1, 2, 3], lengthEncrypted: protection.lengthEncrypted, blockSize: 16)
            try protection.encryptPacket(&wire, sequenceNumber: 0)
            XCTAssertEqual(TestPacket.parse(wire, protection: server, sequenceNumber: 0), .payload([1, 2, 3]), scheme.label)
            // 新的密钥照常接受。
            XCTAssertNoThrow(try protection.updateKeys(TestKeys.Material.random(scheme.type.keySizes).client))
        }
    }
}
