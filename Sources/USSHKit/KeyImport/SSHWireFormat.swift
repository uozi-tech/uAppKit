import USSHCore

/// SSH 线格式写入器。
nonisolated struct SSHWireWriter {
    private(set) var bytes: [UInt8] = []

    mutating func writeUInt32(_ value: UInt32) {
        bytes.append(UInt8((value >> 24) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    /// `string`：uint32 长度前缀 + 原始字节。
    mutating func writeString(_ value: [UInt8]) {
        writeUInt32(UInt32(value.count))
        bytes.append(contentsOf: value)
    }

    mutating func writeString(_ value: String) { writeString([UInt8](value.utf8)) }

    /// `mpint`：去前导零；若结果最高位为 1 则前补 0x00；再按 `string` 写出。
    mutating func writeMPInt(_ magnitude: [UInt8]) {
        var m = SSHWireReader.strippingLeadingZeros(magnitude)
        if m == [0x00] { m = [] }                       // 数值 0 -> 空 string
        if let first = m.first, first & 0x80 != 0 { m.insert(0x00, at: 0) }
        writeString(m)
    }

    mutating func writeRawBytes(_ value: [UInt8]) { bytes.append(contentsOf: value) }
}

/// SSH 线格式读取器。
nonisolated struct SSHWireReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= bytes.count else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "SSH 线格式：读 uint32 越界", bundle: ModuleBundle.bundle))
        }
        defer { offset += 4 }
        return (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
             | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    /// 一个 `string` 最长这么多字节。私钥文件里最大的字段是 OpenSSH 容器的私钥段：8192 位 RSA 的
    /// n / e / d / iqmp / p / q 加注释与填充约 4.3 KiB，留足注释的余地取 64 KiB。超过的一律当结构损坏。
    static let maximumStringLength = 64 * 1024

    /// 一个 `mpint` 的幅值最长这么多字节：8192 位（`SSHRSAPublicKey.maximumModulusBits`）的模数。
    /// 私钥文件里的任何整数（n、d、素因子、ECDSA 标量）都不会更长；更长的在做大数运算之前就拒绝。
    static let maximumMPIntLength = SSHRSAPublicKey.maximumModulusBits / 8

    mutating func readString() throws -> [UInt8] {
        let length = Int(try readUInt32())
        guard length <= Self.maximumStringLength, offset + length <= bytes.count else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "SSH 线格式：读 string 越界", bundle: ModuleBundle.bundle))
        }
        defer { offset += length }
        return Array(bytes[offset..<offset + length])
    }

    /// 去掉前导零（至少留一个字节）。一次切片，线性；以前逐个 `removeFirst` 是平方级的。
    static func strippingLeadingZeros(_ bytes: [UInt8]) -> [UInt8] {
        let trimmed = bytes.drop(while: { $0 == 0 })
        return trimmed.isEmpty ? Array(bytes.suffix(1)) : Array(trimmed)
    }

    /// 读 `mpint`，返回无符号大端幅值（去掉符号 0x00）。
    mutating func readMPInt() throws -> [UInt8] {
        let m = Self.strippingLeadingZeros(try readString())
        guard m.count <= Self.maximumMPIntLength else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "SSH 线格式：整数过长", bundle: ModuleBundle.bundle))
        }
        return m
    }
}
