import BigInt
import Foundation
import NIOCore

/// SSH 线格式（RFC 4251 §5）解析失败的原因。
///
/// 所有从对端读来的长度在用之前都先核对：声明的长度超过剩余字节、超过上限、编码不是最短形式，
/// 一律抛错，绝不越界读、绝不 trap。
public enum SSHWireFormatError: Error, Hashable, Sendable {
    /// 剩余字节不够读出声明的内容。
    case truncated
    /// 声明的长度超过调用方给的上限。
    case lengthExceedsLimit(declared: Int, limit: Int)
    /// mpint 带了多余的前导 0x00 / 0xFF（RFC 4251 §5 规定 MUST NOT）。
    case nonMinimalMPInt
    /// 期望非负的 mpint 是负数。
    case negativeMPInt
    /// name-list 里有空名字、非可打印 ASCII 或过长的名字（RFC 4251 §6）。
    case invalidNameList
    /// 字符串不是合法的 UTF-8 / ASCII。
    case invalidString
    /// 期望的标识（如公钥类型名）与实际不符。
    case unexpectedIdentifier
    /// 一个完整的结构读完后还剩字节。
    case trailingBytes(count: Int)
}

/// 线格式读写的上限。
package enum SSHWireLimits {
    /// 单个 `string` 的默认上限。SSH 包本身最大约 256 KiB（NIOSSH 的上限），不会有更长的字段。
    package static let maximumStringLength = 256 * 1024

    /// 单个 `mpint` 的默认上限：2049 字节够放 16384 位的 RSA 模数（带一个前导 0x00）。
    package static let maximumMPIntLength = 2049

    /// RFC 4251 §6：算法名不超过 64 个字符。
    package static let maximumNameLength = 64
}

// MARK: - 读

extension ByteBuffer {
    /// 读一个 `uint32`（大端）。
    package mutating func readSSHWireUInt32() throws -> UInt32 {
        guard let value = self.readInteger(endianness: .big, as: UInt32.self) else {
            throw SSHWireFormatError.truncated
        }
        return value
    }

    /// 读一个 `string`（`uint32` 长度 + 字节），返回内容的切片。
    ///
    /// 失败时读指针不动（先 `get` 再 `move`）。
    package mutating func readSSHWireString(
        maximumLength: Int = SSHWireLimits.maximumStringLength
    ) throws -> ByteBuffer {
        guard let declared = self.getInteger(at: self.readerIndex, endianness: .big, as: UInt32.self) else {
            throw SSHWireFormatError.truncated
        }
        // UInt32 → Int 在 64 位平台上不会溢出；在 32 位平台上先和上限比较再转换。
        guard declared <= UInt32(clamping: maximumLength) else {
            throw SSHWireFormatError.lengthExceedsLimit(declared: Int(clamping: declared), limit: maximumLength)
        }
        let length = Int(declared)
        guard self.readableBytes - 4 >= length else {
            throw SSHWireFormatError.truncated
        }
        self.moveReaderIndex(forwardBy: 4)
        // 上面已核对过剩余字节，这里一定成功。
        return self.readSlice(length: length)!
    }

    /// 读一个 `string` 并要求内容是 US-ASCII 的标识（算法名、密钥类型名等）。
    package mutating func readSSHWireIdentifier() throws -> String {
        let bytes = try self.readSSHWireString(maximumLength: SSHWireLimits.maximumNameLength)
        let view = bytes.readableBytesView
        guard !view.isEmpty, view.allSatisfy(Self.isNameByte) else {
            throw SSHWireFormatError.invalidString
        }
        return String(decoding: view, as: UTF8.self)
    }

    /// 读一个 `name-list`（RFC 4251 §5）：逗号分隔、每项非空、可打印 US-ASCII、不含逗号与空白、不超过 64 字符。
    /// 空串表示空列表。
    package mutating func readSSHWireNameList(
        maximumLength: Int = SSHWireLimits.maximumStringLength
    ) throws -> [String] {
        let original = self.readerIndex
        let content = try self.readSSHWireString(maximumLength: maximumLength)
        do {
            return try Self.parseNameList(content.readableBytesView)
        } catch {
            self.moveReaderIndex(to: original)
            throw error
        }
    }

    /// 读一个 `mpint`，按二补码解释，返回有符号整数。要求最短编码。
    package mutating func readSSHWireMPInt(
        maximumLength: Int = SSHWireLimits.maximumMPIntLength
    ) throws -> BigInt {
        let original = self.readerIndex
        let content = try self.readSSHWireString(maximumLength: maximumLength)
        do {
            return try Self.decodeMPInt(Array(content.readableBytesView))
        } catch {
            self.moveReaderIndex(to: original)
            throw error
        }
    }

