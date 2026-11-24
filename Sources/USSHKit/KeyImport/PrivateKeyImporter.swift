import Foundation

/// 私钥导入编排器：把任意受支持格式的私钥文本解析为 `ParsedPrivateKey`。
nonisolated enum PrivateKeyImporter {

    static func resolve(pem rawText: String, passphrase: String?) throws -> ParsedPrivateKey {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let label = firstPEMLabel(in: text) else {
            throw PrivateKeyImportError.malformedPEM(reason: String(localized: "未找到 -----BEGIN ...----- 标记", bundle: ModuleBundle.bundle))
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

    /// OpenSSH 容器：按公钥段声明的类型分给各解码器。带口令的容器在 `OpenSSHContainer` 里就地解密
    /// （bcrypt_pbkdf + aes-ctr）；ECDSA 的加密容器仍按「不支持」拒绝（迁移前就是这样，放开是产品决定）。
    private static func resolveOpenSSH(text: String, passphrase: String?) throws -> ParsedPrivateKey {
        let keyType: String
        do {
            keyType = try OpenSSHContainer.publicKeyType(text: text)
        } catch {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "无法识别 OpenSSH 私钥类型", bundle: ModuleBundle.bundle))
        }
        switch keyType {
        case "ssh-rsa":
            return try OpenSSHRSADecoder.decode(openSSHText: text, passphrase: passphrase)
        case "ssh-ed25519":
            return try OpenSSHEd25519Decoder.decode(openSSHText: text, passphrase: passphrase)
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            return try OpenSSHECDSADecoder.decode(openSSHText: text)
        case "ssh-dss":
            throw PrivateKeyImportError.dsaUnsupported
        default:
            throw PrivateKeyImportError.unsupportedFormat(label: "OPENSSH \(keyType)")
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

    /// 取首个 `-----BEGIN <label>-----` 中的 label。
    private static func firstPEMLabel(in text: String) -> String? {
        guard let begin = text.range(of: "-----BEGIN ") else { return nil }
        let rest = text[begin.upperBound...]
        guard let end = rest.range(of: "-----") else { return nil }
        return String(rest[..<end.lowerBound])
    }
}
