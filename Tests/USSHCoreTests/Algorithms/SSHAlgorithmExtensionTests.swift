import BigInt
import Crypto
import Foundation
import NIOCore
import NIOSSH
import XCTest

@testable import USSHCore

/// NIOSSH 扩展接口上的适配层：RSA 公钥 / 签名 / 私钥、有限域 DH，以及审查要求的防误用。不建连接。
final class SSHAlgorithmExtensionTests: XCTestCase {
    override func setUp() {
        SSHAlgorithms.registerStandardAlgorithms()
    }

    // MARK: RSA 公钥

    func testPublicKeyReadsOnlyItsOwnBytesAndWritesThemBack() throws {
        for fixture in RSAFixtures.keys {
            let blob = [UInt8](hex: fixture.publicKeyBlob)
            // NIOSSH 有的调用点给的是整条报文剩下的部分：公钥后面还跟着别的字节。
            var buffer = ByteBuffer(bytes: blob + [0xde, 0xad, 0xbe, 0xef])
            _ = try buffer.readSSHWireIdentifier()
            let key = try SSHRSAExtensionPublicKey.read(from: &buffer)
            XCTAssertEqual(Array(buffer.readableBytesView), [0xde, 0xad, 0xbe, 0xef], "只读两个 mpint")
            XCTAssertEqual(key.blob, blob, "原样写回")
            var written = ByteBuffer()
            XCTAssertEqual(key.write(to: &written), blob.count - 11)   // 去掉 string "ssh-rsa"
            XCTAssertEqual(key.key, try SSHRSAPublicKey(sshBlob: blob))

            // 经 NIOSSH 解析 OpenSSH 公钥行，取回来的是同一把。
            let line = "ssh-rsa " + Data(blob).base64EncodedString()
            let parsed = try NIOSSHPublicKey(openSSHPublicKey: line)
            XCTAssertEqual(parsed, NIOSSHPublicKey(rsaPublicKey: key.key))
            XCTAssertEqual(parsed.rsaPublicKey, key.key)
            XCTAssertEqual(String(openSSHPublicKey: parsed), line)
        }
        XCTAssertNil(NIOSSHPrivateKey(ed25519Key: .init()).publicKey.rsaPublicKey)
    }

    func testMalformedPublicKeyBodiesDoNotMoveTheReader() throws {
        for body: [UInt8] in [[], [0, 0, 0, 3, 1, 0, 1], [0, 0, 0, 9, 1], [0, 0, 0, 1, 0x80, 0, 0, 0, 1, 1]] {
            var buffer = ByteBuffer(bytes: body)
            XCTAssertThrowsError(try SSHRSAExtensionPublicKey.read(from: &buffer))
            XCTAssertEqual(buffer.readerIndex, 0)
        }
    }

    /// 适配层按签名自己的类型验；不是 RSA 签名、或签名与数据对不上都判假，不会因为是 SHA-1 就放行或崩溃。
    func testPublicKeyVerifiesBySignatureTypeAndRecordsTheAlgorithm() throws {
        let key = try SSHRSAPrivateKey(pemRepresentation: RSAFixtures.keys[1].pkcs1PEM)
        let publicKey = SSHRSAExtensionPublicKey(key.publicKey)
        let data = Array("exchange hash".utf8)
        for algorithm in SSHRSASignatureAlgorithm.allCases {
            let signature: NIOSSHSignatureProtocol
            switch algorithm {
            case .rsaSHA2_512: signature = try SSHRSAExtensionPrivateKey<SSHRSAExtensionSHA512>(key).signature(for: data)
            case .rsaSHA2_256: signature = try SSHRSAExtensionPrivateKey<SSHRSAExtensionSHA256>(key).signature(for: data)
            case .sshRSA: signature = try SSHRSAExtensionPrivateKey<SSHRSAExtensionSHA1>(key).signature(for: data)
            }
            XCTAssertEqual(type(of: signature).signaturePrefix, algorithm.name)
            XCTAssertTrue(publicKey.isValidSignature(signature, for: data))
            XCTAssertEqual(SSHRSAVerificationRecord.take(keyBlob: publicKey.blob), algorithm)
            XCTAssertNil(SSHRSAVerificationRecord.take(keyBlob: publicKey.blob), "取出即清除")
            XCTAssertFalse(publicKey.isValidSignature(signature, for: data + [0]))
            XCTAssertNil(SSHRSAVerificationRecord.take(keyBlob: publicKey.blob), "验不过不留记录")

            // 签名 blob 往返。
            var buffer = ByteBuffer()
            _ = signature.write(to: &buffer)
            let reread: NIOSSHSignatureProtocol
            switch algorithm {
            case .rsaSHA2_512: reread = try SSHRSAExtensionSignature<SSHRSAExtensionSHA512>.read(from: &buffer)
            case .rsaSHA2_256: reread = try SSHRSAExtensionSignature<SSHRSAExtensionSHA256>.read(from: &buffer)
            case .sshRSA: reread = try SSHRSAExtensionSignature<SSHRSAExtensionSHA1>.read(from: &buffer)
            }
            XCTAssertEqual(reread.rawRepresentation, signature.rawRepresentation)
        }
        // 别的钥匙的签名、或根本不是 RSA 的签名。
        XCTAssertFalse(publicKey.isValidSignature(ForeignSignature(), for: data))
        let other = try SSHRSAPrivateKey(pemRepresentation: RSAFixtures.keys[2].pkcs1PEM)
        XCTAssertFalse(publicKey.isValidSignature(
            try SSHRSAExtensionPrivateKey<SSHRSAExtensionSHA512>(other).signature(for: data), for: data))
    }

