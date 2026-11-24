/// 只为把 RSA 分量交给 BoringSSL 而写的最小 DER 编码器（只编码、不解析）。
///
/// swift-crypto 的 `_RSA.Signing` 按分量构造的入口要求模数 ≥ 2048 位；为了兼容 1024–2047 位的旧密钥，
/// 统一拼成 PKCS#1 DER 走 `unsafeDERRepresentation`（≥ 1024 位），最小位数由我们自己把关。
/// BoringSSL 解析 PKCS#1 私钥时会做 `RSA_check_key`，分量不一致会被拒绝。
enum RSADEREncoding {
    /// INTEGER：非负整数的大端字节串（可带前导零）。最短编码，最高位为 1 时补 0x00，零编码为 `02 01 00`。
    static func integer<Bytes: Collection>(_ magnitude: Bytes) -> [UInt8] where Bytes.Element == UInt8 {
        var content = SSHBytes.trimmingLeadingZeros(magnitude)
        if content.isEmpty {
            content = [0]
        } else if content[0] & 0x80 != 0 {
            content.insert(0, at: 0)
        }
        return [0x02] + Self.length(content.count) + content
    }

    static func sequence(_ elements: [[UInt8]]) -> [UInt8] {
        let content = elements.flatMap { $0 }
        return [0x30] + Self.length(content.count) + content
    }

    static func length(_ count: Int) -> [UInt8] {
        precondition(count >= 0)
        if count < 0x80 {
            return [UInt8(count)]
        }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(truncatingIfNeeded: remaining), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    /// PKCS#1 `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }`。
    static func pkcs1PublicKey(modulus: [UInt8], publicExponent: [UInt8]) -> [UInt8] {
        Self.sequence([Self.integer(modulus), Self.integer(publicExponent)])
    }

    /// PKCS#1 `RSAPrivateKey ::= SEQUENCE { version(0), n, e, d, p, q, d mod (p−1), d mod (q−1), q⁻¹ mod p }`。
    static func pkcs1PrivateKey(_ c: SSHRSAPrivateKeyComponents, exponent1: [UInt8], exponent2: [UInt8], coefficient: [UInt8]) -> [UInt8] {
        Self.sequence([
            Self.integer([0]),
            Self.integer(c.modulus),
            Self.integer(c.publicExponent),
            Self.integer(c.privateExponent),
            Self.integer(c.prime1),
            Self.integer(c.prime2),
            Self.integer(exponent1),
            Self.integer(exponent2),
            Self.integer(coefficient),
        ])
    }
}
