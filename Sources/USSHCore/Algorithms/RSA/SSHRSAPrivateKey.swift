import BigInt
import Crypto
import Foundation
import _CryptoExtras

/// RSA 私钥的分量，全部是大端无符号字节串（允许带前导零）。
///
/// 对应两种导入来源：PKCS#1 `RSAPrivateKey`（n, e, d, p, q, dP, dQ, qInv 九项齐全）与
/// OpenSSH 私钥段（PROTOCOL.key：n, e, d, iqmp, p, q，没有 dP / dQ）。缺的 CRT 值由 d、p、q 算出；
/// 给了就照用，BoringSSL 会核对它们与其余分量一致。
public struct SSHRSAPrivateKeyComponents: Sendable {
    public var modulus: [UInt8]
    public var publicExponent: [UInt8]
    public var privateExponent: [UInt8]
    public var prime1: [UInt8]
    public var prime2: [UInt8]
    /// d mod (p − 1)
    public var exponent1: [UInt8]?
    /// d mod (q − 1)
    public var exponent2: [UInt8]?
    /// q⁻¹ mod p（OpenSSH 的 `iqmp`、PKCS#1 的 `coefficient`）
    public var coefficient: [UInt8]?

    public init(
        modulus: [UInt8],
        publicExponent: [UInt8],
        privateExponent: [UInt8],
        prime1: [UInt8],
        prime2: [UInt8],
        exponent1: [UInt8]? = nil,
        exponent2: [UInt8]? = nil,
        coefficient: [UInt8]? = nil
    ) {
        self.modulus = modulus
        self.publicExponent = publicExponent
        self.privateExponent = privateExponent
        self.prime1 = prime1
        self.prime2 = prime2
        self.exponent1 = exponent1
        self.exponent2 = exponent2
        self.coefficient = coefficient
    }
}

/// RSA 私钥：按 `rsa-sha2-512` / `rsa-sha2-256` / `ssh-rsa` 做 PKCS#1 v1.5 签名，运算交给 swift-crypto
/// 的 `_RSA.Signing`（BoringSSL，带 blinding、恒定时间）。
public struct SSHRSAPrivateKey: Sendable {
    let backing: _RSA.Signing.PrivateKey
    public let publicKey: SSHRSAPublicKey

    /// 由分量构造。模数要在 1024–16384 位之间（低于 2048 位可用但 `publicKey.isWeak` 为真）。
    public init(components: SSHRSAPrivateKeyComponents) throws {
        let p = BigUInt(sshMagnitude: components.prime1)
        let q = BigUInt(sshMagnitude: components.prime2)
        let d = BigUInt(sshMagnitude: components.privateExponent)
        guard p > 1, q > 1, d > 0 else {
            throw SSHRSAError.invalidPrivateKey
        }
        let exponent1 = components.exponent1 ?? (d % (p - 1)).sshMagnitudeBytes
        let exponent2 = components.exponent2 ?? (d % (q - 1)).sshMagnitudeBytes
        let coefficient: [UInt8]
        if let given = components.coefficient {
            coefficient = given
        } else {
            guard let inverse = q.inverse(p) else {
                throw SSHRSAError.invalidPrivateKey
            }
            coefficient = inverse.sshMagnitudeBytes
        }
        // 先核对模数位数，好给出明确的错误（BoringSSL 只会笼统地失败）。
        let publicKey = try SSHRSAPublicKey(modulus: components.modulus, publicExponent: components.publicExponent)

        var der = RSADEREncoding.pkcs1PrivateKey(
            components,
            exponent1: exponent1,
            exponent2: exponent2,
            coefficient: coefficient
        )
        defer { SSHBytes.zeroize(&der) }
        let backing: _RSA.Signing.PrivateKey
        do {
            backing = try _RSA.Signing.PrivateKey(unsafeDERRepresentation: der)
        } catch {
            throw SSHRSAError.invalidPrivateKey
        }
        try self.init(backing: backing, expectedPublicKey: publicKey)
    }

    /// 由 PKCS#1 或 PKCS#8 的 DER 构造（未加密）。
    public init<Bytes: DataProtocol>(derRepresentation: Bytes) throws {
        let backing: _RSA.Signing.PrivateKey
        do {
            backing = try _RSA.Signing.PrivateKey(unsafeDERRepresentation: derRepresentation)
        } catch {
            throw SSHRSAError.invalidPrivateKey
        }
        try self.init(backing: backing, expectedPublicKey: nil)
    }

    /// 由未加密的 PEM（`RSA PRIVATE KEY` 或 `PRIVATE KEY`）构造。
    public init(pemRepresentation: String) throws {
        let backing: _RSA.Signing.PrivateKey
        do {
            backing = try _RSA.Signing.PrivateKey(unsafePEMRepresentation: pemRepresentation)
        } catch {
            throw SSHRSAError.invalidPrivateKey
        }
        try self.init(backing: backing, expectedPublicKey: nil)
    }

    /// 生成新密钥（公钥指数 65537）。只允许 ≥ 2048 位。
    public init(generatingModulusBits bits: Int) throws {
        guard bits >= SSHRSAPublicKey.recommendedMinimumModulusBits, bits <= SSHRSAPublicKey.maximumModulusBits else {
            throw SSHRSAError.unsupportedModulusSize(bits: bits)
        }
        let backing: _RSA.Signing.PrivateKey
        do {
            backing = try _RSA.Signing.PrivateKey(keySize: .init(bitCount: bits))
        } catch {
            throw SSHRSAError.invalidPrivateKey
        }
        try self.init(backing: backing, expectedPublicKey: nil)
    }

    private init(backing: _RSA.Signing.PrivateKey, expectedPublicKey: SSHRSAPublicKey?) throws {
        let primitives: _RSA.Signing.PublicKey.Primitives
        do {
            primitives = try backing.publicKey.getKeyPrimitives()
        } catch {
            throw SSHRSAError.invalidPrivateKey
        }
        let publicKey = try SSHRSAPublicKey(modulus: primitives.modulus, publicExponent: primitives.publicExponent)
        if let expectedPublicKey, expectedPublicKey != publicKey {
            throw SSHRSAError.invalidPrivateKey
        }
        self.backing = backing
        self.publicKey = publicKey
    }

    /// 用 `algorithm` 对 `data` 签名（先按算法取摘要，再 PKCS#1 v1.5）。签名长度恒等于模数字节数。
    public func signature<D: DataProtocol>(for data: D, algorithm: SSHRSASignatureAlgorithm) throws -> SSHRSASignature {
        // PKCS#1 v1.5 是 RFC 8332 规定的填充；_CryptoExtras 把它叫 "insecure" 是为了劝能用 PSS 的场合，
        // 对 SSH 而言就是正确的选择。
        let raw: _RSA.Signing.RSASignature
        do {
            switch algorithm {
            case .rsaSHA2_512:
                raw = try self.backing.signature(for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5)
            case .rsaSHA2_256:
                raw = try self.backing.signature(for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5)
            case .sshRSA:
                raw = try self.backing.signature(for: Insecure.SHA1.hash(data: data), padding: .insecurePKCS1v1_5)
            }
        } catch {
            throw SSHRSAError.signingFailed
        }
        let bytes = Array(raw.rawRepresentation)
        // BoringSSL 输出总是模数长度；万一短了按 RFC 8332 补齐（服务端可能严格要求等长）。
        guard let padded = SSHBytes.leftPadded(bytes, to: self.publicKey.modulusByteCount) else {
            throw SSHRSAError.signingFailed
        }
        return SSHRSASignature(algorithm: algorithm, bytes: padded)
    }
}
