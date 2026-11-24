import USSHCore
import Foundation
import SwiftASN1
import Crypto

/// 解析明文 DER 私钥为 `ParsedPrivateKey`。
/// 用 SwiftASN1 的 `DER.parse` 得到节点树后手动遍历已知结构。
nonisolated enum DERKeyDecoder {

    // MARK: - OID 常量（点分字符串）

    enum OID {
        static let rsaEncryption  = "1.2.840.113549.1.1.1"
        static let ecPublicKey    = "1.2.840.10045.2.1"
        static let ed25519        = "1.3.101.112"
        static let dsa            = "1.2.840.10040.4.1"
        static let p256           = "1.2.840.10045.3.1.7"
        static let p384           = "1.3.132.0.34"
        static let p521           = "1.3.132.0.35"
        static let primeField     = "1.2.840.10045.1.1"
    }

    // MARK: - 节点遍历助手

    /// 取构造型节点（SEQUENCE 等）的子节点数组。
    static func children(_ node: ASN1Node) throws -> [ASN1Node] {
        guard case .constructed(let collection) = node.content else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "DER：期望构造型节点", bundle: ModuleBundle.bundle))
        }
        return Array(collection)
    }

    /// 取原始型节点（INTEGER / OCTET STRING 等）的内容字节。
    static func primitiveBytes(_ node: ASN1Node) throws -> [UInt8] {
        guard case .primitive(let bytes) = node.content else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "DER：期望原始型节点", bundle: ModuleBundle.bundle))
        }
        return Array(bytes)
    }

    /// 一个 INTEGER 的原始编码最长这么多字节：8192 位的模数加一个符号 0x00。私钥文件里的整数都不会更长，
    /// 更长的（例如前面塞了几兆字节的零）在做任何处理之前就拒绝。
    static let maximumIntegerLength = SSHRSAPublicKey.maximumModulusBits / 8 + 1

    /// 取 INTEGER 节点的无符号大端幅值（去掉 DER 符号 0x00）。
    static func integerMagnitude(_ node: ASN1Node) throws -> [UInt8] {
        let bytes = try primitiveBytes(node)
        guard bytes.count <= maximumIntegerLength else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "SSH 线格式：整数过长", bundle: ModuleBundle.bundle))
        }
        return SSHWireReader.strippingLeadingZeros(bytes)
    }

    /// 把 OBJECT IDENTIFIER 节点解析为点分字符串。
    static func oidString(_ node: ASN1Node) throws -> String {
        do {
            let oid = try ASN1ObjectIdentifier(derEncoded: node, withIdentifier: .objectIdentifier)
            return oid.description
        } catch {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "DER：OID 解析失败", bundle: ModuleBundle.bundle))
        }
    }

    /// 解析顶层 DER 字节为节点。
    static func parse(_ der: [UInt8]) throws -> ASN1Node {
        do {
            return try DER.parse(der)
        } catch {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "DER 解析失败", bundle: ModuleBundle.bundle))
        }
    }
}

