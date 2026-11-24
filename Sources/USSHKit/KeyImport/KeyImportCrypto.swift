import Foundation
import Crypto
import CommonCrypto

/// 私钥导入用到的对称密码学，基于 macOS 系统模块 CommonCrypto。
nonisolated enum KeyImportCrypto {

    nonisolated enum BlockCipher {
        case aes, tripleDES, des
        var blockSize: Int { self == .aes ? 16 : 8 }
        var ccAlgorithm: CCAlgorithm {
            switch self {
            case .aes:       return CCAlgorithm(kCCAlgorithmAES)
            case .tripleDES: return CCAlgorithm(kCCAlgorithm3DES)
            case .des:       return CCAlgorithm(kCCAlgorithmDES)
            }
        }
    }

    nonisolated enum PRF {
        case sha1, sha224, sha256, sha384, sha512
        var ccPRF: CCPseudoRandomAlgorithm {
            switch self {
            case .sha1:   return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
            case .sha224: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA224)
            case .sha256: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
            case .sha384: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384)
            case .sha512: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
            }
        }
    }

    /// PBKDF2 派生出的密钥长度上限（字节）。最大支持的对称密钥为 AES-256（32 字节），
    /// 这里留足余量即可。用于在以 keyLength 分配缓冲前拦下不可信的超大长度，
    /// 防止 ~4GB 量级的内存分配。
    static let maxDerivedKeyLength = 1024

    /// PBKDF2 迭代次数上限：200 万。迭代次数读自密钥文件（不可信），而每次连接都会重新解一遍私钥。
    /// 实测（2026-11，M5 Pro，CommonCrypto）1000 万次：SHA-1 2.6 秒、SHA-256 1.1 秒、SHA-512 3.2 秒，手机慢一倍左右；
    /// 200 万次最坏约 0.6 秒。真实工具写的：OpenSSL `pkcs8` 默认 2048，OWASP 2023 的建议是 SHA-512 21 万、
    /// SHA-256 60 万、SHA-1 130 万，都在上限以内。超过的报 `.unsupportedKDFCost`（与 bcrypt 同一种错误）。
    static let maxPBKDF2Iterations = 2_000_000

    /// PBKDF2。
    static func pbkdf2(password: [UInt8], salt: [UInt8],
                       iterations: Int, keyLength: Int, prf: PRF) throws -> [UInt8] {
        // keyLength 可能源自不可信密钥文件；分配缓冲前先夹紧到合理上限。
        guard keyLength > 0, keyLength <= maxDerivedKeyLength else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "派生密钥长度非法", bundle: ModuleBundle.bundle))
        }
        var derived = [UInt8](repeating: 0, count: keyLength)
        // CCKeyDerivationPBKDF 的 password 参数类型为 `const char *`（UnsafePointer<Int8>）。
        // 使用 withUnsafeBytes 将 UInt8 数组转换为 Int8 指针。
        // 密码为空时 baseAddress 可能为 nil，因此预备一个哑元数组。
        let pwd = password.isEmpty ? [UInt8(0)] : password
        _ = derived.withUnsafeMutableBufferPointer { out in
            pwd.withUnsafeBytes { pwdRaw in
                salt.withUnsafeBufferPointer { s in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwdRaw.baseAddress!.assumingMemoryBound(to: Int8.self),
                        password.count,
                        s.baseAddress, salt.count,
                        prf.ccPRF, UInt32(iterations),
                        out.baseAddress, keyLength)
                }
            }
        }
        return derived
    }

    /// OpenSSL EVP_BytesToKey（MD5；無 IV 派生，IV 來自 DEK-Info）。
    static func evpBytesToKey(password: [UInt8], salt: [UInt8], keyLength: Int) -> [UInt8] {
        var derived: [UInt8] = []
        var block: [UInt8] = []
        while derived.count < keyLength {
            var input = block
            input.append(contentsOf: password)
            input.append(contentsOf: salt)
            block = Array(Insecure.MD5.hash(data: Data(input)))
            derived.append(contentsOf: block)
        }
        return Array(derived.prefix(keyLength))
    }

    /// CBC 加/解密，無填充處理（調用方負責 PKCS#7）。
    static func cbcCrypt(_ cipher: BlockCipher, encrypt: Bool,
                         key: [UInt8], iv: [UInt8], input: [UInt8]) throws -> [UInt8] {
        // CCCrypt 按 blockSize 读取 IV；IV 来自不可信密钥文件，必须先校验长度，
        // 否则短 IV（如 DEK-Info "AES-128-CBC,01" 的 1 字节 IV）会触发堆越界读。
        guard iv.count == cipher.blockSize else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "IV 长度与块大小不符", bundle: ModuleBundle.bundle))
        }
        guard input.count % cipher.blockSize == 0, !input.isEmpty else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "密文长度不是块大小的整数倍", bundle: ModuleBundle.bundle))
        }
        var output = [UInt8](repeating: 0, count: input.count + cipher.blockSize)
        var moved = 0
        let status = key.withUnsafeBufferPointer { k in
            iv.withUnsafeBufferPointer { ivp in
                input.withUnsafeBufferPointer { inp in
                    output.withUnsafeMutableBufferPointer { outp in
                        CCCrypt(
                            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                            cipher.ccAlgorithm,
                            CCOptions(0),                       // 無填充
                            k.baseAddress, key.count,
                            ivp.baseAddress,
                            inp.baseAddress, input.count,
                            outp.baseAddress, outp.count,
                            &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "CBC 运算失败（\(String(status))）", bundle: ModuleBundle.bundle))
        }
        return Array(output.prefix(moved))
    }

    /// 校驗並剝離 PKCS#7 填充；非法填充視為口令錯誤。
    static func stripPKCS7(_ data: [UInt8], blockSize: Int) throws -> [UInt8] {
        guard let pad = data.last, pad >= 1, Int(pad) <= blockSize,
              data.count >= Int(pad),
              data.suffix(Int(pad)).allSatisfy({ $0 == pad }) else {
            throw PrivateKeyImportError.incorrectPassphrase
        }
        return Array(data.prefix(data.count - Int(pad)))
    }
}
