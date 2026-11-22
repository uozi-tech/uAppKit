import Foundation

/// OpenSSH 新格式私钥容器（`-----BEGIN OPENSSH PRIVATE KEY-----`，内层 magic
/// `openssh-key-v1\0`）的外层解析：走到私钥段、读掉算法标识，剩下的分量交给各算法
/// 解码器自己读。
///
/// 带口令的容器（`ciphername != "none"`）在这里现场解密，解密实现见
/// `OpenSSHKeyDecryption`。不给口令时不解密，只把 ciphername 原样报出去，由调用方
/// 决定报错措辞。
nonisolated enum OpenSSHContainer {

    /// 私钥段的打开结果。
    enum PrivateSection {
        /// 已就绪（未加密，或已用口令解开）。`keyType` 是私钥段里声明的算法
        /// （`ssh-rsa` / `ecdsa-sha2-nistp256` …），`body` 停在该算法的分量之前。
        case plaintext(keyType: String, body: SSHWireReader)
        /// 已加密（ciphername != "none"）且调用方没给口令。
        case encrypted(cipherName: String)
    }

    /// - Parameter passphrase: 容器带口令时用它解密；传 `nil` 表示不解密，加密容器直接
    ///   返回 `.encrypted`。
    static func openPrivateSection(text: String,
                                   passphrase: String? = nil) throws -> PrivateSection {
        let der = try extractBase64Body(text)

        // AUTH_MAGIC "openssh-key-v1\0"（16 字节，含 NUL）
        let magic = Array("openssh-key-v1\u{0}".utf8)
        guard der.count >= magic.count, Array(der.prefix(magic.count)) == magic else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "OpenSSH：缺少 magic", bundle: .module))
        }
        var reader = SSHWireReader(Array(der.dropFirst(magic.count)))

        let cipherName = String(decoding: try reader.readString(), as: UTF8.self)
        let kdfName = String(decoding: try reader.readString(), as: UTF8.self)
        let kdfOptions = try reader.readString()
        let keyCount = try reader.readUInt32()
        guard keyCount == 1 else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "OpenSSH：密钥数量非 1", bundle: .module))
        }
        _ = try reader.readString()                    // 公钥段（跳过）
        let blob = try reader.readString()             // 私钥段：cipher=none 时即明文

        let encrypted = (cipherName != "none")
        let body: [UInt8]
        if encrypted {
            guard let passphrase else { return .encrypted(cipherName: cipherName) }
            body = try OpenSSHKeyDecryption.decryptPrivateSection(
                blob: blob, cipherName: cipherName, kdfName: kdfName,
                kdfOptions: kdfOptions, passphrase: passphrase)
        } else {
            body = blob
        }

        var priv = SSHWireReader(body)
        let check1 = try priv.readUInt32()
        let check2 = try priv.readUInt32()
        guard check1 == check2 else {
            // 解过密才走到这里的话几乎必然是口令错了：派生出的 key 不对，解出来就是
            // 随机字节，两个 checkint 还能撞上的概率是 2^-32。
            if encrypted { throw PrivateKeyImportError.incorrectPassphrase }
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "OpenSSH：checkint 不一致", bundle: .module))
        }
        let keyType = String(decoding: try priv.readString(), as: UTF8.self)
        return .plaintext(keyType: keyType, body: priv)
    }

    /// 取 BEGIN/END 之间的 base64 并解码。
    private static func extractBase64Body(_ text: String) throws -> [UInt8] {
        let doc = try PEMDocument.parse(text)
        guard doc.label == "OPENSSH PRIVATE KEY" else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "非 OpenSSH 私钥", bundle: .module))
        }
        return doc.der
    }
}