    /// 读一个非负的 `mpint`，返回去掉前导零的大端无符号字节串（0 是空数组）。
    /// 负数抛 `.negativeMPInt`，非最短编码抛 `.nonMinimalMPInt`。
    package mutating func readSSHWireUnsignedMPInt(
        maximumLength: Int = SSHWireLimits.maximumMPIntLength
    ) throws -> [UInt8] {
        let original = self.readerIndex
        let content = try self.readSSHWireString(maximumLength: maximumLength)
        do {
            return try Self.decodeUnsignedMPInt(Array(content.readableBytesView))
        } catch {
            self.moveReaderIndex(to: original)
            throw error
        }
    }

    /// 要求缓冲读完，否则抛 `.trailingBytes`。
    package func requireFullyConsumed() throws {
        if self.readableBytes != 0 {
            throw SSHWireFormatError.trailingBytes(count: self.readableBytes)
        }
    }
}

// MARK: - 写

extension ByteBuffer {
    /// 写一个 `uint32`（大端），返回写入字节数。
    @discardableResult
    package mutating func writeSSHWireUInt32(_ value: UInt32) -> Int {
        self.writeInteger(value, endianness: .big)
    }

    /// 写一个 `string`（`uint32` 长度 + 字节），返回写入字节数。
    @discardableResult
    package mutating func writeSSHWireString<Bytes: Collection>(_ bytes: Bytes) -> Int where Bytes.Element == UInt8 {
        precondition(bytes.count <= UInt32.max, "SSH string 超过 uint32 能表示的长度")
        let written = self.writeInteger(UInt32(bytes.count), endianness: .big)
        return written + self.writeBytes(bytes)
    }

    /// 写一个 ASCII 标识的 `string`。
    @discardableResult
    package mutating func writeSSHWireString(_ string: String) -> Int {
        self.writeSSHWireString(Array(string.utf8))
    }

    /// 写一个 `name-list`。调用方保证每个名字合法（这里只断言，名字都是代码里的常量）。
    @discardableResult
    package mutating func writeSSHWireNameList(_ names: [String]) -> Int {
        assert(names.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy(Self.isNameByte) })
        return self.writeSSHWireString(names.joined(separator: ","))
    }

    /// 写一个有符号整数的 `mpint`（二补码、最短编码）。
    @discardableResult
    package mutating func writeSSHWireMPInt(_ value: BigInt) -> Int {
        self.writeSSHWireString(Self.encodeMPInt(value))
    }

    /// 写一个非负整数的 `mpint`。`magnitude` 是大端无符号字节串，允许带前导零（会被去掉）；
    /// 最高位为 1 时补一个 0x00，保证读回来是正数。
    @discardableResult
    package mutating func writeSSHWireUnsignedMPInt<Bytes: Collection>(
        magnitude: Bytes
    ) -> Int where Bytes.Element == UInt8 {
        self.writeSSHWireString(Self.encodeUnsignedMPInt(magnitude: magnitude))
    }
}

// MARK: - 纯函数（编码规则本身，单测直接测它们）

extension ByteBuffer {
    /// RFC 4251 §6：名字是可打印 US-ASCII，不含逗号、空白、控制字符。
    package static func isNameByte(_ byte: UInt8) -> Bool {
        byte >= 0x21 && byte <= 0x7E && byte != UInt8(ascii: ",")
    }

    package static func parseNameList<Bytes: Collection>(_ bytes: Bytes) throws -> [String] where Bytes.Element == UInt8 {
        if bytes.isEmpty {
            return []
        }
        var names: [String] = []
        for part in bytes.split(separator: UInt8(ascii: ","), omittingEmptySubsequences: false) {
            guard !part.isEmpty, part.count <= SSHWireLimits.maximumNameLength, part.allSatisfy(Self.isNameByte) else {
                throw SSHWireFormatError.invalidNameList
            }
            names.append(String(decoding: part, as: UTF8.self))
        }
        return names
    }

    /// mpint 的内容（不含长度前缀）→ 有符号整数。
    package static func decodeMPInt(_ bytes: [UInt8]) throws -> BigInt {
        guard let first = bytes.first else {
            return 0
        }
        try Self.checkMinimal(bytes)
        let magnitude = BigUInt(Data(bytes))
        if first & 0x80 == 0 {
            return BigInt(magnitude)
        }
        // 负数：值 = 无符号读数 − 2^(8n)。
        return BigInt(magnitude) - (BigInt(1) << (8 * bytes.count))
    }

