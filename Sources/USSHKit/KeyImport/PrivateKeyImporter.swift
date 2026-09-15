import Foundation
import Crypto
@preconcurrency import Citadel

/// 私钥导入编排器：把任意受支持格式的私钥文本解析为 `ParsedPrivateKey`。
nonisolated enum PrivateKeyImporter {

    static func resolve(pem rawText: String, passphrase: String?) throws -> ParsedPrivateKey {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let label = firstPEMLabel(in: text) else {
            throw PrivateKeyImportError.malformedPEM(reason: "未找到 -----BEGIN ...----- 标记")
        }

        switch label {
        case "OPENSSH PRIVATE KEY":
            return try resolveOpenSSH(text: text, passphrase: passphrase)
        case "DSA PRIVATE KEY":
            throw PrivateKeyImportError.dsaUnsupported
        case "RSA PRIVATE KEY", "EC PRIVATE KEY", "PRIVATE KEY", "ENCRYPTED PRIVATE KEY":
            return try resolvePEM(text: text, passphrase: passphrase)
        default:
            throw PrivateKeyImportError.unsupportedFormat(label: label)
        }
    }

    /// OpenSSH 容器：RSA 自解（见下，带口令的也在这一层解密），Ed25519 交给 Citadel，
    /// ECDSA 由 OpenSSHECDSADecoder 处理。
    private static func resolveOpenSSH(text: String, passphrase: String?) throws -> ParsedPrivateKey {
        let decryptionKey = passphrase?.data(using: .utf8)
        let keyType: SSHKeyType
        do {
            keyType = try SSHKeyDetection.detectPrivateKeyType(from: text)
        } catch {
            throw PrivateKeyImportError.malformedKey(reason: "无法识别 OpenSSH 私钥类型")
        }
        switch keyType {
        case .rsa:
            // 先自己读容器：拿到 n/e/d/p/q 就能走 rsa-sha2-512（`RSASHA512AuthDelegate`）。
            // 交给 Citadel 只能得到 ssh-rsa（SHA-1）签名，OpenSSH 8.8+ 服务端默认拒收，
            // 认证以 allAuthenticationOptionsFailed 失败 —— 同一把密钥 `ssh` 却连得上。
            // 带口令的容器同样走这条路（bcrypt_pbkdf + aes-ctr 就地解密）。
            do {
                return .rsa(try OpenSSHRSADecoder.decodeComponents(
                    openSSHText: text, passphrase: passphrase))
            } catch let error as PrivateKeyImportError where isConclusive(error) {
                throw error
            } catch {
                // 只剩「容器结构我们读不动」这类意外。回退老路：老路至少能在仍接受
                // SHA-1 的服务端上连上，好过直接失败。
                do {
                    return .legacyOpenSSHRSA(try Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: decryptionKey))
                } catch { throw mapCitadelKeyError(error) }
            }
        case .ed25519:
            do {
                return .ed25519(try Curve25519.Signing.PrivateKey(
                    sshEd25519: text, decryptionKey: decryptionKey))
            } catch { throw mapCitadelKeyError(error) }
        default:
            switch keyType {
            case .ecdsaP256, .ecdsaP384, .ecdsaP521:
                return try OpenSSHECDSADecoder.decode(openSSHText: text)
            default:
                throw PrivateKeyImportError.unsupportedFormat(label: "OPENSSH \(keyType)")
            }
        }
    }

    /// PEM 信封：解析 -> 解密 -> DER 解码。
    private static func resolvePEM(text: String, passphrase: String?) throws -> ParsedPrivateKey {
        let doc = try PEMDocument.parse(text)
        let der = try PEMDecryptor.decryptedDER(from: doc, passphrase: passphrase)
        // PKCS#8 加密解密后是 PrivateKeyInfo，归一化标签为 "PRIVATE KEY"。
        let label = (doc.label == "ENCRYPTED PRIVATE KEY") ? "PRIVATE KEY" : doc.label
        return try DERKeyDecoder.decode(der: der, label: label)
    }

    /// 这些失败已经定性，回退 Citadel 只会把准确提示换成更差的 —— 口令错在老路上
    /// 表现为 checkint 不一致，映射出来是 `.malformedKey`（「私钥结构损坏」），
    /// 与真实原因南辕北辙。所以直接抛出去，不回退。
    private static func isConclusive(_ error: PrivateKeyImportError) -> Bool {
        switch error {
        case .encryptedKeyNeedsPassphrase, .incorrectPassphrase,
             .unsupportedCipher, .unsupportedKDF:
            return true
        default:
            return false
        }
    }

    /// Citadel 解析私钥抛错时映射到本模块错误（口令相关给出更准确的提示）。
    private static func mapCitadelKeyError(_ error: Error) -> PrivateKeyImportError {
        let text = (error.localizedDescription + "\(error)").lowercased()
        if text.contains("missingdecryptionkey") {
            return .encryptedKeyNeedsPassphrase
        }
        if text.contains("passphrase") || text.contains("decrypt") || text.contains("bcrypt") {
            return .incorrectPassphrase
        }
        return .malformedKey(reason: error.localizedDescription)
    }

    /// 取首个 `-----BEGIN <label>-----` 中的 label。
    private static func firstPEMLabel(in text: String) -> String? {
        guard let begin = text.range(of: "-----BEGIN ") else { return nil }
        let rest = text[begin.upperBound...]
        guard let end = rest.range(of: "-----") else { return nil }
        return String(rest[..<end.lowerBound])
    }
}
