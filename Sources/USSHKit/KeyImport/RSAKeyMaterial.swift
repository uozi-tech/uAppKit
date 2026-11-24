import BigInt
import Foundation
import USSHCore

/// RSA 私钥从各种落盘格式走到 USSHCore 的 `SSHRSAPrivateKey` 的那一段：抽分量、补素因子、构造并报错。
nonisolated enum RSAKeyMaterial {

    /// 从 PKCS#1 `RSAPrivateKey` DER（SEQUENCE { version, n, e, d, p, q, dP, dQ, qInv }）抽取分量。
    ///
    /// 只取 n / e / d / p / q，CRT 值交给 USSHCore 现算——和迁移前（`_RSA.Signing.PrivateKey(n:e:d:p:q:)`）
    /// 一样只认这五项，文件里 CRT 值写错的密钥照旧能用。
    static func componentsFromPKCS1DER(_ der: [UInt8]) throws -> SSHRSAPrivateKeyComponents {
        let root = try DERKeyDecoder.parse(der)
        let fields = try DERKeyDecoder.children(root)
        guard fields.count >= 9 else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "PKCS#1 RSA：字段不足（需 9）", bundle: ModuleBundle.bundle))
        }
        return SSHRSAPrivateKeyComponents(
            modulus: try DERKeyDecoder.integerMagnitude(fields[1]),
            publicExponent: try DERKeyDecoder.integerMagnitude(fields[2]),
            privateExponent: try DERKeyDecoder.integerMagnitude(fields[3]),
            prime1: try DERKeyDecoder.integerMagnitude(fields[4]),
            prime2: try DERKeyDecoder.integerMagnitude(fields[5]))
    }

    /// 由分量构造私钥。分量的毛病一律报成 `.malformedKey`（文案与迁移前相同）。
    static func makeKey(_ components: SSHRSAPrivateKeyComponents) throws -> SSHRSAPrivateKey {
        do {
            return try SSHRSAPrivateKey(components: components)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            throw PrivateKeyImportError.malformedKey(
                reason: String(localized: "RSA 私钥构造失败：\(detail)", bundle: ModuleBundle.bundle))
        }
    }

    /// 只有 n / e / d、缺 p / q 时由它们还原两个素因子（NIST SP 800-56B Rev. 2 附录 C.2 的概率算法）。
    ///
    /// 迁移前这种 OpenSSH 容器由 Citadel 只凭 n / e / d 接下来、以 `ssh-rsa`（SHA-1）签名；现在还原出 p / q，
    /// 和别的 RSA 私钥走同一条 SHA-2 的路。还原不出来（分量互相不一致）返回 nil。
    static func recoverPrimes(modulus: [UInt8], publicExponent: [UInt8],
                              privateExponent: [UInt8]) -> (p: [UInt8], q: [UInt8])? {
        let n = BigUInt(Data(modulus))
        let e = BigUInt(Data(publicExponent))
        let d = BigUInt(Data(privateExponent))
        guard n > 3, e > 1, d > 1, n % 2 == 1 else { return nil }
        // k = d·e − 1 = 2^t · r，r 为奇数。
        let k = d * e - 1
        guard k > 0, k % 2 == 0 else { return nil }
        var r = k
        var t = 0
        while r % 2 == 0 {
            r /= 2
            t += 1
        }
        let one = BigUInt(1)
        let nMinusOne = n - 1
        // 先花一次模幂核对 (2^e)^d ≡ 2 (mod n)：分量对不上的话下面每次尝试都白算（文件不可信，
        // 不能让一个坏文件把导入拖上几十秒）。
        guard BigUInt(2).power(e, modulus: n).power(d, modulus: n) == 2 else { return nil }
        // 分量一致时每个底数至少有一半的概率分解成功，40 次都失败的概率不到 2^-40。
        for attempt in 0..<40 {
            let g = attempt < 8
                ? BigUInt([2, 3, 5, 7, 11, 13, 17, 19][attempt])
                : BigUInt.randomInteger(lessThan: n - 3) + 2
            var y = g.power(r, modulus: n)
            // y == 0 只在底数与 n 有公因子时出现（分量不对），BigUInt 减到负数会 trap，先排除。
            guard y != 0, y != one, y != nMinusOne else { continue }
            for _ in 0..<t {
                let x = y.power(2, modulus: n)
                if x == one {
                    let p = (y - 1).greatestCommonDivisor(with: n)
                    guard p > one, p < n else { break }
                    let q = n / p
                    guard p * q == n else { break }
                    return (Array(p.serialize()), Array(q.serialize()))
                }
                if x == nMinusOne || x == 0 { break }
                y = x
            }
        }
        return nil
    }
}