    /// 别的钥匙留下的记录不能被当成这把钥匙的。
    func testVerificationRecordIsBoundToTheKey() throws {
        let key = SSHRSAExtensionPublicKey(try SSHRSAPrivateKey(pemRepresentation: RSAFixtures.keys[1].pkcs1PEM).publicKey)
        let other = SSHRSAExtensionPublicKey(try SSHRSAPrivateKey(pemRepresentation: RSAFixtures.keys[2].pkcs1PEM).publicKey)
        SSHRSAVerificationRecord.record(algorithm: .sshRSA, keyBlob: other.blob)
        XCTAssertNil(SSHRSAVerificationRecord.take(keyBlob: key.blob))
        XCTAssertNil(SSHRSAVerificationRecord.take(keyBlob: other.blob), "不匹配时也清掉")
    }

    // MARK: 有限域 DH

    func testDiffieHellmanAdaptersAgreeAndRejectOutOfRangeValues() throws {
        func agree<V: SSHDiffieHellmanExtensionVariant>(_: V.Type) throws {
            var client = SSHDiffieHellmanExtensionKeyExchange<V>()
            var server = SSHDiffieHellmanExtensionKeyExchange<V>()
            XCTAssertEqual(type(of: client).keyExchangeAlgorithmNames, [Substring(V.algorithm.name)])
            XCTAssertEqual(type(of: client).publicValueEncoding, .mpint)
            let k1 = try client.sharedSecret(peerPublicValue: server.publicValue)
            let k2 = try server.sharedSecret(peerPublicValue: client.publicValue)
            XCTAssertEqual(k1, k2)
            XCTAssertThrowsError(try client.sharedSecret(peerPublicValue: server.publicValue)) { error in
                XCTAssertEqual(error as? SSHDiffieHellmanError, .alreadyCompleted)
            }

            let prime = V.algorithm.group.primeBytes
            let pMinus1 = (BigUInt(Data(prime)) - 1).sshMagnitudeBytes
            let pPlus1 = (BigUInt(Data(prime)) + 1).sshMagnitudeBytes
            var fresh = SSHDiffieHellmanExtensionKeyExchange<V>()
            for value: [UInt8] in [[], [0], [1], [0, 1], pMinus1, prime, pPlus1, [UInt8](repeating: 0xFF, count: prime.count + 1)] {
                XCTAssertThrowsError(try fresh.sharedSecret(peerPublicValue: value), "\(V.algorithm.name)") { error in
                    XCTAssertEqual(error as? SSHDiffieHellmanError, .invalidPeerPublicValue)
                }
            }
            // 校验失败不消耗私钥：随后的合法值照样能算。
            XCTAssertNoThrow(try fresh.sharedSecret(peerPublicValue: [2]))
        }
        try agree(SSHDiffieHellmanGroup14SHA256.self)
        try agree(SSHDiffieHellmanGroup14SHA1.self)
        try agree(SSHDiffieHellmanGroup16SHA512.self)
    }

    /// NIOSSH 在状态机里复制适配器结构体：复制品共享同一个只能用一次的私钥。
    func testCopiesShareTheSingleUseExponent() throws {
        var original = SSHDiffieHellmanExtensionKeyExchange<SSHDiffieHellmanGroup14SHA256>()
        var copy = original
        let peer = SSHDiffieHellmanKeyExchange(algorithm: .group14SHA256, role: .server).localPublicValue
        _ = try original.sharedSecret(peerPublicValue: peer)
        XCTAssertThrowsError(try copy.sharedSecret(peerPublicValue: peer)) { error in
            XCTAssertEqual(error as? SSHDiffieHellmanError, .alreadyCompleted)
        }
    }
}

/// 不是 RSA 的签名类型（测试用，不登记）。
private struct ForeignSignature: NIOSSHSignatureProtocol {
    static var signaturePrefix: String { "test-foreign@example.com" }
    var rawRepresentation: Data { Data([1]) }
    func write(to buffer: inout ByteBuffer) -> Int { 0 }
    static func read(from buffer: inout ByteBuffer) throws -> ForeignSignature { ForeignSignature() }
}