    /// mpint 的内容（不含长度前缀）→ 非负整数的大端无符号字节串（去掉前导零）。
    package static func decodeUnsignedMPInt(_ bytes: [UInt8]) throws -> [UInt8] {
        guard let first = bytes.first else {
            return []
        }
        guard first & 0x80 == 0 else {
            throw SSHWireFormatError.negativeMPInt
        }
        try Self.checkMinimal(bytes)
        return first == 0 ? Array(bytes.dropFirst()) : bytes
    }

    /// RFC 4251 §5：「Unnecessary leading bytes with the value 0 or 255 MUST NOT be included.
    /// The value zero MUST be stored as a string with zero bytes of data.」
    private static func checkMinimal(_ bytes: [UInt8]) throws {
        guard bytes.count >= 1 else { return }
        let first = bytes[0]
        if bytes.count == 1 {
            // 单独一个 0x00 是零的非最短写法；单独一个 0xFF 是 −1，合法。
            if first == 0x00 { throw SSHWireFormatError.nonMinimalMPInt }
            return
        }
        let second = bytes[1]
        if first == 0x00, second & 0x80 == 0 { throw SSHWireFormatError.nonMinimalMPInt }
        if first == 0xFF, second & 0x80 != 0 { throw SSHWireFormatError.nonMinimalMPInt }
    }

    /// 有符号整数 → mpint 内容（二补码、最短）。
    package static func encodeMPInt(_ value: BigInt) -> [UInt8] {
        if value.sign == .plus || value.isZero {
            return Self.encodeUnsignedMPInt(magnitude: Array(value.magnitude.serialize()))
        }
        // 负数：找最小的 n 使 −2^(8n−1) ≤ value，写 2^(8n) + value。
        var byteCount = (value.magnitude.bitWidth + 7) / 8
        if byteCount == 0 { byteCount = 1 }
        while -(BigInt(1) << (8 * byteCount - 1)) > value {
            byteCount += 1
        }
        let twosComplement = ((BigInt(1) << (8 * byteCount)) + value).magnitude
        var bytes = Array(twosComplement.serialize())
        if bytes.count < byteCount {
            bytes.insert(contentsOf: repeatElement(0, count: byteCount - bytes.count), at: 0)
        }
        // 最短化：去掉多余的 0xFF（后一字节最高位仍为 1 时）。
        while bytes.count > 1, bytes[0] == 0xFF, bytes[1] & 0x80 != 0 {
            bytes.removeFirst()
        }
        return bytes
    }

    /// 非负整数的大端字节串（可带前导零）→ mpint 内容。
    package static func encodeUnsignedMPInt<Bytes: Collection>(
        magnitude: Bytes
    ) -> [UInt8] where Bytes.Element == UInt8 {
        let trimmed = magnitude.drop(while: { $0 == 0 })
        guard let first = trimmed.first else {
            return []
        }
        if first & 0x80 != 0 {
            return [0] + trimmed
        }
        return Array(trimmed)
    }
}

// MARK: - 字节工具

package enum SSHBytes {
    /// 去掉前导零的大端无符号字节串。
    package static func trimmingLeadingZeros<Bytes: Collection>(_ bytes: Bytes) -> [UInt8] where Bytes.Element == UInt8 {
        Array(bytes.drop(while: { $0 == 0 }))
    }

    /// 把 `bytes` 左侧补零到 `length`；比 `length` 长时返回 nil。
    package static func leftPadded(_ bytes: [UInt8], to length: Int) -> [UInt8]? {
        guard bytes.count <= length else { return nil }
        if bytes.count == length { return bytes }
        return [UInt8](repeating: 0, count: length - bytes.count) + bytes
    }

    /// 尽力抹掉内存里的敏感字节（`[UInt8]` 唯一持有时有效）。
    package static func zeroize(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return }
            _ = memset_s(base, buffer.count, 0, buffer.count)
        }
    }
}

extension BigUInt {
    /// 大端无符号字节串（0 为空数组）。
    package var sshMagnitudeBytes: [UInt8] {
        Array(self.serialize())
    }

    package init<Bytes: Collection>(sshMagnitude bytes: Bytes) where Bytes.Element == UInt8 {
        self.init(Data(bytes))
    }
}
