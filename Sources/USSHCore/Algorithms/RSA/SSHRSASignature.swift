import NIOCore

/// RSA 签名 blob（RFC 8332 §3、RFC 4253 §6.6）：`string 算法名 ‖ string 签名`，签名是大端无符号整数，
/// 长度应等于模数字节数（解析时不强求，校验时按 RFC 8332 的宽松规则左侧补零）。
public struct SSHRSASignature: Hashable, Sendable {
    public let algorithm: SSHRSASignatureAlgorithm
    /// 原始 RSA 签名字节。
    public let bytes: [UInt8]

    public init(algorithm: SSHRSASignatureAlgorithm, bytes: [UInt8]) {
        self.algorithm = algorithm
        self.bytes = bytes
    }

    /// 解析完整的签名 blob，不允许多余字节；算法名不认识抛 `.unknownSignatureAlgorithm`。
    public init<Bytes: Collection>(sshBlob: Bytes) throws where Bytes.Element == UInt8 {
        var buffer = ByteBuffer(bytes: sshBlob)
        let name = try buffer.readSSHWireIdentifier()
        guard let algorithm = SSHRSASignatureAlgorithm(name: name) else {
            throw SSHRSAError.unknownSignatureAlgorithm
        }
        self = try Self(algorithm: algorithm, readingBodyFrom: &buffer)
        try buffer.requireFullyConsumed()
    }

    /// 完整的签名 blob。
    public var sshBlob: [UInt8] {
        var buffer = ByteBuffer()
        buffer.writeSSHWireString(self.algorithm.name)
        self.writeBody(to: &buffer)
        return Array(buffer.readableBytesView)
    }

    /// 只读主体（算法名之后的 `string 签名`）。给 NIOSSH 的签名扩展接口用。
    package init(algorithm: SSHRSASignatureAlgorithm, readingBodyFrom buffer: inout ByteBuffer) throws {
        // 最大模数（8192 位）的签名是 1024 字节。
        let maximum = SSHRSAPublicKey.maximumModulusBits / 8
        let original = buffer.readerIndex
        let signature: ByteBuffer
        do {
            signature = try buffer.readSSHWireString(maximumLength: maximum)
        } catch SSHWireFormatError.lengthExceedsLimit {
            buffer.moveReaderIndex(to: original)
            throw SSHRSAError.invalidSignatureLength
        }
        guard signature.readableBytes > 0 else {
            buffer.moveReaderIndex(to: original)
            throw SSHRSAError.invalidSignatureLength
        }
        self.init(algorithm: algorithm, bytes: Array(signature.readableBytesView))
    }

    @discardableResult
    package func writeBody(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHWireString(self.bytes)
    }
}
