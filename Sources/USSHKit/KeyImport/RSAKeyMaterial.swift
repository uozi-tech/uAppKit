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

    /// 由分量构造私钥。分量的毛病一律报成 `.malformedKey`（文案与迁移前相同）。先过 `validate`：文件不可信，
    /// 大数运算之前先把尺寸卡住。
    static func makeKey(_ components: SSHRSAPrivateKeyComponents) throws -> SSHRSAPrivateKey {
        try validate(modulus: components.modulus, publicExponent: components.publicExponent,
                     privateExponent: components.privateExponent,
                     primes: (components.prime1, components.prime2))
        do {
            return try SSHRSAPrivateKey(components: components)
        } catch {
            throw malformed(error)
        }
    }

    /// 公钥指数最多这么多位：BoringSSL 自己的上限（`kMaxExponentBits`，33 位）。实际的钥匙都是 65537（17 位）。
    static let maximumPublicExponentBits = 33

    /// 任何大数运算之前的尺寸与范围检查（只做字节长度、比较与一次乘法，最坏也就几微秒）：
    /// - n 的位数在 USSHCore 支持的范围内（1024–8192），且是奇数；
    /// - 1 < e < n，e 不超过 `maximumPublicExponentBits` 位，且是奇数；
    /// - 1 < d < n；
    /// - 给了素因子时 1 < p, q < n 且 p·q = n。
    ///
    /// 没有这一步时，一个 n / d 有几兆位、素因子留空的容器会让 `recoverPrimes` 的模幂跑上很久——每次连接都会
    /// 重新导入一遍私钥，等于每次连接都卡住。
    static func validate(modulus: [UInt8], publicExponent: [UInt8], privateExponent: [UInt8],
                         primes: (p: [UInt8], q: [UInt8])?) throws {
        // 位数与 e 的形状交给 USSHCore 的公钥构造（只看字节长度与奇偶，再由 BoringSSL 装一次公钥），
        // 位数不对时报的是「RSA 密钥长度 … 位不受支持」。
        do {
            _ = try SSHRSAPublicKey(modulus: modulus, publicExponent: publicExponent)
        } catch {
            throw malformed(error)
        }
        guard bitCount(publicExponent) <= maximumPublicExponentBits else { throw componentsOutOfRange() }
        let n = BigUInt(Data(modulus))
        let e = BigUInt(Data(publicExponent))
        let d = BigUInt(Data(privateExponent))
        guard e > 1, e < n, d > 1, d < n else { throw componentsOutOfRange() }
        if let (pBytes, qBytes) = primes, !pBytes.isEmpty, !qBytes.isEmpty {
            // 先比长度再做乘法：两个都不超过 n 的字节数，乘积最多 2×8192 位。
            guard bitCount(pBytes) + bitCount(qBytes) <= bitCount(modulus) + 1 else { throw componentsOutOfRange() }
            let p = BigUInt(Data(pBytes)), q = BigUInt(Data(qBytes))
            guard p > 1, q > 1, p < n, q < n, p * q == n else { throw componentsOutOfRange() }
        }
    }

    /// 大端字节串的有效位数（忽略前导零）。
    static func bitCount(_ bytes: [UInt8]) -> Int {
        guard let first = bytes.firstIndex(where: { $0 != 0 }) else { return 0 }
        return (bytes.count - first - 1) * 8 + (8 - bytes[first].leadingZeroBitCount)
    }

    private static func componentsOutOfRange() -> PrivateKeyImportError {
        .malformedKey(reason: String(localized: "RSA 私钥分量超出范围或互相不一致", bundle: ModuleBundle.bundle))
    }

    private static func malformed(_ error: any Error) -> PrivateKeyImportError {
        if let error = error as? PrivateKeyImportError { return error }
        let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return .malformedKey(reason: String(localized: "RSA 私钥构造失败：\(detail)", bundle: ModuleBundle.bundle))
    }

    /// 只有 n / e / d、缺 p / q 时由它们还原两个素因子。
    ///
    /// 迁移前这种 OpenSSH 容器由 Citadel 只凭 n / e / d 接下来、以 `ssh-rsa`（SHA-1）签名；现在还原出 p / q，
    /// 和别的 RSA 私钥走同一条 SHA-2 的路。还原不出来（分量互相不一致）返回 nil；分量尺寸不对抛 `.malformedKey`
    /// （先过 `validate`，再做任何大数运算）。
    ///
    /// 不用 NIST SP 800-56B 附录 C 的概率算法：它要做与 n 同长的指数的模幂，BigInt 在 Debug 构建里 8192 位要
    /// 两三分钟（Release 也要秒级），而且每次连接都会重新导入一遍。这里只做乘除与一次开方（毫秒级）：
    ///
    /// e·d − 1 = k 是 λ(n) 的倍数，λ(n) = φ(n) / g，g = gcd(p − 1, q − 1)。所以对某个小的 g，k·g = m·φ(n)。
    /// φ(n) = n − (p + q) + 1 只比 n 小一点（差不到 2^(位数/2 + 2)），而 e 最多 33 位，于是 m 只能是
    /// ⌊k·g / n⌋ + 1（或 ⌊k·g / n⌋）。由 φ 得 s = p + q，再由 s² − 4n 是完全平方数解出 p、q，最后核对 p·q = n。
    /// 私钥指数按 φ 算的 g 取 1，按 λ 算的（OpenSSL 1.1 起）g 就是 gcd(p − 1, q − 1)，实际的钥匙都很小；
    /// 枚举到 `maximumTotientCofactor` 为止，枚举不到就当分量不一致。
    ///
    /// 代价：每个 g 一次乘法、两次除法（被除数 ~8200 位、除数很短），几千次加起来是毫秒级。开方贵（与 n 同长），
    /// 只给通过了余数检查、落在范围内、**没被拒过**（构造出来的 e = 3、d = (2n − 2s + 1) / 3 会让每个 g 都给出同一个
    /// φ）、而且判别式模 64 / 63 / 65 / 11 都是平方剩余（非平方数一千个里只漏过六个左右）的候选。
    /// 实测（Debug，M5 Pro，8192 位）：上面那种构造（s ≈ 2√n，判别式非负）以前每个 g 都开方，24.8 秒；现在 1.4 秒，
    /// 随机垃圾 1.0 秒，都花在枚举的除法上；合法的钥匙 0.09 秒。Release 快一个数量级。
    static func recoverPrimes(modulus: [UInt8], publicExponent: [UInt8],
                              privateExponent: [UInt8]) throws -> (p: [UInt8], q: [UInt8])? {
        try validate(modulus: modulus, publicExponent: publicExponent, privateExponent: privateExponent, primes: nil)
        let n = BigUInt(Data(modulus))
        let e = BigUInt(Data(publicExponent))
        let d = BigUInt(Data(privateExponent))
        let k = e * d - 1
        // φ(n) > n − 2^(⌈位数/2⌉ + 2)：p + q < 2·2^⌈位数/2⌉。
        let slack = BigUInt(1) << (n.bitWidth / 2 + 2)
        guard n > slack else { return nil }
        let lowestTotient = n - slack
        let four = BigUInt(4)
        var rejected = Set<BigUInt>()
        for g in 1...maximumTotientCofactor {
            let kg = k * BigUInt(g)
            let estimate = kg / n
            for m in [estimate + 1, estimate] where m > 0 {
                let (totient, remainder) = kg.quotientAndRemainder(dividingBy: m)
                guard remainder == 0, totient < n, totient > lowestTotient, !rejected.contains(totient) else { continue }
                let sum = n - totient + 1                      // p + q
                let square = sum * sum
                guard square > four * n else {
                    rejected.insert(totient)
                    continue
                }
                let discriminant = square - four * n           // (p − q)²
                guard mayBeSquare(discriminant) else {
                    rejected.insert(totient)
                    continue
                }
                let root = discriminant.squareRoot()
                guard root * root == discriminant, (sum + root) % 2 == 0 else {
                    rejected.insert(totient)
                    continue
                }
                let p = (sum + root) / 2
                let q = (sum - root) / 2
                guard q > 1, p * q == n else { continue }
                return (Array(p.serialize()), Array(q.serialize()))
            }
        }
        return nil
    }

    /// `recoverPrimes` 枚举 gcd(p − 1, q − 1) 的上限。它总是偶数；按 λ 算私钥指数的钥匙里超过 4096 的大约是
    /// 万分之二到万分之五（量级，样本不大）。只影响**缺素因子**的容器——OpenSSH 与 PuTTYgen 写的都带素因子——
    /// 这样的钥匙导入会失败（用 `ssh-keygen -p` 重新存一次就会写上素因子）。
    static let maximumTotientCofactor = 4096

    /// 模 64 / 63 / 65 / 11 的平方剩余表：不在表里的一定不是完全平方数（开方之前的廉价筛子）。
    private static let squareResidues: [(modulus: UInt, residues: Set<UInt>)] = [64, 63, 65, 11].map { m in
        (UInt(m), Set((0..<UInt(m)).map { $0 * $0 % UInt(m) }))
    }

    static func mayBeSquare(_ value: BigUInt) -> Bool {
        squareResidues.allSatisfy { table in
            table.residues.contains(UInt(value % BigUInt(table.modulus)))
        }
    }
}
