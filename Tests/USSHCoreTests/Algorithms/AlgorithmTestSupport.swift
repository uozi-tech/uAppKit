import CommonCrypto
import Crypto
import Foundation
import NIOCore
import NIOSSH
import XCTest
import _CryptoExtras

@testable import USSHCore

// MARK: - 十六进制

extension Array where Element == UInt8 {
    init(hex: String) {
        let cleaned = hex.filter { !$0.isWhitespace && $0 != ":" }
        precondition(cleaned.count % 2 == 0, "十六进制串长度必须是偶数")
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            bytes.append(UInt8(cleaned[index..<next], radix: 16)!)
            index = next
        }
        self = bytes
    }

    var hexString: String {
        self.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 包的构造与解析（模仿 NIOSSH 的 SSHPacketSerializer / SSHPacketParser 的调用方式）

enum TestPacket {
    /// 按 RFC 4253 §6 拼一个明文包（长度 + 填充长度 + payload + 填充），与 NIOSSH 的 `writeSSHPacket` 同一算法。
    static func plaintext(
        payload: [UInt8],
        lengthEncrypted: Bool,
        blockSize: Int,
        extraPaddingBlocks: Int = 0,
        allocator: ByteBufferAllocator = .init()
    ) -> ByteBuffer {
        let covered = lengthEncrypted ? payload.count + 5 : payload.count + 1
        var padding = blockSize - (covered % blockSize)
        if padding < 4 { padding += blockSize }
        padding += extraPaddingBlocks * blockSize
        precondition(padding <= 255)
        var buffer = allocator.buffer(capacity: 5 + payload.count + padding + 64)
        buffer.writeInteger(UInt32(1 + payload.count + padding))
        buffer.writeInteger(UInt8(padding))
        buffer.writeBytes(payload)
        var rng = SystemRandomNumberGenerator()
        buffer.writeBytes((0..<padding).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
        return buffer
    }

    enum ParseOutcome: Equatable {
        case payload([UInt8])
        case needMoreData
        case threw(String)

        var isPayload: Bool {
            if case .payload = self { return true }
            return false
        }
    }

    /// 模仿 NIOSSH 解析器：先在整个缓冲上 `decryptFirstBlock`，读长度，再切出整包交给
    /// `decryptAndVerifyRemainingPacket`。
    static func parse(
        _ wire: ByteBuffer,
        protection: NIOSSHTransportProtection,
        sequenceNumber: UInt32
    ) -> ParseOutcome {
        var buffer = wire
        do {
            guard buffer.readableBytes >= type(of: protection).cipherBlockSize else { return .needMoreData }
            try protection.decryptFirstBlock(&buffer)
            let length = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self)!
            let total = Int(length) + protection.macBytes + 4
            guard var slice = buffer.readSlice(length: total) else { return .needMoreData }
            var payload = try protection.decryptAndVerifyRemainingPacket(&slice, sequenceNumber: sequenceNumber)
            guard slice.readableBytes == 0 else { return .threw("包没读完") }
            return .payload(payload.readBytes(length: payload.readableBytes)!)
        } catch {
            return .threw(String(describing: error))
        }
    }
}

// MARK: - 会话密钥

enum TestKeys {
    static func random(_ count: Int) -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
    }

    struct Material {
        var ivC2S: [UInt8]
        var ivS2C: [UInt8]
        var encC2S: [UInt8]
        var encS2C: [UInt8]
        var macC2S: [UInt8]
        var macS2C: [UInt8]

        static func random(_ sizes: ExpectedKeySizes) -> Material {
            Material(
                ivC2S: TestKeys.random(sizes.ivSize),
                ivS2C: TestKeys.random(sizes.ivSize),
                encC2S: TestKeys.random(sizes.encryptionKeySize),
                encS2C: TestKeys.random(sizes.encryptionKeySize),
                macC2S: TestKeys.random(sizes.macKeySize),
                macS2C: TestKeys.random(sizes.macKeySize)
            )
        }

        var client: NIOSSHSessionKeys {
            NIOSSHSessionKeys(
                initialInboundIV: self.ivS2C,
                initialOutboundIV: self.ivC2S,
                inboundEncryptionKey: SymmetricKey(data: self.encS2C),
                outboundEncryptionKey: SymmetricKey(data: self.encC2S),
                inboundMACKey: SymmetricKey(data: self.macS2C),
                outboundMACKey: SymmetricKey(data: self.macC2S)
            )
        }

        var server: NIOSSHSessionKeys {
            NIOSSHSessionKeys(
                initialInboundIV: self.ivC2S,
                initialOutboundIV: self.ivS2C,
                inboundEncryptionKey: SymmetricKey(data: self.encC2S),
                outboundEncryptionKey: SymmetricKey(data: self.encS2C),
                inboundMACKey: SymmetricKey(data: self.macC2S),
                outboundMACKey: SymmetricKey(data: self.macS2C)
            )
        }
    }
}