nonisolated extension DERKeyDecoder {

    /// 解析明文 DER。`label` 为 PEM 信封标签（决定结构）。
    static func decode(der: [UInt8], label: String) throws -> ParsedPrivateKey {
        switch label {
        case "RSA PRIVATE KEY":
            return try decodePKCS1RSA(der)
        case "EC PRIVATE KEY":
            return try decodeSEC1EC(der)
        case "PRIVATE KEY":
            return try decodePKCS8(der)
        case "DSA PRIVATE KEY":
            throw PrivateKeyImportError.dsaUnsupported
        default:
            throw PrivateKeyImportError.unsupportedFormat(label: label)
        }
    }

    /// SEC1 ECPrivateKey ::= SEQUENCE {
    ///   version INTEGER, privateKey OCTET STRING,
    ///   parameters [0] EXPLICIT ECParameters OPTIONAL, publicKey [1] EXPLICIT BIT STRING OPTIONAL }
    /// `curveOIDOverride` 用于 PKCS#8 包裹时曲线在外层 AlgorithmIdentifier 的情形。
    ///
    /// - 曲线：命名曲线（`[0]` 里是 OID），或显式曲线参数（`[0]` 里是 SEQUENCE，`openssl ecparam -param_enc explicit`）
    ///   而且 p、a、b、基点、阶逐项与 P-256 / P-384 / P-521 之一相同（`curveOID(parameters:)`）。别的显式参数按不支持
    ///   拒绝：以前按标量长度猜成 NIST 曲线，secp256k1、brainpool 之类的钥匙会被悄悄当成另一条曲线上的钥匙用（指纹与
    ///   `ssh-keygen` 对不上，同一个标量在两条曲线上用）。
    /// - 带了 `[1] publicKey` 时必须与私钥推出来的公钥一致（与 OpenSSH 容器同一条规矩），否则文件可以「显示一个
    ///   指纹、用另一把钥匙认证」。
    /// - 哪里都没有曲线信息时，只在带了公钥、而且它与按标量长度推出的曲线上的公钥一致时才接受。
    static func decodeSEC1EC(_ der: [UInt8], curveOIDOverride: String? = nil) throws -> ParsedPrivateKey {
        let root = try parse(der)
        let fields = try children(root)
        guard fields.count >= 2 else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "SEC1 EC：字段不足", bundle: ModuleBundle.bundle))
        }
        let scalar = try primitiveBytes(fields[1])      // privateKey OCTET STRING

        var namedCurve: String?
        var publicPoint: [UInt8]?
        for node in fields.dropFirst(2) {
            guard node.identifier.tagClass == .contextSpecific, case .constructed(let inner) = node.content,
                  let value = Array(inner).first else { continue }
            switch node.identifier.tagNumber {
            case 0:
                namedCurve = try curveOID(parameters: value)
            case 1:
                guard value.identifier == .bitString, case .primitive(let bits) = value.content,
                      bits.first == 0, bits.count > 1 else {
                    throw PrivateKeyImportError.malformedKey(reason: String(localized: "SEC1 EC：公钥格式不对", bundle: ModuleBundle.bundle))
                }
                publicPoint = Array(bits.dropFirst())
            default:
                continue
            }
        }
        if let curveOIDOverride, let namedCurve, curveOIDOverride != namedCurve {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "SEC1 EC：内外两层的曲线不一致", bundle: ModuleBundle.bundle))
        }
        let key: ParsedPrivateKey
        if let oid = curveOIDOverride ?? namedCurve {
            key = try makeECKey(curveOID: oid, scalar: scalar)
        } else if publicPoint != nil {
            let guessed: String
            switch scalar.count {
            case 32: guessed = OID.p256
            case 48: guessed = OID.p384
            case 66: guessed = OID.p521
            default:
                throw PrivateKeyImportError.malformedKey(reason: String(localized: "SEC1 EC：缺少曲线信息", bundle: ModuleBundle.bundle))
            }
            key = try makeECKey(curveOID: guessed, scalar: scalar)
        } else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "SEC1 EC：缺少曲线信息", bundle: ModuleBundle.bundle))
        }
        if let publicPoint, !key.ecPublicPointEncodings.contains(publicPoint) {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "SEC1 EC：公钥与私钥不是同一把钥匙", bundle: ModuleBundle.bundle))
        }
        return key
    }

    /// EC 参数节点 → 曲线 OID：命名曲线直接取；显式 ECParameters 只在逐项等于某条 NIST 曲线时认成它，否则不支持。
    ///
    /// ECParameters ::= SEQUENCE { version INTEGER, fieldID SEQUENCE { prime-field OID, p INTEGER },
    ///   curve SEQUENCE { a OCTET STRING, b OCTET STRING, seed BIT STRING OPTIONAL }, base OCTET STRING,
    ///   order INTEGER, cofactor INTEGER OPTIONAL }（SEC1 C.2）。种子不比（它只说明参数怎么来的）。
    static func curveOID(parameters node: ASN1Node) throws -> String {
        if node.identifier == .objectIdentifier { return try oidString(node) }
        guard node.identifier == .sequence, let fields = try? children(node), fields.count >= 5,
              let field = try? children(fields[1]), field.count == 2,
              (try? oidString(field[0])) == OID.primeField,
              let curve = try? children(fields[2]), curve.count >= 2,
              let p = try? integerMagnitude(field[1]), let a = try? primitiveBytes(curve[0]),
              let b = try? primitiveBytes(curve[1]), let base = try? primitiveBytes(fields[3]),
              let order = try? integerMagnitude(fields[4]) else {
            throw explicitCurveParameters()
        }
        if fields.count >= 6 {
            guard (try? integerMagnitude(fields[5])) == [1] else { throw explicitCurveParameters() }
        }
        let strip = SSHWireReader.strippingLeadingZeros
        for known in NISTCurve.all where strip(p) == known.p && strip(a) == known.a && strip(b) == known.b
            && strip(order) == known.order && known.baseEncodings.contains(base) {
            return known.oid
        }
        throw explicitCurveParameters()
    }

    /// P-256 / P-384 / P-521 的参数（FIPS 186-4 D.1.2，按 OpenSSL `-param_enc explicit` 的输出核过），去掉前导零。
    struct NISTCurve {
        let oid: String
        let p: [UInt8], a: [UInt8], b: [UInt8], order: [UInt8]
        /// 基点的非压缩与压缩两种编码。
        let baseEncodings: [[UInt8]]

        init(oid: String, p: String, a: String, b: String, base: String, order: String) {
            func bytes(_ hex: String) -> [UInt8] {
                let digits = Array(hex.utf8)
                let raw = stride(from: 0, to: digits.count, by: 2).map {
                    UInt8(String(decoding: digits[$0..<$0 + 2], as: UTF8.self), radix: 16)!
                }
                return SSHWireReader.strippingLeadingZeros(raw)
            }
            self.oid = oid
            self.p = bytes(p); self.a = bytes(a); self.b = bytes(b); self.order = bytes(order)
            let digits = Array(base.utf8)
            let uncompressed = stride(from: 0, to: digits.count, by: 2).map {
                UInt8(String(decoding: digits[$0..<$0 + 2], as: UTF8.self), radix: 16)!
            }
            let width = (uncompressed.count - 1) / 2
            let x = Array(uncompressed[1...width])
            let compressed = [0x02 | (uncompressed.last! & 1)] + x
            baseEncodings = [uncompressed, compressed]
        }

        static let all: [NISTCurve] = [
            NISTCurve(
                oid: OID.p256,
                p: "ffffffff00000001000000000000000000000000ffffffffffffffffffffffff",
                a: "ffffffff00000001000000000000000000000000fffffffffffffffffffffffc",
                b: "5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b",
                base: "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296"
                    + "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5",
                order: "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"),
            NISTCurve(
                oid: OID.p384,
                p: "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffff",
                a: "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000fffffffc",
                b: "b3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088f5013875ac656398d8a2ed19d2a85c8edd3ec2aef",
                base: "04aa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7"
                    + "3617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5f",
                order: "ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973"),
            NISTCurve(
                oid: OID.p521,
                p: "01ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
                    + "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
                a: "01ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
                    + "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc",
                b: "0051953eb9618e1c9a1f929a21a0b68540eea2da725b99b315f3b8b489918ef109"
                    + "e156193951ec7e937b1652c0bd3bb1bf073573df883d2c34f1ef451fd46b503f00",
                base: "0400c6858e06b70404e9cd9e3ecb662395b4429c648139053fb521f828af606b4d3dbaa14b5e77efe75928fe1dc127a2ffa8de3348b3c1856a429bf97e7e31c2e5bd66"
                    + "011839296a789a3bc0045c8a5fb42c7d1bd998f54449579b446817afbd17273e662c97ee72995ef42640c550b9013fad0761353c7086a272c24088be94769fd16650",
                order: "01ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
                    + "fa51868783bf2f966b7fcc0148f709a5d03bb5c9b8899c47aebb6fb71e91386409"),
        ]
    }

    /// 不是 P-256 / P-384 / P-521 的显式曲线参数：不支持。
    static func explicitCurveParameters() -> PrivateKeyImportError {
        .unsupportedFormat(label: String(localized: "EC 显式曲线参数（只支持 P-256 / P-384 / P-521）", bundle: ModuleBundle.bundle))
    }

    /// 按曲线 OID 把原始标量左补零到字段宽度后构造 swift-crypto 密钥。
    static func makeECKey(curveOID: String, scalar: [UInt8]) throws -> ParsedPrivateKey {
        func padded(_ bytes: [UInt8], to width: Int) throws -> [UInt8] {
            guard bytes.count <= maximumIntegerLength else {
                throw PrivateKeyImportError.malformedKey(reason: String(localized: "EC 标量超长", bundle: ModuleBundle.bundle))
            }
            let s = bytes.count > width ? SSHWireReader.strippingLeadingZeros(bytes) : bytes
            guard s.count <= width else {
                throw PrivateKeyImportError.malformedKey(reason: String(localized: "EC 标量超长", bundle: ModuleBundle.bundle))
            }
            return Array(repeating: 0, count: width - s.count) + s
        }
        do {
            switch curveOID {
            case OID.p256:
                return .p256(try P256.Signing.PrivateKey(
                    rawRepresentation: try padded(scalar, to: 32)))
            case OID.p384:
                return .p384(try P384.Signing.PrivateKey(
                    rawRepresentation: try padded(scalar, to: 48)))
            case OID.p521:
                return .p521(try P521.Signing.PrivateKey(
                    rawRepresentation: try padded(scalar, to: 66)))
            default:
                throw PrivateKeyImportError.unsupportedFormat(label: String(localized: "EC 曲线 \(curveOID)", bundle: ModuleBundle.bundle))
            }
        } catch let e as PrivateKeyImportError {
            throw e
        } catch {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "EC 私钥构造失败", bundle: ModuleBundle.bundle))
        }
    }

    /// PKCS#8 PrivateKeyInfo ::= SEQUENCE {
    ///   version INTEGER,
    ///   privateKeyAlgorithm AlgorithmIdentifier,   -- SEQUENCE { OID, params OPTIONAL }
    ///   privateKey OCTET STRING }
    static func decodePKCS8(_ der: [UInt8]) throws -> ParsedPrivateKey {
        let root = try parse(der)
        let fields = try children(root)
        guard fields.count >= 3 else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "PKCS#8：字段不足", bundle: ModuleBundle.bundle))
        }
        let algFields = try children(fields[1])
        guard let algOIDNode = algFields.first else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "PKCS#8：缺少算法标识", bundle: ModuleBundle.bundle))
        }
        let algOID = try oidString(algOIDNode)
        let inner = try primitiveBytes(fields[2])      // privateKey OCTET STRING 内容

        switch algOID {
        case OID.rsaEncryption:
            return try decodePKCS1RSA(inner)            // 内层即 PKCS#1
        case OID.dsa:
            throw PrivateKeyImportError.dsaUnsupported
        case OID.ed25519:
            // inner 本身是一个 DER OCTET STRING，再包 32 字节种子。
            let seedNode = try parse(inner)
            let seed = try primitiveBytes(seedNode)
            guard seed.count == 32 else {
                throw PrivateKeyImportError.malformedKey(reason: String(localized: "Ed25519 种子长度非 32", bundle: ModuleBundle.bundle))
            }
            do {
                return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: seed))
            } catch {
                throw PrivateKeyImportError.malformedKey(reason: String(localized: "Ed25519 私钥构造失败", bundle: ModuleBundle.bundle))
            }
        case OID.ecPublicKey:
            // algFields[1]（EC 参数）：命名曲线 OID，或逐项与某条 NIST 曲线相同的显式 ECParameters。
            var curveOID: String? = nil
            if algFields.count >= 2 {
                curveOID = try Self.curveOID(parameters: algFields[1])
            }
            return try decodeSEC1EC(inner, curveOIDOverride: curveOID)
        default:
            throw PrivateKeyImportError.unsupportedFormat(label: String(localized: "算法 OID \(algOID)", bundle: ModuleBundle.bundle))
        }
    }

    /// PKCS#1 RSAPrivateKey ::= SEQUENCE { version, n, e, d, p, q, dP, dQ, qInv }
    static func decodePKCS1RSA(_ der: [UInt8]) throws -> ParsedPrivateKey {
        return .rsa(try RSAKeyMaterial.makeKey(RSAKeyMaterial.componentsFromPKCS1DER(der)))
    }
}

nonisolated extension ParsedPrivateKey {
    /// EC 私钥对应的公钥点的两种编码（X9.63 非压缩 `04‖X‖Y` 与压缩 `02/03‖X`）；不是 EC 钥匙时为空。
    var ecPublicPointEncodings: [[UInt8]] {
        switch self {
        case .p256(let key):
            return [Array(key.publicKey.x963Representation), Array(key.publicKey.compressedRepresentation)]
        case .p384(let key):
            return [Array(key.publicKey.x963Representation), Array(key.publicKey.compressedRepresentation)]
        case .p521(let key):
            return [Array(key.publicKey.x963Representation), Array(key.publicKey.compressedRepresentation)]
        case .rsa, .ed25519:
            return []
        }
    }
}
