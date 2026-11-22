import Foundation

/// 私钥导入失败原因。`Equatable` 只比较 case，不比较关联文本（便于测试）。
public nonisolated enum PrivateKeyImportError: Error, LocalizedError, Equatable {
    case malformedPEM(reason: String)
    case unsupportedFormat(label: String)
    case dsaUnsupported
    case encryptedKeyNeedsPassphrase
    case incorrectPassphrase
    case unsupportedCipher(name: String)
    case unsupportedKDF(name: String)
    case malformedKey(reason: String)

    public var errorDescription: String? {
        switch self {
        case .malformedPEM(let reason):
            return String(localized: "私钥内容无法识别：\(reason)", bundle: ModuleBundle.bundle)
        case .unsupportedFormat(let label):
            return String(localized: "不支持的私钥格式（\(label)）：仅支持 RSA / Ed25519 / ECDSA 私钥", bundle: ModuleBundle.bundle)
        case .dsaUnsupported:
            return String(localized: "DSA 私钥不受支持，请改用 RSA / Ed25519 / ECDSA 密钥", bundle: ModuleBundle.bundle)
        case .encryptedKeyNeedsPassphrase:
            return String(localized: "私钥已加密，请填写密钥口令", bundle: ModuleBundle.bundle)
        case .incorrectPassphrase:
            return String(localized: "私钥口令错误，无法解密", bundle: ModuleBundle.bundle)
        case .unsupportedCipher(let name):
            return String(localized: "不支持的私钥加密算法：\(name)", bundle: ModuleBundle.bundle)
        case .unsupportedKDF(let name):
            return String(localized: "不支持的私钥密钥派生算法：\(name)", bundle: ModuleBundle.bundle)
        case .malformedKey(let reason):
            return String(localized: "私钥结构损坏：\(reason)", bundle: ModuleBundle.bundle)
        }
    }

    public var failureReason: String? {
        switch self {
        case .malformedPEM:
            return String(localized: "文件不是可识别的 PEM 私钥，或 BEGIN/END 标记不完整。", bundle: ModuleBundle.bundle)
        case .unsupportedFormat(let label):
            return String(localized: "检测到 \(label)，当前只支持 RSA / Ed25519 / ECDSA 私钥。", bundle: ModuleBundle.bundle)
        case .dsaUnsupported:
            return String(localized: "DSA 已不再作为受支持的 SSH 私钥算法。", bundle: ModuleBundle.bundle)
        case .encryptedKeyNeedsPassphrase:
            return String(localized: "该私钥受口令保护，导入前需要先解密。", bundle: ModuleBundle.bundle)
        case .incorrectPassphrase:
            return String(localized: "输入的私钥口令无法解密此文件。", bundle: ModuleBundle.bundle)
        case .unsupportedCipher(let name):
            return String(localized: "加密算法 \(name) 当前未实现。", bundle: ModuleBundle.bundle)
        case .unsupportedKDF(let name):
            return String(localized: "密钥派生算法 \(name) 当前未实现。", bundle: ModuleBundle.bundle)
        case .malformedKey:
            return String(localized: "文件结构损坏，或内容与声明的私钥算法不匹配。", bundle: ModuleBundle.bundle)
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .malformedPEM:
            return String(localized: "请选择私钥文件（如 id_ed25519、id_rsa），不要选择 .pub 公钥；确认文件以 -----BEGIN ... PRIVATE KEY----- 开头，且一次只导入一把私钥。", bundle: ModuleBundle.bundle)
        case .unsupportedFormat:
            return String(localized: "如果这是公钥或证书，请改选对应私钥；如为 PuTTY .ppk，请先转换为 OpenSSH/PEM 格式。", bundle: ModuleBundle.bundle)
        case .dsaUnsupported:
            return String(localized: "请重新生成 Ed25519、RSA 或 ECDSA 密钥，并在服务器上换用新公钥。", bundle: ModuleBundle.bundle)
        case .encryptedKeyNeedsPassphrase:
            return String(localized: "请输入创建该私钥时设置的 passphrase；这不是服务器登录密码。", bundle: ModuleBundle.bundle)
        case .incorrectPassphrase:
            return String(localized: "请检查大小写和输入法，或在终端用 ssh-keygen -y -f <key> 验证口令。", bundle: ModuleBundle.bundle)
        case .unsupportedCipher:
            return String(localized: "请用 ssh-keygen 重新导出为常见 OpenSSH/PEM 格式后再导入。", bundle: ModuleBundle.bundle)
        case .unsupportedKDF:
            return String(localized: "请改用 PBES2/PBKDF2 等常见 PEM 加密格式，或重新导出为 OpenSSH 私钥后再导入。", bundle: ModuleBundle.bundle)
        case .malformedKey:
            return String(localized: "请确认文件未被截断、复制时没有丢行；也不要粘贴 .pub 公钥内容。", bundle: ModuleBundle.bundle)
        }
    }

    public nonisolated static func == (lhs: PrivateKeyImportError, rhs: PrivateKeyImportError) -> Bool {
        switch (lhs, rhs) {
        case (.malformedPEM, .malformedPEM), (.unsupportedFormat, .unsupportedFormat),
             (.dsaUnsupported, .dsaUnsupported),
             (.encryptedKeyNeedsPassphrase, .encryptedKeyNeedsPassphrase),
             (.incorrectPassphrase, .incorrectPassphrase),
             (.unsupportedCipher, .unsupportedCipher),
             (.unsupportedKDF, .unsupportedKDF), (.malformedKey, .malformedKey):
            return true
        default:
            return false
        }
    }
}
