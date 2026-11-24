/// AES-CTR 的 128 位计数器（RFC 4344 §4）。
///
/// 「The counter X is a 128-bit integer ... encoded in network byte order」：初值是密钥交换给的 IV，
/// 每加 / 解密一个 16 字节块加一，**跨包连续**，直到下一次换钥；进位贯穿全部 128 位，到 2^128 回绕。
package struct SSHCTRCounter: Hashable, Sendable {
    package private(set) var high: UInt64
    package private(set) var low: UInt64

    package init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    /// 由 16 字节的 IV 构造（大端）。
    package init<Bytes: Collection>(iv: Bytes) throws where Bytes.Element == UInt8 {
        guard iv.count == 16 else {
            throw SSHTransportProtectionError.invalidIVSize
        }
        var high: UInt64 = 0
        var low: UInt64 = 0
        for (index, byte) in iv.enumerated() {
            if index < 8 {
                high = (high << 8) | UInt64(byte)
            } else {
                low = (low << 8) | UInt64(byte)
            }
        }
        self.init(high: high, low: low)
    }

    /// 当前计数块（大端 16 字节），即下一个要用的密钥流块的输入。
    package var block: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8(truncatingIfNeeded: self.high >> (56 - 8 * index))
            bytes[8 + index] = UInt8(truncatingIfNeeded: self.low >> (56 - 8 * index))
        }
        return bytes
    }

    /// 前进 `blocks` 个块（模 2^128）。
    package mutating func advance(byBlocks blocks: UInt64) {
        let (newLow, overflow) = self.low.addingReportingOverflow(blocks)
        self.low = newLow
        if overflow {
            self.high &+= 1
        }
    }
}