// MARK: - 参考实现（CommonCrypto + 逐块 AES，独立于被测代码）

/// 用 CommonCrypto 的有状态 CTR 加密器与 CCHmac 照 RFC 4253 / OpenSSH PROTOCOL 拼出线上字节，
/// 与被测实现逐字节比对。计数器的延续交给 CommonCrypto 自己维护。
final class ReferenceSSHEncrypter {
    private var cryptor: CCCryptorRef?
    private let macKey: [UInt8]
    private let macAlgorithm: CCHmacAlgorithm
    private let macLength: Int
    private let encryptThenMAC: Bool

    init(key: [UInt8], iv: [UInt8], macKey: [UInt8], macName: String) {
        var ref: CCCryptorRef?
        let status = CCCryptorCreateWithMode(
            CCOperation(kCCEncrypt),
            CCMode(kCCModeCTR),
            CCAlgorithm(kCCAlgorithmAES),
            CCPadding(ccNoPadding),
            iv,
            key,
            key.count,
            nil,
            0,
            0,
            CCModeOptions(kCCModeOptionCTR_BE),
            &ref
        )
        precondition(status == kCCSuccess)
        self.cryptor = ref
        self.macKey = macKey
        self.encryptThenMAC = macName.hasSuffix("-etm@openssh.com")
        switch macName {
        case "hmac-sha2-256", "hmac-sha2-256-etm@openssh.com":
            (self.macAlgorithm, self.macLength) = (CCHmacAlgorithm(kCCHmacAlgSHA256), 32)
        case "hmac-sha2-512", "hmac-sha2-512-etm@openssh.com":
            (self.macAlgorithm, self.macLength) = (CCHmacAlgorithm(kCCHmacAlgSHA512), 64)
        case "hmac-sha1", "hmac-sha1-etm@openssh.com":
            (self.macAlgorithm, self.macLength) = (CCHmacAlgorithm(kCCHmacAlgSHA1), 20)
        default:
            preconditionFailure("未知 MAC \(macName)")
        }
    }

    deinit {
        CCCryptorRelease(self.cryptor)
    }

    private func ctr(_ input: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status = CCCryptorUpdate(self.cryptor, input, input.count, &output, output.count, &moved)
        precondition(status == kCCSuccess && moved == input.count)
        return output
    }

    func mac(_ data: [UInt8], sequenceNumber: UInt32) -> [UInt8] {
        let message = withUnsafeBytes(of: sequenceNumber.bigEndian) { Array($0) } + data
        var out = [UInt8](repeating: 0, count: self.macLength)
        CCHmac(self.macAlgorithm, self.macKey, self.macKey.count, message, message.count, &out)
        return out
    }

    /// `plaintextPacket` 是完整明文包（含长度字段）。
    func seal(_ plaintextPacket: [UInt8], sequenceNumber: UInt32) -> [UInt8] {
        if self.encryptThenMAC {
            let encrypted = Array(plaintextPacket[0..<4]) + self.ctr(Array(plaintextPacket[4...]))
            return encrypted + self.mac(encrypted, sequenceNumber: sequenceNumber)
        } else {
            return self.ctr(plaintextPacket) + self.mac(plaintextPacket, sequenceNumber: sequenceNumber)
        }
    }
}

/// 逐块调用 AES 置换、自己维护 128 位大端计数器的 CTR 参考实现，专门用来核对计数器进位。
enum ReferenceCTR {
    static func keystreamXOR(_ input: [UInt8], key: [UInt8], counter: [UInt8]) throws -> [UInt8] {
        precondition(input.count % 16 == 0 && counter.count == 16)
        var block = counter
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        let symmetricKey = SymmetricKey(data: key)
        for offset in stride(from: 0, to: input.count, by: 16) {
            var keystream = block
            try AES.permute(&keystream, key: symmetricKey)
            for i in 0..<16 {
                output.append(input[offset + i] ^ keystream[i])
            }
            // 128 位大端 +1，按字节进位。
            var i = 15
            while true {
                block[i] &+= 1
                if block[i] != 0 || i == 0 { break }
                i -= 1
            }
        }
        return output
    }
}

// MARK: - 方案元数据

struct SchemeUnderTest {
    let type: NIOSSHTransportProtection.Type
    var cipherName: String { self.type.cipherName }
    var macName: String { self.type.macName! }
    var label: String { "\(self.cipherName) + \(self.macName)" }
    var encryptThenMAC: Bool { self.macName.hasSuffix("-etm@openssh.com") }

    static var all: [SchemeUnderTest] {
        (SSHTransportProtections.modern + SSHTransportProtections.requiringKeyExtension + SSHTransportProtections.legacy)
            .map { SchemeUnderTest(type: $0) }
    }
}
