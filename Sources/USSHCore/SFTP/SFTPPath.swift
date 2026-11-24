/// SFTP 线上的路径 / 文件名：原样的字节串。
///
/// SFTP v3 的文件名是不透明字节（OpenSSH 不做任何编码转换），服务端上完全可以有不是 UTF-8 的名字，
/// 也可以有 NFC 与 NFD 两种写法并存的「同一个」名字。拿 `String` 承载会出两类错：
/// 非法序列被替换成 U+FFFD，几个不同的名字解出来一样，再拿这个字符串去操作就打到别的文件或者找不到；
/// `String` 的相等按 Unicode 规范等价比较，NFC 与 NFD 的两个不同文件会被当成同一个。
///
/// 所以路径一律用它在线上往返：相等与哈希按**字节**，不按字符串。由 `String` 构造（UTF-8 编码）、
/// 由字节构造、字符串字面量都行；`string` 给显示用（非法序列替换），`isLosslessUTF8` 告诉调用方
/// 这个名字能不能安全地只用字符串表示。
public struct SFTPPath: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible, CustomDebugStringConvertible {
    /// 线上的原始字节。
    public let bytes: [UInt8]

    public init(_ string: String) {
        self.bytes = Array(string.utf8)
    }

    public init<Bytes: Sequence>(bytes: Bytes) where Bytes.Element == UInt8 {
        self.bytes = Array(bytes)
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// 按 UTF-8 解出来的字符串；非法序列替换成 U+FFFD（只适合显示，不适合再拿去操作）。
    public var string: String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// 字节是合法的 UTF-8：`SFTPPath(path.string) == path` 成立。
    public var isLosslessUTF8: Bool {
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue: continue
            case .emptyInput: return true
            case .error: return false
            }
        }
    }

    public var isEmpty: Bool { bytes.isEmpty }

    /// 用 `/` 接上一段（自己以 `/` 结尾或为空时不重复加）。
    public func appending(_ component: SFTPPath) -> SFTPPath {
        if bytes.isEmpty { return component }
        if bytes.last == UInt8(ascii: "/") { return SFTPPath(bytes: bytes + component.bytes) }
        return SFTPPath(bytes: bytes + [UInt8(ascii: "/")] + component.bytes)
    }

    public var description: String { string }

    public var debugDescription: String {
        isLosslessUTF8 ? "SFTPPath(\(string.debugDescription))" : "SFTPPath(bytes: \(bytes))"
    }
}
